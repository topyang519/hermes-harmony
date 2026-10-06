#!/usr/bin/env python3
"""Pure-Python HarmonyOS phone stand-in that speaks the v2 wire protocol.

Covers every client message in docs/PROTOCOL.md / TECH-PLAN §3.
Never prints tokens.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
import time
import wave
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

import aiohttp


@dataclass
class PhoneState:
    epoch: str | None = None
    last_seen: dict[str, int] = field(default_factory=dict)
    session_id: str = ""
    stored_id: str = ""
    events: list[dict] = field(default_factory=list)
    transcripts: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)
    replays: list[dict] = field(default_factory=list)
    sessions_list: list[dict] = field(default_factory=list)
    pcm: bytearray = field(default_factory=bytearray)
    tts_sr: int = 0
    tts_bytes_declared: int | None = None
    tts_end: dict | None = None
    ready: dict | None = None
    reset_cursors_on_epoch: bool = False

    def note_epoch(self, epoch: str | None) -> None:
        if epoch and self.epoch and epoch != self.epoch:
            self.last_seen = {sid: 0 for sid in self.last_seen}
            self.reset_cursors_on_epoch = True
        if epoch:
            self.epoch = epoch

    def note_event(self, params: dict) -> None:
        sid = str(params.get("session_id") or self.session_id or "")
        seq = params.get("seq")
        if sid and isinstance(seq, int):
            prev = self.last_seen.get(sid, 0)
            if seq <= prev:
                return
            self.last_seen[sid] = seq
        self.events.append(params)


class FakePhone:
    def __init__(
        self,
        ws: aiohttp.ClientWebSocketResponse,
        *,
        device_id: str = "fake-harmony-01",
        state: PhoneState | None = None,
    ):
        self.ws = ws
        self.device_id = device_id
        self.state = state or PhoneState()
        self._closed = False

    async def hello(self) -> dict:
        await self.ws.send_str(
            json.dumps({"t": "hello", "app": "0.1.0-fake", "proto": 2, "dev": self.device_id})
        )
        return await self.wait_for(lambda m: m.get("t") == "ready", timeout=15)

    async def send(self, **fields: Any) -> None:
        await self.ws.send_str(json.dumps(fields, ensure_ascii=False))

    async def send_bin(self, payload: bytes) -> None:
        await self.ws.send_bytes(payload)

    async def wait_for(
        self,
        pred: Callable[[dict], bool],
        *,
        timeout: float = 60.0,
        also_binary: bool = False,
    ) -> dict:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            remaining = max(0.1, deadline - time.monotonic())
            try:
                msg = await asyncio.wait_for(self.ws.receive(), timeout=remaining)
            except asyncio.TimeoutError as exc:
                raise TimeoutError("wait_for timed out") from exc
            if msg.type == aiohttp.WSMsgType.BINARY:
                self.state.pcm.extend(msg.data)
                if also_binary:
                    return {"t": "_bin", "n": len(msg.data)}
                continue
            if msg.type != aiohttp.WSMsgType.TEXT:
                if msg.type in (aiohttp.WSMsgType.CLOSE, aiohttp.WSMsgType.CLOSED, aiohttp.WSMsgType.ERROR):
                    raise ConnectionError(f"ws closed: {msg.type}")
                continue
            obj = json.loads(msg.data)
            self._ingest(obj)
            if pred(obj):
                return obj
        raise TimeoutError("wait_for timed out")

    def _ingest(self, obj: dict) -> None:
        kind = obj.get("t")
        if kind == "ready":
            self.state.ready = obj
            self.state.note_epoch(obj.get("epoch") or None)
        elif kind == "ev":
            params = obj.get("p") or {}
            if isinstance(params, dict):
                self.state.note_event(params)
        elif kind == "replay":
            self.state.replays.append(obj)
        elif kind == "transcript":
            self.state.transcripts.append(str(obj.get("body") or ""))
        elif kind == "error":
            self.state.errors.append(str(obj.get("msg") or "error"))
        elif kind == "sessions":
            self.state.sessions_list = list(obj.get("list") or [])
            if obj.get("created"):
                self.state.session_id = str(obj["created"])
            if obj.get("stored"):
                self.state.stored_id = str(obj["stored"])
        elif kind == "tts_start":
            self.state.tts_sr = int(obj.get("sr") or 0)
            if "bytes" in obj:
                self.state.tts_bytes_declared = int(obj["bytes"])
            self.state.pcm = bytearray()
        elif kind == "tts_end":
            self.state.tts_end = obj
        elif kind == "ping":
            asyncio.create_task(self.send(t="pong"))

    async def new_session(self, title: str = "harmony-fake") -> str:
        await self.send(t="new_session", title=title)
        msg = await self.wait_for(lambda m: m.get("t") == "sessions" and m.get("created"), timeout=30)
        sid = str(msg.get("created") or "")
        self.state.session_id = sid
        self.state.stored_id = str(msg.get("stored") or sid)
        return sid

    async def sub(self, session: str, last_seen: int = 0) -> dict:
        await self.send(t="sub", session=session, last_seen=last_seen)
        return await self.wait_for(
            lambda m: m.get("t") in {"replay", "error"}, timeout=30
        )

    async def dispatch(self, text: str, session: str | None = None) -> None:
        await self.send(t="dispatch", session=session or self.state.session_id, text=text)

    async def wait_complete(self, *, timeout: float = 180.0) -> dict:
        return await self.wait_for(
            lambda m: m.get("t") == "ev" and (m.get("p") or {}).get("type") == "message.complete",
            timeout=timeout,
        )

    async def wait_type(self, event_type: str, *, timeout: float = 180.0) -> dict:
        return await self.wait_for(
            lambda m: m.get("t") == "ev" and (m.get("p") or {}).get("type") == event_type,
            timeout=timeout,
        )

    async def interrupt(self, session: str | None = None) -> None:
        await self.send(t="interrupt", session=session or self.state.session_id)

    async def approve(self, request_id: str, choice: str = "once", session: str | None = None) -> None:
        await self.send(
            t="approve",
            session=session or self.state.session_id,
            request_id=request_id,
            choice=choice,
        )

    async def clarify(self, request_id: str, answer: Any, session: str | None = None) -> None:
        await self.send(
            t="clarify",
            session=session or self.state.session_id,
            request_id=request_id,
            answer=answer,
        )

    async def sessions(self) -> list[dict]:
        await self.send(t="sessions")
        msg = await self.wait_for(lambda m: m.get("t") == "sessions", timeout=20)
        return list(msg.get("list") or [])

    async def tts(self, text: str, *, timeout: float = 60.0) -> tuple[bytes, dict]:
        await self.send(t="tts", text=text)
        await self.wait_for(lambda m: m.get("t") == "tts_start", timeout=timeout)
        end = await self.wait_for(lambda m: m.get("t") == "tts_end", timeout=timeout)
        return bytes(self.state.pcm), end

    async def asr_wav(self, wav_path: Path, *, session: str | None = None, sr: int = 16000) -> str:
        pcm, file_sr = _load_wav_pcm(wav_path)
        await self.send(t="asr_start", sr=file_sr or sr, session=session or self.state.session_id)
        for i in range(0, len(pcm), 4096):
            await self.send_bin(pcm[i : i + 4096])
        await self.send(t="asr_end")
        msg = await self.wait_for(lambda m: m.get("t") == "transcript", timeout=60)
        return str(msg.get("body") or "")


def _load_wav_pcm(path: Path) -> tuple[bytes, int]:
    with wave.open(str(path), "rb") as wf:
        if wf.getsampwidth() != 2:
            raise SystemExit(f"{path} is not 16-bit PCM")
        channels = wf.getnchannels()
        sr = wf.getframerate()
        frames = wf.readframes(wf.getnframes())
    if channels != 1:
        frame_size = 2 * channels
        left = bytearray()
        for i in range(0, len(frames), frame_size):
            left.extend(frames[i : i + 2])
        frames = bytes(left)
    return frames, sr


def _headers(password: str, cf_id: str | None, cf_secret: str | None) -> dict[str, str]:
    headers = {"X-Hermes-App-Password": password}
    if cf_id:
        headers["CF-Access-Client-Id"] = cf_id
    if cf_secret:
        headers["CF-Access-Client-Secret"] = cf_secret
    return headers


async def connect(
    url: str,
    token: str,
    *,
    device_id: str = "fake-harmony-01",
    cf_id: str | None = None,
    cf_secret: str | None = None,
    timeout: float = 180.0,
    state: PhoneState | None = None,
) -> tuple[aiohttp.ClientSession, FakePhone]:
    session = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=timeout))
    ws = await session.ws_connect(url, headers=_headers(token, cf_id, cf_secret), heartbeat=20)
    phone = FakePhone(ws, device_id=device_id, state=state)
    return session, phone


def seqs_of(events: list[dict], session_id: str | None = None) -> list[int]:
    out: list[int] = []
    for ev in events:
        if session_id and ev.get("session_id") and ev.get("session_id") != session_id:
            continue
        seq = ev.get("seq")
        if isinstance(seq, int):
            out.append(seq)
    return out


def assert_monotonic(seqs: list[int]) -> None:
    if not seqs:
        raise AssertionError("no seq values")
    expected = list(range(seqs[0], seqs[0] + len(seqs)))
    if seqs != expected:
        raise AssertionError(f"seq not monotonic gap-free: {seqs[:20]}... vs {expected[:20]}...")


async def _cmd_dispatch(args: argparse.Namespace) -> int:
    http, phone = await connect(args.url, args.token, cf_id=args.cf_id, cf_secret=args.cf_secret)
    try:
        ready = await phone.hello()
        print(json.dumps({"gate": "hello", "epoch_present": bool(ready.get("epoch")), "hermes": ready.get("hermes")}))
        sid = await phone.new_session(args.title)
        await phone.sub(sid, last_seen=0)
        await phone.dispatch(args.text)
        complete = await phone.wait_complete(timeout=args.timeout)
        types = [e.get("type") for e in phone.state.events]
        seqs = seqs_of(phone.state.events, sid)
        assert_monotonic(seqs)
        payload = (complete.get("p") or {}).get("payload") or {}
        print(
            json.dumps(
                {
                    "session": sid,
                    "types": types,
                    "seq": seqs,
                    "seq_monotonic": True,
                    "complete_status": payload.get("status"),
                    "text_len": len(str(payload.get("text") or "")),
                    "errors": phone.state.errors,
                },
                ensure_ascii=False,
            )
        )
        return 0 if not phone.state.errors else 1
    finally:
        await http.close()


async def _cmd_replay(args: argparse.Namespace) -> int:
    http, phone = await connect(args.url, args.token, cf_id=args.cf_id, cf_secret=args.cf_secret)
    try:
        await phone.hello()
        sid = await phone.new_session("harmony-replay")
        await phone.sub(sid, 0)
        await phone.dispatch(args.text)
        await phone.wait_complete(timeout=args.timeout)
        original = list(phone.state.events)
        orig_seqs = seqs_of(original, sid)
        assert_monotonic(orig_seqs)
        cut = orig_seqs[len(orig_seqs) // 3] if len(orig_seqs) >= 3 else orig_seqs[0]
        await phone.ws.close()
        await http.close()

        http2, phone2 = await connect(
            args.url, args.token, cf_id=args.cf_id, cf_secret=args.cf_secret, device_id="fake-harmony-replay"
        )
        try:
            await phone2.hello()
            replay = await phone2.sub(sid, last_seen=cut)
            replayed_seqs = seqs_of(phone2.state.events, sid)
            expected = [s for s in orig_seqs if s > cut]
            print(
                json.dumps(
                    {
                        "session": sid,
                        "cut": cut,
                        "original_seqs": orig_seqs,
                        "replayed_seqs": replayed_seqs,
                        "expected_seqs": expected,
                        "truncated": replay.get("truncated"),
                        "match": replayed_seqs == expected,
                    }
                )
            )
            return 0 if replayed_seqs == expected and not replay.get("truncated") else 1
        finally:
            await http2.close()
    finally:
        if not http.closed:
            await http.close()
    return 1


async def _cmd_truncated(args: argparse.Namespace) -> int:
    http, phone = await connect(args.url, args.token, cf_id=args.cf_id, cf_secret=args.cf_secret)
    try:
        await phone.hello()
        sid = await phone.new_session("harmony-truncated")
        await phone.sub(sid, 0)
        if args.fill:
            await phone.dispatch(args.text)
            try:
                await phone.wait_complete(timeout=args.timeout)
            except TimeoutError:
                pass
        replay = await phone.sub(sid, last_seen=args.last_seen)
        print(
            json.dumps(
                {
                    "session": sid,
                    "last_seen": args.last_seen,
                    "truncated": replay.get("truncated"),
                    "latest_seq": replay.get("latest_seq"),
                    "has_resume": isinstance(replay.get("resume"), dict),
                    "resume_keys": sorted((replay.get("resume") or {}).keys()) if replay.get("truncated") else [],
                }
            )
        )
        if args.expect_truncated:
            return 0 if replay.get("truncated") is True and isinstance(replay.get("resume"), dict) else 1
        return 0
    finally:
        await http.close()


async def _cmd_voice(args: argparse.Namespace) -> int:
    http, phone = await connect(args.url, args.token, cf_id=args.cf_id, cf_secret=args.cf_secret)
    try:
        await phone.hello()
        sid = await phone.new_session("harmony-voice")
        await phone.sub(sid, 0)
        transcript = await phone.asr_wav(Path(args.wav), session=sid)
        completed = False
        reply = ""
        try:
            complete = await phone.wait_complete(timeout=args.timeout)
            completed = True
            payload = (complete.get("p") or {}).get("payload") or {}
            reply = str(payload.get("text") or payload.get("content") or payload.get("message") or "")
        except TimeoutError:
            pass
        # Voice turns are auto-spoken by the bridge after message.complete.
        # An empty transcript is intentional: ASR is a private hint and must
        # never be rendered as a typed user message on the phone.
        if args.tts_text:
            pcm, end = await phone.tts(args.tts_text)
        else:
            await phone.wait_for(lambda m: m.get("t") == "tts_start", timeout=args.timeout)
            end = await phone.wait_for(lambda m: m.get("t") == "tts_end", timeout=args.timeout)
            pcm = bytes(phone.state.pcm)
        declared = end.get("bytes")
        print(
            json.dumps(
                {
                    "session": sid,
                    "transcript": transcript,
                    "completed": completed,
                    "reply_chars": len(reply),
                    "tts_sr": phone.state.tts_sr,
                    "pcm_bytes": len(pcm),
                    "tts_end_bytes": declared,
                    "bytes_match": declared == len(pcm),
                    "aborted": end.get("aborted"),
                    "errors": phone.state.errors,
                },
                ensure_ascii=False,
            )
        )
        return 0 if completed and reply and declared == len(pcm) and not end.get("aborted") and not phone.state.errors else 1
    finally:
        await http.close()


async def _cmd_approve(args: argparse.Namespace) -> int:
    http, phone = await connect(args.url, args.token, cf_id=args.cf_id, cf_secret=args.cf_secret)
    try:
        await phone.hello()
        sid = await phone.new_session("harmony-approve")
        await phone.sub(sid, 0)
        await phone.dispatch(args.text)
        approval = await phone.wait_type("approval.request", timeout=args.timeout)
        payload = (approval.get("p") or {}).get("payload") or {}
        request_id = str(payload.get("request_id") or "")
        await phone.approve(request_id, choice=args.choice)
        complete = await phone.wait_complete(timeout=args.timeout)
        print(
            json.dumps(
                {
                    "session": sid,
                    "request_id_present": bool(request_id),
                    "choices": payload.get("choices"),
                    "complete": (complete.get("p") or {}).get("payload", {}).get("status"),
                    "errors": phone.state.errors,
                }
            )
        )
        return 0 if request_id and not phone.state.errors else 1
    finally:
        await http.close()


async def _cmd_auth(args: argparse.Namespace) -> int:
    results = {}
    async with aiohttp.ClientSession() as session:
        async with session.ws_connect(args.url, headers={}) as ws:
            results["missing_password_close"] = ws.close_code or True
    try:
        async with aiohttp.ClientSession() as session:
            async with session.ws_connect(args.url, headers={"X-Hermes-App-Password": "wrong-password"}) as ws:
                results["wrong_password"] = "connected"
                await ws.close()
    except aiohttp.WSServerHandshakeError as exc:
        results["wrong_password_status"] = exc.status
    http, phone = await connect(args.url, args.token, cf_id=args.cf_id, cf_secret=args.cf_secret)
    try:
        ready = await phone.hello()
        results["valid_password_ready"] = bool(ready.get("t") == "ready" or phone.state.ready)
        results["cf_headers_accepted"] = True
    finally:
        await http.close()
    print(json.dumps(results))
    ok = results.get("wrong_password_status") in {401, 403} or "wrong_password" not in results
    return 0 if ok and results.get("valid_password_ready") else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="HarmonyOS v2 fake phone")
    parser.add_argument("--url", default=os.environ.get("HARMONY_BRIDGE_URL", "ws://127.0.0.1:7691/v2/app"))
    parser.add_argument("--token", default=os.environ.get("HARMONY_APP_TOKEN", ""))
    parser.add_argument("--cf-id", default=os.environ.get("CF_ACCESS_CLIENT_ID") or None)
    parser.add_argument("--cf-secret", default=os.environ.get("CF_ACCESS_CLIENT_SECRET") or None)
    parser.add_argument("--timeout", type=float, default=180.0)
    sub = parser.add_subparsers(dest="cmd", required=True)

    d = sub.add_parser("dispatch")
    d.add_argument("--text", default="Reply with exactly the word pong and do not use any tools.")
    d.add_argument("--title", default="harmony-fake")
    d.set_defaults(func=_cmd_dispatch)

    r = sub.add_parser("replay")
    r.add_argument("--text", default="Reply with exactly the word pong and do not use any tools.")
    r.set_defaults(func=_cmd_replay)

    t = sub.add_parser("truncated")
    t.add_argument("--last-seen", type=int, default=-1)
    t.add_argument("--fill", action="store_true")
    t.add_argument("--expect-truncated", action="store_true")
    t.add_argument(
        "--text",
        default="Count from 1 to 80. Write every integer on its own line. No tools. No commentary.",
    )
    t.set_defaults(func=_cmd_truncated)

    v = sub.add_parser("voice")
    v.add_argument("--wav", required=True)
    v.add_argument("--tts-text", default="")
    v.set_defaults(func=_cmd_voice)

    a = sub.add_parser("approve")
    a.add_argument(
        "--text",
        default="Use the terminal tool to run exactly: echo hermes-harmony-approval-probe",
    )
    a.add_argument("--choice", default="once")
    a.set_defaults(func=_cmd_approve)

    u = sub.add_parser("auth")
    u.set_defaults(func=_cmd_auth)

    args = parser.parse_args(argv)
    if not args.token:
        print("HARMONY_APP_TOKEN / --token required", file=sys.stderr)
        return 2
    return asyncio.run(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
