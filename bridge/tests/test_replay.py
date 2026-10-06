"""Replay / truncated / epoch — the failure-prone path (plan §3.3)."""

from __future__ import annotations

import pytest
from aiohttp import web

from hermes_harmony_bridge.config import BridgeConfig
from hermes_harmony_bridge.server import create_app

from fakes import FakeHermes
from fake_phone import FakePhone, PhoneState, seqs_of

PASSWORD = "unit-app-password-replay"


async def _start(tmp_path, fake=None):
    cfg = BridgeConfig()
    cfg.host = "127.0.0.1"
    cfg.app_password = PASSWORD
    cfg.state_dir = tmp_path / "state"
    cfg.state_dir.mkdir()
    cfg.ping_interval_seconds = 120
    fake = fake or FakeHermes()
    app = create_app(cfg, hermes=fake)
    runner = web.AppRunner(app)
    await runner.setup()
    await web.TCPSite(runner, "127.0.0.1", 0).start()
    return runner, runner.addresses[0][1], fake


async def _phone(session, port, device="unit-phone"):
    ws = await session.ws_connect(
        f"ws://127.0.0.1:{port}/v2/app",
        headers={"X-Hermes-App-Password": PASSWORD},
    )
    phone = FakePhone(ws, device_id=device)
    await phone.hello()
    return phone


@pytest.mark.asyncio
async def test_dispatch_forwards_raw_events_with_seq(tmp_path):
    import aiohttp

    runner, port, fake = await _start(tmp_path)
    try:
        async with aiohttp.ClientSession() as session:
            phone = await _phone(session, port)
            sid = await phone.new_session()
            await phone.sub(sid, 0)
            await phone.dispatch("hi")
            await phone.wait_complete(timeout=5)
            types = [e["type"] for e in phone.state.events]
            assert "message.start" in types
            assert "message.delta" in types
            assert "message.complete" in types
            seqs = seqs_of(phone.state.events, sid)
            assert seqs == list(range(seqs[0], seqs[0] + len(seqs)))
            assert all("type" in e and "seq" in e for e in phone.state.events)
            assert any(e.get("payload", {}).get("text") == "pong" for e in phone.state.events)
    finally:
        await runner.cleanup()


@pytest.mark.asyncio
async def test_replay_matches_live_tail(tmp_path):
    import aiohttp

    runner, port, fake = await _start(tmp_path)
    try:
        async with aiohttp.ClientSession() as session:
            phone = await _phone(session, port, "live")
            sid = await phone.new_session()
            await phone.sub(sid, 0)
            await phone.dispatch("hi")
            await phone.wait_complete(timeout=5)
            original = seqs_of(phone.state.events, sid)
            cut = original[0]
            await phone.ws.close()

        async with aiohttp.ClientSession() as session:
            phone2 = await _phone(session, port, "resume")
            replay = await phone2.sub(sid, last_seen=cut)
            assert replay["truncated"] is False
            replayed = seqs_of(phone2.state.events, sid)
            expected = [s for s in original if s > cut]
            assert replayed == expected
    finally:
        await runner.cleanup()


@pytest.mark.asyncio
async def test_zero_cursor_uses_canonical_resume_instead_of_raw_history(tmp_path):
    import aiohttp

    fake = FakeHermes()
    runner, port, fake = await _start(tmp_path, fake=fake)
    try:
        async with aiohttp.ClientSession() as session:
            phone = await _phone(session, port)
            sid = await phone.new_session()
            fake.add_event(sid, "message.complete", {
                "role": "tool",
                "text": "internal tool output",
            })
            replay = await phone.sub(sid, last_seen=0)
            assert replay["truncated"] is True
            assert isinstance(replay.get("resume"), dict)
            assert fake.resume_calls
            assert phone.state.events == []
    finally:
        await runner.cleanup()


@pytest.mark.asyncio
async def test_persisted_runtime_id_is_refreshed_after_hermes_restart(tmp_path):
    import aiohttp

    fake = FakeHermes()
    runner, port, fake = await _start(tmp_path, fake=fake)
    try:
        async with aiohttp.ClientSession() as session:
            phone = await _phone(session, port, "before-restart")
            old_live = await phone.new_session()
            stored = phone.state.stored_id
            await phone.sub(old_live, last_seen=0)
            await phone.ws.close()

        new_live = "rt-after-restart"
        fake.stored_to_live[stored] = new_live
        fake.latest[new_live] = 0
        async with aiohttp.ClientSession() as session:
            phone2 = await _phone(session, port, "after-restart")
            replay = await phone2.sub(old_live, last_seen=0)
            assert replay["session"] == new_live
            assert fake.resume_calls[-1] == stored
    finally:
        await runner.cleanup()


@pytest.mark.asyncio
async def test_truncated_calls_session_resume(tmp_path):
    import aiohttp

    fake = FakeHermes()
    runner, port, fake = await _start(tmp_path, fake=fake)
    try:
        async with aiohttp.ClientSession() as session:
            phone = await _phone(session, port)
            sid = await phone.new_session()
            for i in range(520):
                fake.add_event(sid, "message.delta", {"text": str(i)})
            assert fake.evicted_through.get(sid, 0) > 0
            replay = await phone.sub(sid, last_seen=1)
            assert replay["truncated"] is True
            assert isinstance(replay.get("resume"), dict)
            assert fake.resume_calls
            assert fake.since_calls[-1] == (sid, 1)
    finally:
        await runner.cleanup()


@pytest.mark.asyncio
async def test_negative_last_seen_is_truncated_like_hermes(tmp_path):
    """Hermes is_truncated(sid, last_seen) is last_seen < evicted_through (default 0),
    so last_seen=-1 reports truncated even on an empty ring. The bridge must still
    take the resume path and mark replay.truncated=true."""
    import aiohttp

    fake = FakeHermes()
    runner, port, fake = await _start(tmp_path, fake=fake)
    try:
        async with aiohttp.ClientSession() as session:
            phone = await _phone(session, port)
            sid = await phone.new_session()
            fake.evicted_through[sid] = 0
            replay = await phone.sub(sid, last_seen=-1)
            assert replay["truncated"] is True
            assert fake.resume_calls
    finally:
        await runner.cleanup()


@pytest.mark.asyncio
async def test_phone_resets_cursors_when_epoch_changes(tmp_path):
    state = PhoneState()
    state.last_seen["s1"] = 97
    state.epoch = "epoch-aaa"
    state.note_epoch("epoch-bbb")
    assert state.reset_cursors_on_epoch is True
    assert state.last_seen["s1"] == 0
    assert state.epoch == "epoch-bbb"


@pytest.mark.asyncio
async def test_approve_refuses_missing_choice(tmp_path):
    import aiohttp

    runner, port, fake = await _start(tmp_path)
    try:
        async with aiohttp.ClientSession() as session:
            phone = await _phone(session, port)
            sid = await phone.new_session()
            await phone.send(t="approve", session=sid, request_id="r1")
            err = await phone.wait_for(lambda m: m.get("t") == "error", timeout=5)
            assert err.get("code") == "no_choice"
            assert fake.approvals == []
            await phone.approve("r1", choice="once", session=sid)
            for _ in range(20):
                if fake.approvals:
                    break
                await asyncio_sleep_brief()
            assert fake.approvals == [{"session_id": sid, "choice": "once", "request_id": "r1"}]
    finally:
        await runner.cleanup()


async def asyncio_sleep_brief():
    import asyncio

    await asyncio.sleep(0.05)
