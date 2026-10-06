import asyncio
import json
import logging
from types import SimpleNamespace
from unittest.mock import AsyncMock
import pytest
from aiohttp.test_utils import make_mocked_request
from aiohttp import web
from hermes_harmony_bridge.config import BridgeConfig
from hermes_harmony_bridge.fanout import Fanout
from hermes_harmony_bridge.hermes import HermesClient, HermesError
from hermes_harmony_bridge.server import AppSession, RateLimiter, RedactingAccessLogger, TurnWatchdog, assistant_speech_text, maintain_hermes
from hermes_harmony_bridge.state import DeviceStore
from fakes import FakeHermes


def phone(tmp_path, hermes=None):
    ws = SimpleNamespace(closed=False, send_str=AsyncMock(), send_bytes=AsyncMock())
    session = AppSession(ws, BridgeConfig(), hermes or FakeHermes(), DeviceStore(tmp_path / 'state.json'), RateLimiter(100), Fanout(), {})
    session._helloed = True
    return session


@pytest.mark.asyncio
@pytest.mark.parametrize(("handler", "action", "frame"), [
    ("_on_session_archive", "archive", {"session": "sid", "archived": True}),
    ("_on_session_delete", "delete", {"session": "sid"}),
])
@pytest.mark.parametrize("fail", [False, True])
async def test_session_actions_echo_request_id(tmp_path, handler, action, frame, fail):
    fake = FakeHermes()
    if fail:
        method = "session_set_archived" if action == "archive" else "session_delete"
        setattr(fake, method, AsyncMock(side_effect=RuntimeError("expected test failure")))
    session = phone(tmp_path, fake)
    frame["request_id"] = "harmony-session-test-1"

    await getattr(session, handler)(frame)

    messages = [json.loads(call.args[0]) for call in session.ws.send_str.call_args_list]
    response_type = "error" if fail else "session_action"
    response = next(msg for msg in messages if msg["t"] == response_type)
    assert response["action"] == action
    assert response["request_id"] == frame["request_id"]


def test_access_logger_never_formats_query_or_headers(caplog):
    logger = RedactingAccessLogger(logging.getLogger('safe-access'), '%r')
    request = make_mocked_request('GET', '/v2/app?password=SECRET&other=ALSO_SECRET', headers={'X-Hermes-App-Password': 'HEADER_SECRET'})
    with caplog.at_level(logging.INFO):
        logger.log(request, web.Response(), 0.1)
    assert '/v2/app' in caplog.text
    assert 'SECRET' not in caplog.text


def test_assistant_speech_ignores_internal_or_failed_completions():
    assert assistant_speech_text({
        'type': 'message.complete',
        'payload': {'role': 'tool', 'text': 'internal'},
    }) == ''
    assert assistant_speech_text({
        'type': 'message.complete',
        'payload': {'display_kind': 'hidden', 'text': 'internal'},
    }) == ''
    assert assistant_speech_text({
        'type': 'message.complete',
        'payload': {'status': 'error', 'text': 'failed'},
    }) == ''
    assert assistant_speech_text({
        'type': 'message.complete',
        'payload': {'status': 'complete', 'text': '正常'},
    }) == '正常'


def test_internal_completion_does_not_disarm_auto_speak(tmp_path):
    session = phone(tmp_path)
    session._arm_auto_speak('sid')
    session._schedule_auto_speak({
        'session_id': 'sid',
        'type': 'message.complete',
        'payload': {'role': 'tool', 'text': 'internal'},
    })
    assert session._auto_speak_sid == 'sid'


@pytest.mark.asyncio
async def test_cancel_drops_audio_and_next_recording_works(tmp_path):
    session = phone(tmp_path)
    await session._on_asr_start({'sr': 16000})
    await session._on_binary(b'\x00\x01' * 400)
    await session._on_text('{"t":"asr_cancel"}')
    await session._on_binary(b'\x00\x01' * 400)
    await session._on_asr_end()
    assert not session.hermes.attaches
    assert session._pcm is None
    await session._on_asr_start({'sr': 'invalid'})
    assert not session._recording
    await session._on_asr_start({'sr': 16000})
    assert session._recording


@pytest.mark.asyncio
async def test_failed_tts_can_retry_identical_text(tmp_path):
    session = phone(tmp_path)
    session._speak_to_phone_locked = AsyncMock(side_effect=[HermesError('failed'), None])
    with pytest.raises(HermesError):
        await session._speak_to_phone('same text')
    await session._speak_to_phone('same text')
    await session._speak_to_phone('same text')
    assert session._speak_to_phone_locked.await_count == 2


@pytest.mark.asyncio
async def test_empty_stream_falls_back(tmp_path):
    fake = FakeHermes()
    async def broken_stream(text, *, profile=None):
        yield 'start', {'sample_rate': 16000}
        yield 'fallback', None
    fake.speak_stream = broken_stream
    fake.speak = AsyncMock(wraps=fake.speak)
    session = phone(tmp_path, fake)
    await session._speak_to_phone('hello')
    fake.speak.assert_awaited_once()
    assert session.ws.send_bytes.await_count > 0


@pytest.mark.asyncio
async def test_incomplete_pcm_stream_reported_aborted(tmp_path):
    fake = FakeHermes()
    async def broken_stream(text, *, profile=None):
        yield 'start', {'sample_rate': 16000}
        yield 'pcm', b'\x00\x01'
    fake.speak_stream = broken_stream
    session = phone(tmp_path, fake)
    with pytest.raises(HermesError):
        await session._speak_to_phone('hello')
    messages = [json.loads(call.args[0]) for call in session.ws.send_str.call_args_list]
    assert messages[-1]['t'] == 'tts_end'
    assert messages[-1]['aborted'] is True


@pytest.mark.asyncio
async def test_monitor_reconnects_once_then_leaves_healthy_link(monkeypatch):
    fake = FakeHermes()
    fake._ready = False
    fake.ensure_connected = AsyncMock(wraps=fake.ensure_connected)
    monkeypatch.setattr('hermes_harmony_bridge.server.discover_endpoint', lambda cfg: fake.endpoint)
    task = asyncio.create_task(maintain_hermes(fake, BridgeConfig(), interval=0.005))
    try:
        await asyncio.sleep(0.04)
        assert fake.connected
        fake.ensure_connected.assert_awaited_once_with(attempts=1)
    finally:
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)


@pytest.mark.asyncio
async def test_phone_handshake_does_not_wait_for_hermes(tmp_path):
    fake = FakeHermes()
    fake._ready = False
    fake.ensure_connected = AsyncMock(side_effect=TimeoutError("Hermes is down"))
    session = phone(tmp_path, fake)
    session._helloed = False
    await asyncio.wait_for(session._on_hello({'proto': 2, 'dev': 'phone'}), timeout=0.1)
    frames = [json.loads(call.args[0]) for call in session.ws.send_str.call_args_list]
    ready_index = next(index for index, frame in enumerate(frames) if frame['t'] == 'ready')
    assert ready_index == 0
    assert [frame['t'] for frame in frames[ready_index + 1:]] in ([], ['voice_capabilities'])
    ready = frames[ready_index]
    assert ready['t'] == 'ready'
    assert ready['hermes'] is False
    fake.ensure_connected.assert_not_awaited()


@pytest.mark.asyncio
async def test_reconnecting_device_replaces_stale_socket(tmp_path):
    first = phone(tmp_path)
    first.ws.close = AsyncMock(side_effect=lambda: setattr(first.ws, 'closed', True))
    first._helloed = False
    second = phone(tmp_path)
    second.connected = first.connected
    second._helloed = False
    await first._on_hello({'proto': 2, 'dev': 'same-phone'})
    await second._on_hello({'proto': 2, 'dev': 'same-phone'})
    first.ws.close.assert_awaited_once()
    assert first.connected['same-phone'] is second


@pytest.mark.asyncio
async def test_replay_precedes_live_events_that_arrive_during_snapshot(tmp_path):
    fake = FakeHermes()
    fake.add_event('sid', 'message.delta', {'text': 'old'})
    fake.add_event('sid', 'message.complete', {'role': 'assistant', 'text': 'old'})
    original = fake.session_events_since
    snapshot_started = asyncio.Event()
    release_snapshot = asyncio.Event()

    async def delayed_snapshot(sid, cursor):
        result = await original(sid, cursor)
        snapshot_started.set()
        await release_snapshot.wait()
        return result

    fake.session_events_since = delayed_snapshot
    session = phone(tmp_path, fake)
    session.device_key = 'phone'
    session._live_sids['sid'] = 'sid'
    task = asyncio.create_task(session._on_sub({'session': 'sid', 'last_seen': 1}))
    await snapshot_started.wait()
    live = fake.add_event('sid', 'message.delta', {'text': 'new'})
    await session.send_event(live)
    assert session.ws.send_str.await_count == 0
    release_snapshot.set()
    await task
    frames = [json.loads(call.args[0]) for call in session.ws.send_str.call_args_list]
    assert [frame['t'] for frame in frames] == ['ev', 'replay', 'ev']
    assert [frame['p']['seq'] for frame in frames if frame['t'] == 'ev'] == [2, 3]


@pytest.mark.asyncio
async def test_missing_phone_pong_closes_stale_socket(tmp_path, monkeypatch):
    session = phone(tmp_path)
    session.ws.close = AsyncMock(side_effect=lambda: setattr(session.ws, 'closed', True))
    session._last_pong = 0
    monkeypatch.setattr('hermes_harmony_bridge.server.asyncio.sleep', AsyncMock())
    await session._ping_loop()
    session.ws.close.assert_awaited_once()


@pytest.mark.asyncio
async def test_long_voice_handler_does_not_expire_unread_pong(tmp_path, monkeypatch):
    session = phone(tmp_path)
    session.ws.close = AsyncMock()
    session._last_pong = 0
    session._processing_message = True
    monkeypatch.setattr(
        'hermes_harmony_bridge.server.asyncio.sleep',
        AsyncMock(side_effect=lambda _interval: setattr(session.ws, 'closed', True)),
    )
    await session._ping_loop()
    session.ws.close.assert_not_awaited()


@pytest.mark.asyncio
async def test_client_loopback_query_auth_and_failed_handshake_cleanup(monkeypatch):
    class Socket:
        closed = False
        def __aiter__(self):
            return self
        async def __anext__(self):
            await asyncio.Event().wait()
        async def close(self):
            self.closed = True
    ws = Socket()
    http = SimpleNamespace(ws_connect=AsyncMock(return_value=ws))
    client = HermesClient(http)
    client.bind(FakeHermes().endpoint)
    original = asyncio.wait_for
    async def timeout(awaitable, timeout):
        return await original(awaitable, timeout=0.001)
    monkeypatch.setattr('hermes_harmony_bridge.hermes.asyncio.wait_for', timeout)
    with pytest.raises(TimeoutError):
        await client._connect()
    from urllib.parse import parse_qs, urlsplit
    assert parse_qs(urlsplit(http.ws_connect.call_args.args[0]).query)['token'] == [client.endpoint.token]
    assert http.ws_connect.call_args.kwargs['headers']['X-Hermes-Session-Token']
    assert ws.closed
    assert client._reader_task is None
    assert not client.connected

@pytest.mark.asyncio
async def test_disconnect_cancels_auto_tts_task(tmp_path):
    class Socket:
        closed = False
        send_str = AsyncMock()
        send_bytes = AsyncMock()
        def __aiter__(self):
            return self
        async def __anext__(self):
            self.closed = True
            raise StopAsyncIteration
    session = phone(tmp_path)
    started = asyncio.Event()
    cancelled = asyncio.Event()
    async def blocked_tts(text):
        started.set()
        try:
            await asyncio.Event().wait()
        finally:
            cancelled.set()
    session._auto_speak = blocked_tts
    session._arm_auto_speak('sid')
    session._schedule_auto_speak({'session_id': 'sid', 'type': 'message.complete', 'payload': {'text': 'hi'}})
    await started.wait()
    session.ws = Socket()
    await session.run()
    assert cancelled.is_set()
    assert not session._tts_tasks


@pytest.mark.asyncio
async def test_turn_watchdog_interrupts_and_notifies():
    fake = FakeHermes()
    notified = asyncio.Event()
    notify = AsyncMock(side_effect=lambda _sid: notified.set())
    watchdog = TurnWatchdog(fake, 15, notify)
    watchdog.timeout = 0.01
    watchdog.arm('sid')
    try:
        await asyncio.wait_for(notified.wait(), timeout=1)
        assert fake.interrupts == ['sid']
        notify.assert_awaited_once_with('sid')
    finally:
        await watchdog.close()


@pytest.mark.asyncio
async def test_turn_watchdog_settle_prevents_interrupt():
    fake = FakeHermes()
    notify = AsyncMock()
    watchdog = TurnWatchdog(fake, 15, notify)
    watchdog.timeout = 0.01
    watchdog.arm('sid')
    watchdog.settle('sid')
    await asyncio.sleep(0.03)
    assert fake.interrupts == []
    notify.assert_not_awaited()
    await watchdog.close()


@pytest.mark.asyncio
async def test_turn_watchdog_serializes_and_correlates_session_turns():
    fake = FakeHermes()
    watchdog = TurnWatchdog(fake, 15, AsyncMock())
    assert watchdog.arm('sid', 'request-a') is True
    assert watchdog.request_id('sid') == 'request-a'
    assert watchdog.arm('sid', 'request-b') is False
    assert watchdog.settle('sid', 'request-b') is False
    assert watchdog.request_id('sid') == 'request-a'
    assert watchdog.settle('sid', 'request-a') is True
    await asyncio.sleep(0)
    await watchdog.close()


@pytest.mark.asyncio
async def test_agent_dispatch_is_single_flight_and_event_replay_keeps_correlation(tmp_path):
    fake = FakeHermes()
    session = phone(tmp_path, fake)
    session.device_key = "phone-1"
    watchdog = TurnWatchdog(fake, 60, AsyncMock())
    session.watchdog = watchdog

    await session._on_dispatch({
        "session": "sid", "text": "first", "request_id": "request-a", "agent_session": True
    })
    sent = [json.loads(call.args[0]) for call in session.ws.send_str.call_args_list]
    assert any(m.get("t") == "session_resolved" and m.get("session") == "sid" for m in sent)
    assert watchdog.request_id("sid") == "request-a"
    assert session.store.is_agent_session("sid")
    assert fake.prompts == [("sid", "first")]

    await session._on_dispatch({"session": "sid", "text": "second", "request_id": "request-b"})
    sent = [json.loads(call.args[0]) for call in session.ws.send_str.call_args_list]
    assert any(m.get("t") == "error" and m.get("code") == "busy" and
               m.get("request_id") == "request-b" for m in sent)
    assert fake.prompts == [("sid", "first")]

    fake.add_event("sid", "message.delta", {"text": "reply"})
    raw_terminal = fake.add_event(
        "sid", "message.complete", {
            "role": "assistant", "text": "first result",
            "persisted_turn": {"user_row_id": fake.last_user_row_id},
        }
    )
    event, request_id, terminal = watchdog.observe_event(raw_terminal, agent_session=True)
    assert request_id == "request-a"
    assert terminal is True
    assert event["harmony_request_id"] == "request-a"
    watchdog.settle("sid", "request-a")

    # A reconnect replays the canonical Hermes event with its request ID even
    # though the live turn lock has already been released.
    resumed = phone(tmp_path, fake)
    resumed.watchdog = watchdog
    # A new/fresh client cursor uses the canonical session snapshot, but the
    # bridge must still replay correlated A2A events so an in-memory Xiaoyi
    # waiter can finish after reconnect, even after the bridge process restarts.
    resumed.watchdog = TurnWatchdog(fake, 60, AsyncMock())
    await resumed._on_sub({"session": "sid", "last_seen": 0})
    replayed = [json.loads(call.args[0]) for call in resumed.ws.send_str.call_args_list]
    replayed_event = next(
        m["p"] for m in replayed
        if m.get("t") == "ev" and m["p"].get("harmony_request_id") == "request-a"
    )
    assert replayed_event["harmony_request_id"] == "request-a"

    # A later event on this session is not attributed to the completed task.
    unrelated = fake.add_event("sid", "message.complete", {"text": "later"})
    event, request_id, _ = watchdog.observe_event(unrelated, agent_session=True)
    assert request_id == ""
    assert "harmony_request_id" not in event
    await watchdog.close()


@pytest.mark.asyncio
async def test_agent_dispatch_refuses_session_with_running_hermes_turn(tmp_path):
    fake = FakeHermes()
    fake.running_sessions.add("sid")
    session = phone(tmp_path, fake)
    session.device_key = "phone-1"
    watchdog = TurnWatchdog(fake, 60, AsyncMock())
    session.watchdog = watchdog

    await session._on_dispatch({
        "session": "sid", "text": "do work", "request_id": "request-busy", "agent_session": True
    })

    sent = [json.loads(call.args[0]) for call in session.ws.send_str.call_args_list]
    assert any(m.get("t") == "error" and m.get("code") == "busy" and
               m.get("request_id") == "request-busy" for m in sent)
    assert fake.prompts == []
    assert watchdog.request_id("sid") == ""
    await watchdog.close()


@pytest.mark.asyncio
async def test_unaccepted_submit_cannot_claim_another_same_session_turn(tmp_path):
    fake = FakeHermes()
    watchdog = TurnWatchdog(fake, 60, AsyncMock())
    assert watchdog.arm("agent-session", "request-pending")
    other_turn = fake.add_event(
        "agent-session", "message.complete", {"role": "assistant", "text": "other result"}
    )
    event, request_id, terminal = watchdog.observe_event(other_turn, agent_session=True)
    assert request_id == ""
    assert terminal is False
    assert "harmony_request_id" not in event
    watchdog.settle("agent-session", "request-pending")  # prompt.submit rejected/busy
    assert "harmony_request_id" not in watchdog.restore_event(other_turn)
    await watchdog.close()


@pytest.mark.asyncio
async def test_old_same_session_completion_cannot_finish_new_agent_request():
    fake = FakeHermes()
    watchdog = TurnWatchdog(fake, 60, AsyncMock())
    assert watchdog.arm("agent-session", "request-new")

    old_completion = {
        "type": "message.complete", "session_id": "agent-session", "seq": 10,
        "payload": {"status": "complete", "text": "old result",
                    "persisted_turn": {"user_row_id": "row-old"}},
    }
    raw, request_id, terminal = watchdog.observe_event(old_completion, agent_session=True)
    assert request_id == ""
    assert terminal is False
    assert "harmony_request_id" not in raw

    new_start = {"type": "message.start", "session_id": "agent-session", "seq": 11, "payload": {}}
    raw, request_id, terminal = watchdog.observe_event(new_start, agent_session=True)
    assert request_id == ""
    assert terminal is False
    accepted = watchdog.accept("agent-session", "request-new", "row-new")
    assert [event["seq"] for event in accepted] == [11]
    assert accepted[0]["harmony_request_id"] == "request-new"

    # A late/replayed completion from the preceding turn cannot release the lock.
    raw, request_id, terminal = watchdog.observe_event(old_completion, agent_session=True)
    assert request_id == ""
    assert terminal is False
    assert watchdog.request_id("agent-session") == "request-new"

    own_completion = {
        "type": "message.complete", "session_id": "agent-session", "seq": 12,
        "payload": {"status": "complete", "text": "new result",
                    "persisted_turn": {"user_row_id": "row-new"}},
    }
    raw, request_id, terminal = watchdog.observe_event(own_completion, agent_session=True)
    assert request_id == "request-new"
    assert terminal is True
    assert watchdog.settle("agent-session", request_id)
    await watchdog.close()


@pytest.mark.asyncio
async def test_control_events_are_correlated_only_after_accepted_fenced_turn_start():
    fake = FakeHermes()
    watchdog = TurnWatchdog(fake, 60, AsyncMock())
    assert watchdog.arm("agent-session", "request-control", start_after_seq=10)

    stale_control = {
        "type": "approval.request", "session_id": "agent-session", "seq": 10,
        "payload": {"request_id": "stale-approval"},
    }
    event, request_id, terminal = watchdog.observe_event(stale_control, agent_session=True)
    assert request_id == ""
    assert terminal is False

    raw_start = {"type": "message.start", "session_id": "agent-session", "seq": 11, "payload": {}}
    event, request_id, terminal = watchdog.observe_event(raw_start, agent_session=True)
    assert request_id == ""
    accepted = watchdog.accept("agent-session", "request-control", "row-control")
    assert [item["type"] for item in accepted] == ["message.start"]

    for event_type in ("approval.request", "clarify.request"):
        control = {
            "type": event_type, "session_id": "agent-session", "seq": 12,
            "payload": {"request_id": f"{event_type}-id"},
        }
        event, request_id, terminal = watchdog.observe_event(control, agent_session=True)
        assert request_id == "request-control"
        assert terminal is False
        assert event["harmony_request_id"] == "request-control"
        assert watchdog.request_id("agent-session") == "request-control"

    # A control frame buffered before prompt.submit's reply is attributed only after
    # the streaming response accepts this row and its new start sequence.
    await watchdog.close()
    pending = TurnWatchdog(fake, 60, AsyncMock())
    assert pending.arm("pending-session", "request-pending-control", start_after_seq=20)
    event, request_id, terminal = pending.observe_event({
        "type": "message.start", "session_id": "pending-session", "seq": 21, "payload": {}
    }, agent_session=True)
    assert request_id == ""
    event, request_id, terminal = pending.observe_event({
        "type": "approval.request", "session_id": "pending-session", "seq": 22, "payload": {}
    }, agent_session=True)
    assert request_id == ""
    assert terminal is False
    accepted = pending.accept("pending-session", "request-pending-control", "row-pending")
    assert [item["type"] for item in accepted] == ["message.start", "approval.request"]
    assert accepted[1]["harmony_request_id"] == "request-pending-control"
    await pending.close()


@pytest.mark.asyncio
async def test_agent_control_without_new_start_stays_unclaimed():
    fake = FakeHermes()
    watchdog = TurnWatchdog(fake, 60, AsyncMock())
    assert watchdog.arm("agent-session", "request-no-start", start_after_seq=5)
    assert watchdog.accept("agent-session", "request-no-start", "row-no-start") == []
    control = {
        "type": "clarify.request", "session_id": "agent-session", "seq": 6,
        "payload": {"request_id": "clarify-1"},
    }
    event, request_id, terminal = watchdog.observe_event(control, agent_session=True)
    assert request_id == ""
    assert terminal is False
    assert "harmony_request_id" not in event
    assert watchdog.request_id("agent-session") == "request-no-start"
    await watchdog.close()


def test_agent_session_registry_survives_bridge_state_reload(tmp_path):
    path = tmp_path / "device-state.json"
    store = DeviceStore(path)
    store.mark_agent_session("phone-1", "live-session", "stored-session")
    store.remember_agent_turn("phone-1", "stored-session", "request-42", "row-42")
    store.remember_agent_control_event(
        "live-session", "request-42", "approval.request", "approval-42"
    )
    restored = DeviceStore(path)
    assert restored.is_agent_session("live-session")
    assert restored.is_agent_session("stored-session")
    assert restored.agent_request_for_event("live-session", {
        "type": "message.complete",
        "payload": {"persisted_turn": {"user_row_id": "row-42"}},
    }) == "request-42"
    assert restored.agent_request_for_event("live-session", {
        "type": "approval.request", "seq": 17, "payload": {"request_id": "approval-42"}
    }) == "request-42"
    assert restored.agent_request_for_event("live-session", {
        "type": "approval.request", "seq": 17, "payload": {"request_id": "unrelated"}
    }) == ""


def test_forgetting_session_clears_agent_tracking_and_preserves_other_sessions(tmp_path):
    store = DeviceStore(tmp_path / "device-state.json")
    store.mark_agent_session("phone-1", "live-session", "stored-session")
    store.remember_agent_turn("phone-1", "stored-session", "request-deleted", "row-deleted")
    store.mark_agent_session("phone-1", "other-live", "other-stored")
    store.remember_agent_turn("phone-1", "other-stored", "request-kept", "row-kept")
    record = store.get("phone-1")
    record.cursors.update({"live-session": 7, "stored-session": 8, "other-live": 9})

    store.forget_session("stored-session")

    assert store.is_agent_session("live-session") is False
    assert store.is_agent_session("stored-session") is False
    assert store.agent_request_for_event("live-session", {
        "type": "message.complete",
        "payload": {"persisted_turn": {"user_row_id": "row-deleted"}},
    }) == ""
    assert store.is_agent_session("other-live") is True
    assert store.agent_request_for_event("other-live", {
        "type": "message.complete",
        "payload": {"persisted_turn": {"user_row_id": "row-kept"}},
    }) == "request-kept"
    assert record.cursors == {"other-live": 9}
    restored = DeviceStore(store.path)
    assert restored.is_agent_session("live-session") is False
    assert restored.is_agent_session("other-stored") is True


def test_corrupt_agent_turn_metadata_does_not_break_state_load(tmp_path):
    path = tmp_path / "device-state.json"
    path.write_text(json.dumps({"devices": {"phone": {
        "agent_turns": [{"session_id": "sid", "created_at": "not-a-timestamp"}]
    }}}), encoding="utf-8")
    store = DeviceStore(path)
    assert store.get("phone").agent_turns == []


@pytest.mark.asyncio
async def test_interrupt_reports_confirmed_request_and_rejects_stale_cancel(tmp_path):
    fake = FakeHermes()
    session = phone(tmp_path, fake)
    watchdog = TurnWatchdog(fake, 60, AsyncMock())
    session.watchdog = watchdog
    assert watchdog.arm("sid", "active-request") is True

    await session._on_interrupt({
        "session": "sid", "request_id": "cancel-request", "task_request_id": "stale-request"
    })
    messages = [json.loads(call.args[0]) for call in session.ws.send_str.call_args_list]
    assert messages[-1]["status"] == "inactive"
    assert fake.interrupts == []

    await session._on_interrupt({
        "session": "sid", "request_id": "cancel-request-2", "task_request_id": "active-request"
    })
    messages = [json.loads(call.args[0]) for call in session.ws.send_str.call_args_list]
    assert messages[-1]["status"] == "interrupted"
    assert messages[-1]["task_request_id"] == "active-request"
    assert fake.interrupts == ["sid"]
    await watchdog.close()


@pytest.mark.asyncio
async def test_unsupported_wav_rate_converted_to_supported_pcm(tmp_path, monkeypatch):
    from hermes_harmony_bridge.audio import pcm16_to_wav
    converted = pcm16_to_wav(b'\x00\x01' * 160, sample_rate=16000)
    converter = AsyncMock(return_value=converted)
    monkeypatch.setattr('hermes_harmony_bridge.server.ffmpeg_to_pcm_wav', converter)
    session = phone(tmp_path)
    for rate in (22050, 44100, 48000):
        source = pcm16_to_wav(b'\x00\x01' * 160, sample_rate=rate)
        pcm, sr = await session._to_pcm(source, 'audio/wav')
        assert sr == 16000
        assert pcm == b'\x00\x01' * 160
        converter.assert_awaited_with(source)
    assert converter.await_count == 3
