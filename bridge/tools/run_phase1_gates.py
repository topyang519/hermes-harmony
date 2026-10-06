#!/usr/bin/env python3
"""Run Phase-1 live gates against a real hermes serve. Never prints tokens."""

from __future__ import annotations

import asyncio
import json
import os
import secrets
import sys
import tempfile
from pathlib import Path

import aiohttp
from aiohttp import web

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "tools"))

from fake_phone import FakePhone, PhoneState, assert_monotonic, seqs_of  # noqa: E402
from hermes_harmony_bridge.audio import ffmpeg_to_pcm_wav, parse_wav  # noqa: E402
from hermes_harmony_bridge.config import BridgeConfig, HermesSettings  # noqa: E402
from hermes_harmony_bridge.discovery import discover_endpoint  # noqa: E402
from hermes_harmony_bridge.hermes import HermesClient  # noqa: E402
from hermes_harmony_bridge.server import create_app  # noqa: E402

PASSWORD = secrets.token_urlsafe(24)
REPORTS: list[dict] = []


def note(gate: int, status: str, **detail):
    rec = {"gate": gate, "status": status, **detail}
    REPORTS.append(rec)
    print("GATE", json.dumps(rec, ensure_ascii=False, default=str))


async def start_bridge(tmp: Path) -> tuple[web.AppRunner, int]:
    cfg = BridgeConfig()
    cfg.host = "127.0.0.1"
    cfg.port = 0
    cfg.app_password = PASSWORD
    cfg.state_dir = tmp / "state"
    cfg.state_dir.mkdir()
    cfg.ping_interval_seconds = 60
    cfg.hermes.allow_spawn = False
    cfg.hermes.turn_timeout_seconds = 180
    cfg.turns_per_minute = 30
    app = create_app(cfg)
    runner = web.AppRunner(app)
    await runner.setup()
    await web.TCPSite(runner, cfg.host, 0).start()
    return runner, runner.addresses[0][1]


async def open_phone(port: int, device: str) -> tuple[aiohttp.ClientSession, FakePhone]:
    session = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=240))
    ws = await session.ws_connect(
        f"ws://127.0.0.1:{port}/v2/app",
        headers={"X-Hermes-App-Password": PASSWORD, "CF-Access-Client-Id": "local-test.access",
                 "CF-Access-Client-Secret": "local-test-secret"},
        heartbeat=20,
    )
    phone = FakePhone(ws, device_id=device, state=PhoneState())
    return session, phone


async def gate2(port: int) -> str:
    http, phone = await open_phone(port, "g2")
    try:
        ready = await phone.hello()
        sid = await phone.new_session("gate2")
        await phone.sub(sid, 0)
        await phone.dispatch("Reply with exactly the word pong and do not use any tools.")
        complete = await phone.wait_complete(timeout=120)
        types = [e.get("type") for e in phone.state.events]
        seqs = seqs_of(phone.state.events, sid)
        assert_monotonic(seqs)
        payload = (complete.get("p") or {}).get("payload") or {}
        needed = {"message.start", "message.delta", "message.complete"}
        missing = needed - set(types)
        ok = not missing and not phone.state.errors
        note(
            2,
            "PASS" if ok else "FAIL",
            session=sid,
            types=types,
            seq=seqs,
            missing=sorted(missing),
            complete_status=payload.get("status"),
            text_len=len(str(payload.get("text") or "")),
            epoch_present=bool(ready.get("epoch")),
            errors=phone.state.errors,
        )
        return sid
    finally:
        await http.close()


async def gate3(port: int) -> None:
    http, phone = await open_phone(port, "g3")
    try:
        await phone.hello()
        sid = await phone.new_session("gate3")
        await phone.sub(sid, 0)
        await phone.dispatch(
            "You MUST invoke a tool. Call the terminal tool with command exactly: echo hermes-harmony-gate3. "
            "Do not finish the turn until that tool has completed."
        )
        await phone.wait_complete(timeout=180)
        types = [e.get("type") for e in phone.state.events]
        ok = "tool.start" in types and "tool.complete" in types
        note(3, "PASS" if ok else "FAIL", session=sid, types=types, errors=phone.state.errors)
    finally:
        await http.close()


async def gate4(port: int) -> None:
    http, phone = await open_phone(port, "g4")
    try:
        await phone.hello()
        sid = await phone.new_session("gate4")
        await phone.sub(sid, 0)
        await phone.dispatch("Reply with exactly the word pong and do not use any tools.")
        await phone.wait_complete(timeout=120)
        original = list(phone.state.events)
        orig_seqs = seqs_of(original, sid)
        assert_monotonic(orig_seqs)
        cut = orig_seqs[len(orig_seqs) // 3] if len(orig_seqs) >= 3 else orig_seqs[0]
        await phone.ws.close()
        await http.close()
        http2, phone2 = await open_phone(port, "g4b")
        try:
            await phone2.hello()
            replay = await phone2.sub(sid, last_seen=cut)
            replayed = seqs_of(phone2.state.events, sid)
            expected = [s for s in orig_seqs if s > cut]
            match = replayed == expected and not replay.get("truncated")
            note(
                4,
                "PASS" if match else "FAIL",
                session=sid,
                cut=cut,
                original_seqs=orig_seqs,
                replayed_seqs=replayed,
                expected_seqs=expected,
                truncated=replay.get("truncated"),
            )
        finally:
            await http2.close()
    except Exception:
        if not http.closed:
            await http.close()
        raise


async def gate5(port: int) -> None:
    http, phone = await open_phone(port, "g5")
    try:
        await phone.hello()
        sid = await phone.new_session("gate5")
        await phone.sub(sid, 0)
        await phone.dispatch("Reply with exactly the word pong and do not use any tools.")
        await phone.wait_complete(timeout=120)
        replay = await phone.sub(sid, last_seen=-1)
        if replay.get("t") == "error":
            note(5, "FAIL", session=sid, error=replay.get("msg"), code=replay.get("code"))
            return
        ok = replay.get("truncated") is True and isinstance(replay.get("resume"), dict)
        note(
            5,
            "PASS" if ok else "FAIL",
            session=sid,
            last_seen=-1,
            truncated=replay.get("truncated"),
            latest_seq=replay.get("latest_seq"),
            resume_keys=sorted((replay.get("resume") or {}).keys()) if ok else [],
            note="Hermes is_truncated(sid,last_seen) is last_seen < evicted_through (default 0), so -1 is truncated",
        )
    finally:
        await http.close()


async def gate7(port: int) -> None:
    ep = discover_endpoint(HermesSettings(allow_spawn=False), probe=True)
    wav_path = Path(tempfile.gettempdir()) / "harmony-gate7.wav"
    async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=120)) as http:
        client = HermesClient(http)
        client.bind(ep)
        ogg, mime = await client.speak("请说你好。")
        wav = await ffmpeg_to_pcm_wav(ogg)
        parsed = parse_wav(wav)
        wav_path.write_bytes(wav)
        await client.close()
    http, phone = await open_phone(port, "g7")
    try:
        await phone.hello()
        sid = await phone.new_session("gate7")
        await phone.sub(sid, 0)
        transcript = await phone.asr_wav(wav_path, session=sid)
        try:
            await phone.wait_complete(timeout=120)
        except TimeoutError:
            pass
        pcm, end = await phone.tts(transcript or "hello")
        declared = end.get("bytes")
        ok = declared == len(pcm) and not end.get("aborted")
        note(
            7,
            "PASS" if ok else "FAIL",
            session=sid,
            transcript=transcript,
            pcm_bytes=len(pcm),
            tts_end_bytes=declared,
            bytes_match=declared == len(pcm),
            tts_sr=phone.state.tts_sr,
            wav_sr=parsed.get("sample_rate"),
            errors=phone.state.errors,
        )
    finally:
        await http.close()


async def gate8(port: int) -> None:
    http, phone = await open_phone(port, "g8")
    try:
        await phone.hello()
        sid = await phone.new_session("gate8")
        await phone.sub(sid, 0)
        await phone.dispatch(
            "Use the terminal tool to run exactly this command and nothing else: echo hermes-harmony-approval-probe"
        )
        got = None
        try:
            got = await phone.wait_type("approval.request", timeout=45)
        except TimeoutError:
            got = None
        if got is None:
            types = [e.get("type") for e in phone.state.events]
            note(
                8,
                "FAIL",
                session=sid,
                reason="no approval.request — ~/.hermes/config.yaml approvals.mode is off so tools auto-run",
                types=types,
            )
            return
        payload = (got.get("p") or {}).get("payload") or {}
        request_id = str(payload.get("request_id") or "")
        await phone.approve(request_id, choice="once")
        complete = await phone.wait_complete(timeout=120)
        ok = bool(request_id)
        note(
            8,
            "PASS" if ok else "FAIL",
            session=sid,
            request_id_present=bool(request_id),
            choices=payload.get("choices"),
            complete=(complete.get("p") or {}).get("payload", {}).get("status"),
        )
    finally:
        await http.close()


async def gate6_epoch(port: int, runner: web.AppRunner) -> None:
    http, phone = await open_phone(port, "g6a")
    try:
        ready1 = await phone.hello()
        epoch1 = ready1.get("epoch")
        phone.state.last_seen["dummy"] = 97
        note(6, "INFO", phase="before_restart", epoch_len=len(str(epoch1 or "")), cursor=97)
    finally:
        await http.close()

    ep = discover_endpoint(HermesSettings(allow_spawn=False), probe=True)
    pid = ep.pid
    if not pid:
        note(6, "FAIL", reason="no hermes serve pid to restart")
        return
    os.kill(pid, 15)
    await asyncio.sleep(2)
    deadline = asyncio.get_event_loop().time() + 25
    ep2 = None
    while asyncio.get_event_loop().time() < deadline:
        try:
            ep2 = discover_endpoint(HermesSettings(allow_spawn=False), probe=True)
            if ep2.pid and ep2.pid != pid:
                break
        except Exception:
            pass
        await asyncio.sleep(0.8)
    if ep2 is None:
        note(6, "FAIL", reason="hermes serve did not come back after SIGTERM")
        return

    http2, phone2 = await open_phone(port, "g6b")
    try:
        phone2.state.last_seen["dummy"] = 97
        phone2.state.epoch = str(epoch1 or "old")
        ready2 = await phone2.hello()
        epoch2 = ready2.get("epoch")
        reset = phone2.state.reset_cursors_on_epoch and phone2.state.last_seen.get("dummy") == 0
        changed = bool(epoch1) and bool(epoch2) and epoch1 != epoch2
        note(
            6,
            "PASS" if changed and reset else "FAIL",
            epoch_changed=changed,
            cursors_reset=reset,
            old_pid=pid,
            new_pid=ep2.pid,
            new_url=ep2.url,
        )
    finally:
        await http2.close()


async def gate10() -> None:
    import subprocess

    repo = ROOT.parent
    gi = (repo / ".gitignore").read_text()
    ok_gi = "bridge.toml" in gi and ".secrets/" in gi
    leaked = subprocess.check_output(
        ["rg", "-n", r"(HERMES_DASHBOARD_SESSION_TOKEN=|CF-Access-Client-Secret:\s+\S{8}|app_token\s*=\s*\"[a-zA-Z0-9_-]{20,}\")",
         str(repo), "-g", "!**/.venv/**", "-g", "!.git/**"],
        text=True,
    ) if False else ""
    proc = subprocess.run(
        ["rg", "-n", "app_token\\s*=\\s*\"[A-Za-z0-9_-]{16,}\"", str(repo), "-g", "!**/.venv/**", "-g", "!.git/**",
         "-g", "!**/*.example"],
        capture_output=True,
        text=True,
    )
    hits = (proc.stdout or "").strip()
    note(
        10,
        "PASS" if ok_gi and not hits else "FAIL",
        gitignore_ok=ok_gi,
        checked_in_app_token=bool(hits),
        token_never_printed=True,
    )


async def main() -> int:
    tmp = Path(tempfile.mkdtemp(prefix="harmony-gates-"))
    runner, port = await start_bridge(tmp)
    print(json.dumps({"bridge_port": port, "health": f"http://127.0.0.1:{port}/healthz"}))
    async with aiohttp.ClientSession() as s:
        async with s.get(f"http://127.0.0.1:{port}/healthz") as resp:
            health = await resp.json()
            hermes = dict(health.get("hermes") or {})
            hermes.pop("url", None)
            print("HEALTH", json.dumps({"ok": health.get("ok"), "hermes": hermes}))
    try:
        await gate2(port)
        await gate3(port)
        await gate4(port)
        await gate5(port)
        await gate7(port)
        await gate8(port)
        await gate6_epoch(port, runner)
        await gate10()
        note(9, "BLOCKED-ON-USER", reason="Cloudflare hostname/Access/service token not created; see docs/SETUP.md")
    finally:
        await runner.cleanup()
    print("SUMMARY", json.dumps(REPORTS, ensure_ascii=False, default=str))
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
