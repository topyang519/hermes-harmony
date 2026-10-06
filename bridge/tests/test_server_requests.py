import asyncio
import json
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

from hermes_harmony_bridge.hermes import HermesClient, HermesError
from hermes_harmony_bridge.config import BridgeConfig
from hermes_harmony_bridge.fanout import Fanout
from hermes_harmony_bridge.server import AppSession, RateLimiter, TurnWatchdog
from hermes_harmony_bridge.state import DeviceStore
from fakes import FakeHermes


class Socket:
    closed = False

    def __init__(self):
        self.send_str = AsyncMock()


def _client():
    client = HermesClient(SimpleNamespace())
    client._ws = Socket()
    client._ready.set()
    client._server_request_capabilities_ready.set()
    return client


def _phone(tmp_path, hermes):
    ws = SimpleNamespace(closed=False, send_str=AsyncMock(), send_bytes=AsyncMock())
    session = AppSession(
        ws, BridgeConfig(), hermes, DeviceStore(tmp_path / "state.json"),
        RateLimiter(100), Fanout(), {},
    )
    session._helloed = True
    return session


@pytest.mark.asyncio
async def test_gateway_ready_advertises_server_request_capability():
    client = _client()
    client._dispatch(json.dumps({
        "jsonrpc": "2.0", "method": "event",
        "params": {"type": "gateway.ready", "payload": {"replay_epoch": "epoch"}},
    }))
    for _ in range(5):
        if client._ws.send_str.await_count:
            break
        await asyncio.sleep(0)
    sent = json.loads(client._ws.send_str.await_args.args[0])
    assert sent["method"] == "client.capabilities"
    assert sent["params"] == {"server_requests": True}
    client._dispatch(json.dumps({
        "jsonrpc": "2.0", "id": sent["id"],
        "result": {"server_requests": ["approval", "clarify"]},
    }))
    await client._capability_task
    assert client._server_requests_enabled is True
    assert client._server_request_capabilities_ready.is_set()


@pytest.mark.asyncio
async def test_modern_approval_is_normalized_and_answered_once():
    client = _client()
    events = []
    client.on_event(events.append)
    client._dispatch(json.dumps({
        "jsonrpc": "2.0", "id": "srq-abc123", "method": "approval",
        "params": {"session_id": "sid", "request_id": "approval-9", "command": "echo hi"},
    }))
    assert events == [{
        "type": "approval.request", "session_id": "sid",
        "payload": {
            "request_id": "approval-9", "command": "echo hi",
            "harmony_server_request_id": "srq-abc123",
            "harmony_server_request_method": "approval",
        },
    }]
    await client.respond_server_request("srq-abc123", {"choice": "once"}, expected_method="approval")
    response = json.loads(client._ws.send_str.await_args.args[0])
    assert response == {"jsonrpc": "2.0", "id": "srq-abc123", "result": {"choice": "once"}}
    assert "srq-abc123" not in client._server_requests
    with pytest.raises(HermesError):
        await client.respond_server_request("srq-abc123", {"choice": "deny"})


@pytest.mark.asyncio
async def test_server_request_cancellation_removes_pending_mapping():
    client = _client()
    client._server_request_event({
        "id": "srq-cancel", "method": "clarify",
        "params": {"session_id": "sid", "request_id": "clarify-1"},
    })
    client._dispatch(json.dumps({
        "jsonrpc": "2.0", "method": "event",
        "params": {"type": "request.cancel", "session_id": "sid", "payload": {"id": "srq-cancel"}},
    }))
    assert "srq-cancel" not in client._server_requests


@pytest.mark.asyncio
async def test_unknown_server_request_fails_fast_with_jsonrpc_error():
    client = _client()
    client._dispatch(json.dumps({
        "jsonrpc": "2.0", "id": "srq-unknown", "method": "sudo",
        "params": {"session_id": "sid"},
    }))
    for _ in range(5):
        if client._ws.send_str.await_count:
            break
        await asyncio.sleep(0)
    response = json.loads(client._ws.send_str.await_args.args[0])
    assert response["id"] == "srq-unknown"
    assert response["error"]["code"] == -32601


@pytest.mark.asyncio
async def test_batch_clarification_fails_fast_instead_of_showing_an_empty_card():
    client = _client()
    client._dispatch(json.dumps({
        "jsonrpc": "2.0", "id": "srq-batch", "method": "clarify",
        "params": {"session_id": "sid", "questions": [{"id": "q1", "question": "First?"}]},
    }))
    for _ in range(5):
        if client._ws.send_str.await_count:
            break
        await asyncio.sleep(0)
    response = json.loads(client._ws.send_str.await_args.args[0])
    assert response["id"] == "srq-batch"
    assert response["error"]["code"] == -32601


@pytest.mark.asyncio
async def test_modern_approval_and_clarify_answers_use_server_request_ids(tmp_path):
    fake = FakeHermes()
    session = _phone(tmp_path, fake)
    fake.restore_server_request({
        "id": "srq-approve", "method": "approval",
        "params": {"session_id": "sid", "request_id": "approval-1"},
    })
    fake.restore_server_request({
        "id": "srq-clarify", "method": "clarify",
        "params": {"session_id": "sid", "request_id": "clarify-1"},
    })
    await session._on_approve({
        "session": "sid", "request_id": "approval-1",
        "harmony_server_request_id": "srq-approve", "choice": "once",
    })
    await session._on_clarify({
        "session": "sid", "request_id": "clarify-1",
        "harmony_server_request_id": "srq-clarify", "answer": "continue",
    })
    assert fake.server_request_responses == [
        {"id": "srq-approve", "result": {"choice": "once"}},
        {"id": "srq-clarify", "result": {"answer": "continue"}},
    ]
    assert fake.approvals == []


@pytest.mark.asyncio
async def test_replay_restores_open_server_request_as_phone_event(tmp_path):
    fake = FakeHermes()
    request = {
        "id": "srq-replay", "method": "approval",
        "params": {"session_id": "sid", "request_id": "approval-replay", "command": "echo ok"},
    }
    fake.session_events_since = AsyncMock(return_value={
        "events": [], "latest_seq": 4, "truncated": False, "open_requests": [request],
    })
    fake.session_resume = AsyncMock(return_value={
        "session_id": "sid", "stored_session_id": "sid", "messages": [],
        "open_requests": [request],
    })
    session = _phone(tmp_path, fake)
    await session._replay("sid", 0)
    sent = [json.loads(call.args[0]) for call in session.ws.send_str.call_args_list]
    events = [item["p"] for item in sent if item.get("t") == "ev"]
    assert len(events) == 1
    assert events[0]["type"] == "approval.request"
    assert events[0]["payload"]["harmony_server_request_id"] == "srq-replay"


@pytest.mark.asyncio
async def test_unsequenced_server_request_is_fenced_to_new_agent_turn():
    fake = FakeHermes()
    watchdog = TurnWatchdog(fake, 60, AsyncMock())
    assert watchdog.arm("sid", "agent-task", start_after_seq=40)
    watchdog.observe_event({"type": "message.start", "session_id": "sid", "seq": 41}, agent_session=True)
    control = {
        "type": "approval.request", "session_id": "sid",
        "payload": {"request_id": "approval-1", "harmony_server_request_id": "srq-1"},
    }
    watchdog.observe_event(control, agent_session=True)
    accepted = watchdog.accept("sid", "agent-task", "user-row")
    assert [event["type"] for event in accepted] == ["message.start", "approval.request"]
    assert accepted[1]["harmony_request_id"] == "agent-task"
    await watchdog.close()


def test_server_request_correlation_survives_bridge_state_reload(tmp_path):
    path = tmp_path / "state.json"
    store = DeviceStore(path)
    store.remember_agent_turn("phone", "sid", "agent-task", "user-row")
    store.remember_agent_control_event(
        "sid", "agent-task", "approval.request", "approval-1", server_request_id="srq-1"
    )
    restored = DeviceStore(path)
    assert restored.agent_request_for_event("sid", {
        "type": "approval.request", "session_id": "sid",
        "payload": {"harmony_server_request_id": "srq-1"},
    }) == "agent-task"
