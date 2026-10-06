"""Shared test helpers. Never embed real tokens."""

from __future__ import annotations

import asyncio
from typing import Any

from hermes_harmony_bridge.discovery import HermesEndpoint
from hermes_harmony_bridge.hermes import HermesError


class FakeHermes:
    """In-process stand-in for HermesClient used by unit tests."""

    def __init__(self):
        self.endpoint = HermesEndpoint(url="http://127.0.0.1:9", token="unit-test-token", tier=2)
        self.replay_epoch = "epoch-aaa"
        self._ready = True
        self._handlers = []
        self.created = 0
        self.stored_to_live: dict[str, str] = {}
        self.resume_calls: list[str] = []
        self.since_calls: list[tuple[str, int]] = []
        self.prompts: list[tuple[str, str]] = []
        self.last_user_row_id = ""
        self.approvals: list[dict] = []
        self.server_requests: dict[str, dict] = {}
        self.server_request_responses: list[dict] = []
        self.server_request_rejections: list[dict] = []
        self.interrupts: list[str] = []
        self.buffers: dict[str, list[dict]] = {}
        self.evicted_through: dict[str, int] = {}
        self.latest: dict[str, int] = {}
        self.sessions = []
        self.archived = []
        self.pending_approvals: dict[str, list[dict]] = {}
        self.running_sessions: set[str] = set()
        self.transcript = "unit transcript"
        self.transcribe_calls = 0
        self.attaches: list[dict] = []
        self.speak_pcm = b"\x00\x01" * 80
        self.stream_fallback = False
        self.voice_ready = True

    async def voice_capabilities(self, *, profile=None) -> dict:
        return {"ready": self.voice_ready, "stt": self.voice_ready, "tts": self.voice_ready,
                "ffmpeg": self.voice_ready, "reason": "电脑语音配置已就绪。" if self.voice_ready else "电脑尚未完成语音配置。"}

    @property
    def connected(self) -> bool:
        return self._ready

    @property
    def base_url(self) -> str:
        return self.endpoint.url

    @property
    def discovery_tier(self) -> int:
        return self.endpoint.tier

    def bind(self, endpoint):
        self.endpoint = endpoint

    def on_event(self, handler):
        self._handlers.append(handler)

    async def close(self, *, clear_server_requests: bool = True):
        self._ready = False
        if clear_server_requests:
            self.server_requests.clear()

    async def ensure_connected(self, *, attempts: int = 6):
        self._ready = True

    async def emit(self, params: dict):
        for handler in list(self._handlers):
            result = handler(params)
            if asyncio.iscoroutine(result):
                await result

    def add_event(self, sid: str, typ: str, payload: dict | None = None) -> dict:
        seq = self.latest.get(sid, 0) + 1
        self.latest[sid] = seq
        ev = {"type": typ, "session_id": sid, "payload": payload or {}, "seq": seq}
        self.buffers.setdefault(sid, []).append(ev)
        buf = self.buffers[sid]
        if len(buf) > 512:
            dropped = buf.pop(0)
            self.evicted_through[sid] = max(self.evicted_through.get(sid, 0), int(dropped["seq"]))
        return ev

    def restore_server_request(self, frame: dict) -> dict | None:
        request_id = frame.get("id")
        method = frame.get("method")
        params = frame.get("params") or {}
        event_type = {"approval": "approval.request", "clarify": "clarify.request"}.get(method)
        if not isinstance(request_id, str) or not isinstance(params, dict) or not event_type:
            return None
        sid = params.get("session_id")
        if not isinstance(sid, str) or not sid:
            return None
        self.server_requests[request_id] = {"method": method, "session_id": sid}
        payload = {key: value for key, value in params.items() if key != "session_id"}
        payload["harmony_server_request_id"] = request_id
        payload["harmony_server_request_method"] = method
        return {"type": event_type, "session_id": sid, "payload": payload}

    async def respond_server_request(self, request_id: str, result: dict, *, expected_method=None) -> None:
        request = self.server_requests.get(request_id)
        if request is None or (expected_method and request.get("method") != expected_method):
            raise HermesError("server request is no longer open")
        self.server_request_responses.append({"id": request_id, "result": result})
        self.server_requests.pop(request_id, None)

    async def reject_server_request(self, request_id: str, message: str) -> None:
        self.server_request_rejections.append({"id": request_id, "message": message})

    async def session_create(self, **kwargs) -> dict:
        self.created += 1
        sid = f"rt{self.created:04d}"
        stored = f"stored-{sid}"
        self.stored_to_live[stored] = sid
        self.latest[sid] = 0
        return {"session_id": sid, "stored_session_id": stored, "messages": [], "info": {}}

    async def session_resume(self, session_id: str) -> dict:
        self.resume_calls.append(session_id)
        live = self.stored_to_live.get(session_id, session_id)
        running = live in self.running_sessions or session_id in self.running_sessions
        return {
            "session_id": live,
            "stored_session_id": session_id,
            "messages": [{"role": "user", "content": "hi"}],
            "inflight": {"running": True} if running else None,
            "running": running,
            "pending_approval": self.pending_approvals.get(live) or None,
        }

    async def session_events_since(self, session_id: str, last_seen: int) -> dict:
        self.since_calls.append((session_id, last_seen))
        buf = self.buffers.get(session_id, [])
        truncated = last_seen < self.evicted_through.get(session_id, 0)
        events = [e for e in buf if int(e["seq"]) > last_seen]
        return {
            "events": events,
            "latest_seq": self.latest.get(session_id, 0),
            "truncated": truncated,
            "count": len(events),
            "epoch": self.replay_epoch,
        }

    async def session_list(self) -> dict:
        return {"sessions": list(self.sessions)}

    async def archived_sessions(self) -> list[dict]:
        return list(self.archived)

    async def session_set_archived(self, session_id: str, archived: bool) -> dict:
        if archived:
            if not any(str(row.get("id") or "") == session_id for row in self.archived):
                self.archived.append({"id": session_id, "title": session_id})
        else:
            self.archived = [row for row in self.archived if str(row.get("id") or "") != session_id]
        return {"ok": True, "archived": archived}

    async def session_delete(self, session_id: str) -> dict:
        self.sessions = [
            row for row in self.sessions
            if str(row.get("stored_session_id") or row.get("id") or "") != session_id
        ]
        self.archived = [row for row in self.archived if str(row.get("id") or "") != session_id]
        return {"ok": True}

    async def prompt_submit(self, session_id: str, text: str, **extra) -> dict:
        self.prompts.append((session_id, text))
        self.last_user_row_id = f"user-row-{len(self.prompts)}"
        start = self.add_event(session_id, "message.start")
        delta = self.add_event(session_id, "message.delta", {"text": "pong"})
        complete = self.add_event(session_id, "message.complete", {
            "text": "pong", "status": "ok",
            "persisted_turn": {"user_row_id": self.last_user_row_id},
        })
        for ev in (start, delta, complete):
            await self.emit(ev)
        return {"status": "streaming", "user_row_id": self.last_user_row_id, **extra}

    async def session_interrupt(self, session_id: str) -> None:
        self.interrupts.append(session_id)

    async def approval_respond(self, session_id: str, choice: str, request_id: str | None = None) -> dict:
        if not choice:
            raise HermesError("approval choice required; refusing to default")
        self.approvals.append({"session_id": session_id, "choice": choice, "request_id": request_id})
        return {"resolved": 1}

    async def approval_pending(self, session_id: str) -> dict:
        return {"approvals": self.pending_approvals.get(session_id, [])}

    async def clarify_respond(self, session_id: str, request_id: str, answer: Any) -> dict:
        return {"status": "ok"}

    async def transcribe(self, wav_bytes: bytes, *, profile=None) -> str:
        self.transcribe_calls += 1
        return self.transcript

    async def file_attach(self, session_id: str, data_url: str, name: str) -> dict:
        self.attaches.append({"session_id": session_id, "name": name, "data_url": data_url})
        ref = f"@file:attachments/{name}"
        return {
            "attached": True,
            "name": name,
            "path": f"/tmp/{name}",
            "ref_path": f"attachments/{name}",
            "ref_text": ref,
            "uploaded": True,
        }

    async def file_attach_wav(self, session_id: str, wav_bytes: bytes, *, name: str) -> dict:
        return await self.file_attach(session_id, f"data:audio/wav;base64,{len(wav_bytes)}", name)

    async def speak(self, text: str, *, profile=None) -> tuple[bytes, str]:
        from hermes_harmony_bridge.audio import pcm16_to_wav

        return pcm16_to_wav(self.speak_pcm), "audio/wav"

    async def speak_stream(self, text: str, *, profile=None):
        if self.stream_fallback:
            yield ("fallback", None)
            return
        yield ("start", {"type": "start", "sample_rate": 16000, "channels": 1})
        yield ("pcm", self.speak_pcm)
        yield ("end", {"type": "end"})
