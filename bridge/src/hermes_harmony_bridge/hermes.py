"""Hermes dashboard HTTP + persistent JSON-RPC WebSocket client.

Ported from hermes-cardputer and extended with session.list, approval.*,
clarify.respond, and speak-stream. Never log the session token.
"""

from __future__ import annotations

import asyncio
import base64
import itertools
import json
import logging
from urllib.parse import quote, urlencode
from collections.abc import AsyncIterator, Awaitable, Callable
from typing import Any

import aiohttp

from hermes_harmony_bridge.discovery import HermesEndpoint

log = logging.getLogger(__name__)
EventHandler = Callable[[dict[str, Any]], Awaitable[None] | None]


class HermesError(RuntimeError):
    pass


def _active_command_voice_provider(config: dict, name: str) -> bool:
    """Return whether the selected STT/TTS provider has a valid command block.

    Hermes' provider-picker API only reports built-in and registry-backed rows;
    custom command providers can be active in config without appearing there.
    Keep this discriminator aligned with Hermes: ``type`` is optional or
    ``command`` (case-insensitive), and ``command`` must be a non-empty string.
    """
    section = config.get(name)
    if not isinstance(section, dict):
        return False
    provider = section.get("provider")
    if not isinstance(provider, str) or not provider.strip():
        return False
    providers = section.get("providers")
    block = providers.get(provider) if isinstance(providers, dict) else None
    if not isinstance(block, dict):
        # Hermes also supports the legacy ``<kind>.<provider>`` layout.
        block = section.get(provider)
    if not isinstance(block, dict):
        return False
    provider_type = str(block.get("type") or "").strip().lower()
    command = block.get("command")
    return provider_type in ("", "command") and isinstance(command, str) and bool(command.strip())


def voice_turn_text(*, ref_text: str, name: str, seconds: float, transcript_hint: str = "") -> str:
    """Hidden voice note: preserve the attachment and optionally provide a private transcript hint."""
    dur = max(1, int(round(seconds)))
    note = (
        f"[The user sent a voice message: '{name}'. "
        f"It is saved at: {ref_text}. "
        f"Duration: {dur}s. "
    )
    hint = transcript_hint.strip()
    if hint:
        return (
            note
            + f"A private server-side transcript hint is: {json.dumps(hint, ensure_ascii=False)}. "
            "Use it to understand the attached audio, do not mention transcription, "
            "and reply directly to what the user said.]"
        )
    return (
        note
        + "Its content is not inlined here. Transcribe or process it yourself instead "
        "of asking the user to type it. Then reply to what they said.]"
    )


class HermesClient:
    def __init__(self, session: aiohttp.ClientSession):
        self._http = session
        self.endpoint: HermesEndpoint | None = None
        self._ws: aiohttp.ClientWebSocketResponse | None = None
        self._reader_task: asyncio.Task | None = None
        self._pending: dict[str, asyncio.Future] = {}
        self._server_requests: dict[str, dict[str, Any]] = {}
        self._id = itertools.count(1)
        self._lock = asyncio.Lock()
        self._write_lock = asyncio.Lock()
        self._ready = asyncio.Event()
        self._server_request_capabilities_ready = asyncio.Event()
        self._server_requests_enabled = False
        self._capability_task: asyncio.Task | None = None
        self._event_handlers: list[EventHandler] = []
        self.replay_epoch: str | None = None

    @property
    def connected(self) -> bool:
        return self._ws is not None and not self._ws.closed and self._ready.is_set()

    @property
    def base_url(self) -> str | None:
        return self.endpoint.safe_url if self.endpoint else None

    @property
    def discovery_tier(self) -> int | None:
        return self.endpoint.tier if self.endpoint else None

    def on_event(self, handler: EventHandler) -> None:
        self._event_handlers.append(handler)

    def off_event(self, handler: EventHandler) -> None:
        try:
            self._event_handlers.remove(handler)
        except ValueError:
            pass

    def bind(self, endpoint: HermesEndpoint) -> None:
        self.endpoint = endpoint

    def _headers(self) -> dict[str, str]:
        if not self.endpoint:
            raise HermesError("Hermes endpoint not bound")
        return {"X-Hermes-Session-Token": self.endpoint.token}

    async def voice_capabilities(self, *, profile: str | None = None) -> dict:
        """Read readiness from the active Hermes profile; never forward credentials.

        Older dashboards without provider readiness fail closed. This checks
        configuration/dependencies, not provider connectivity or account quota.
        """
        from hermes_harmony_bridge.audio import ffmpeg_available

        result = {"ready": False, "stt": False, "tts": False,
                  "ffmpeg": ffmpeg_available(), "reason": "无法检查电脑语音配置，请更新 Hermes 并重试。"}
        if not self.connected or self.endpoint is None:
            result["reason"] = "电脑 Hermes 尚未连接。"
            return result

        async def read(path: str):
            async with self._http.get(
                f"{self.endpoint.url}{path}", headers=self._headers(),
                params={"profile": profile} if profile else None,
                timeout=aiohttp.ClientTimeout(total=5),
            ) as response:
                if response.status != 200:
                    raise HermesError("voice readiness API unavailable")
                return await response.json()

        try:
            toolsets, stt, tts = await asyncio.gather(
                read("/api/tools/toolsets"),
                read("/api/tools/toolsets/stt/config"),
                read("/api/tools/toolsets/tts/config"),
            )
            active_config = None
            for name, config in (("stt", stt), ("tts", tts)):
                enabled = any(row.get("name") == name and row.get("enabled") is True
                              for row in toolsets if isinstance(row, dict))
                provider_ready = any(
                    row.get("is_active") is True and row.get("status") == "ready"
                    for row in config.get("providers", []) if isinstance(row, dict)
                )
                # Custom command providers are valid active providers even when
                # Hermes omits them from the provider-picker matrix. Read only
                # the local config here; never forward command text or secrets.
                if not provider_ready:
                    if active_config is None:
                        try:
                            active_config = await read("/api/config")
                        except Exception:
                            active_config = {}
                    provider_ready = _active_command_voice_provider(active_config, name)
                result[name] = enabled and provider_ready
            result["ready"] = result["stt"] and result["tts"] and result["ffmpeg"]
            missing = [label for key, label in (("stt", "语音识别"), ("tts", "语音合成"),
                                                ("ffmpeg", "FFmpeg 音频依赖")) if not result[key]]
            result["reason"] = "电脑语音配置已就绪。" if not missing else "电脑尚未完成：" + "、".join(missing) + "。"
        except Exception:
            # No provider response, exception detail or secret is exposed to phones.
            pass
        return result

    async def close(self, *, clear_server_requests: bool = True) -> None:
        capability_task = self._capability_task
        self._capability_task = None
        if capability_task and capability_task is not asyncio.current_task() and not capability_task.done():
            capability_task.cancel()
            await asyncio.gather(capability_task, return_exceptions=True)
        if self._reader_task:
            self._reader_task.cancel()
            try:
                await self._reader_task
            except (asyncio.CancelledError, Exception):
                pass
            self._reader_task = None
        if self._ws is not None and not self._ws.closed:
            await self._ws.close()
        self._ws = None
        self._ready.clear()
        self._server_request_capabilities_ready.clear()
        self._server_requests_enabled = False
        if clear_server_requests:
            self._server_requests.clear()
        self._fail_pending(HermesError("hermes client closed"))

    async def ensure_connected(self, *, attempts: int = 6) -> None:
        if self.connected:
            if (self._server_request_capabilities_ready.is_set()
                    or asyncio.current_task() is self._capability_task):
                return
            try:
                await asyncio.wait_for(self._server_request_capabilities_ready.wait(), timeout=10)
            except asyncio.TimeoutError as exc:
                raise HermesError("Hermes capability handshake timed out") from exc
            return
        delay = 0.5
        last_exc: Exception | None = None
        for attempt in range(max(1, attempts)):
            try:
                await self._connect()
                return
            except Exception as exc:
                last_exc = exc
                log.warning("hermes ws connect failed: %s", type(exc).__name__)
                if attempt + 1 < max(1, attempts):
                    await asyncio.sleep(delay)
                delay = min(delay * 2, 8.0)
        raise HermesError("hermes ws connect failed") from last_exc

    async def _connect(self) -> None:
        if not self.endpoint:
            raise HermesError("Hermes endpoint not bound")
        async with self._lock:
            if self.connected:
                return
            await self.close(clear_server_requests=False)
            self._ready.clear()
            # Hermes loopback WS auth reads query token, unlike HTTP header auth.
            # Connection failures must log exception types only, never this URL.
            ws_url = self.endpoint.ws_url + "?" + urlencode({"token": self.endpoint.token})
            self._ws = await self._http.ws_connect(
                ws_url, heartbeat=20.0, autoping=True, headers=self._headers()
            )
            if self._reader_task:
                self._reader_task.cancel()
            self._reader_task = asyncio.create_task(self._read_loop(), name="hermes-ws-reader")
            try:
                await asyncio.wait_for(self._ready.wait(), timeout=10)
                await asyncio.wait_for(self._server_request_capabilities_ready.wait(), timeout=10)
            except BaseException:
                await self.close()
                raise

    async def _read_loop(self) -> None:
        ws = self._ws
        if ws is None:
            return
        try:
            async for msg in ws:
                if msg.type == aiohttp.WSMsgType.TEXT:
                    for line in msg.data.splitlines():
                        if line.strip():
                            self._dispatch(line.strip())
                elif msg.type in (aiohttp.WSMsgType.CLOSE, aiohttp.WSMsgType.CLOSED, aiohttp.WSMsgType.ERROR):
                    break
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("Hermes WS reader failed")
        finally:
            if self._ws is ws:
                self._ready.clear()
                self._fail_pending(HermesError("Hermes WS disconnected"))
                self._ws = None
            if not ws.closed:
                await ws.close()

    def _dispatch(self, line: str) -> None:
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            return
        if not isinstance(obj, dict):
            return
        msg_id = obj.get("id")
        if msg_id is not None and str(msg_id) in self._pending:
            fut = self._pending.pop(str(msg_id))
            if not fut.done():
                if "error" in obj:
                    err = obj["error"]
                    if isinstance(err, dict):
                        fut.set_exception(HermesError(f"RPC {err.get('code')}: {err.get('message')}"))
                    else:
                        fut.set_exception(HermesError("RPC failed"))
                else:
                    fut.set_result(obj.get("result"))
            return
        method = obj.get("method")
        if msg_id is not None and isinstance(method, str) and method != "event":
            event = self._server_request_event(obj)
            if event is None:
                asyncio.create_task(self._write_frame({
                    "jsonrpc": "2.0",
                    "id": msg_id,
                    "error": {"code": -32601, "message": "Unsupported server request"},
                }))
                return
            for handler in list(self._event_handlers):
                try:
                    result = handler(event)
                    if asyncio.iscoroutine(result):
                        asyncio.create_task(result)
                except Exception:
                    log.exception("server request handler failed")
            return
        if obj.get("method") == "event":
            params = obj.get("params") or {}
            if not isinstance(params, dict):
                return
            if params.get("type") == "gateway.ready":
                self.replay_epoch = (params.get("payload") or {}).get("replay_epoch")
                self._ready.set()
                self._server_request_capabilities_ready.clear()
                self._capability_task = asyncio.create_task(
                    self._advertise_server_requests(), name="hermes-server-request-capabilities"
                )
            elif params.get("type") == "request.cancel":
                payload = params.get("payload") or {}
                request_id = payload.get("id") if isinstance(payload, dict) else None
                if isinstance(request_id, str):
                    self._server_requests.pop(request_id, None)
            for handler in list(self._event_handlers):
                try:
                    result = handler(params)
                    if asyncio.iscoroutine(result):
                        asyncio.create_task(result)
                except Exception:
                    log.exception("event handler failed")

    async def _advertise_server_requests(self) -> None:
        try:
            result = await self.rpc(
                "client.capabilities", {"server_requests": True}, timeout=10
            )
            self._server_requests_enabled = isinstance(result, dict)
        except Exception as exc:
            # Older Hermes versions do not have this capability method. Keep the
            # legacy approval.respond / clarify.respond path available there.
            log.info("Hermes server-request capability unavailable: %s", type(exc).__name__)
        finally:
            self._server_request_capabilities_ready.set()

    def _server_request_event(self, frame: dict[str, Any]) -> dict[str, Any] | None:
        request_id = frame.get("id")
        method = frame.get("method")
        params = frame.get("params") or {}
        if (not isinstance(request_id, str) or not isinstance(method, str)
                or not isinstance(params, dict)):
            return None
        event_type = {"approval": "approval.request", "clarify": "clarify.request"}.get(method)
        if event_type is None:
            return None
        if method == "clarify" and isinstance(params.get("questions"), list):
            # Batch clarification needs per-question editing/locking in the phone
            # UI; reject it promptly until that interaction is available.
            return None
        session_id = params.get("session_id")
        if not isinstance(session_id, str) or not session_id:
            return None
        self._server_requests[request_id] = {"method": method, "session_id": session_id}
        payload = {key: value for key, value in params.items() if key != "session_id"}
        payload["harmony_server_request_id"] = request_id
        payload["harmony_server_request_method"] = method
        return {"type": event_type, "session_id": session_id, "payload": payload}

    def restore_server_request(self, frame: dict[str, Any]) -> dict[str, Any] | None:
        """Register an unanswered request from session.resume/events.since and render its card."""
        return self._server_request_event(frame)

    async def reject_server_request(self, request_id: str, message: str) -> None:
        await self.ensure_connected()
        await self._write_frame({
            "jsonrpc": "2.0",
            "id": request_id,
            "error": {"code": -32601, "message": message},
        })

    async def respond_server_request(
        self, request_id: str, result: dict[str, Any], *, expected_method: str | None = None
    ) -> None:
        if not request_id:
            raise HermesError("server request ID required")
        await self.ensure_connected()
        async with self._write_lock:
            request = self._server_requests.get(request_id)
            if request is None:
                raise HermesError("server request is no longer open")
            if expected_method and request.get("method") != expected_method:
                raise HermesError("server request method does not match the response")
            await self._write_frame_locked({"jsonrpc": "2.0", "id": request_id, "result": result})
            self._server_requests.pop(request_id, None)

    async def _write_frame(self, frame: dict[str, Any]) -> None:
        async with self._write_lock:
            await self._write_frame_locked(frame)

    async def _write_frame_locked(self, frame: dict[str, Any]) -> None:
        ws = self._ws
        if ws is None or ws.closed:
            raise HermesError("Hermes WS not connected")
        await ws.send_str(json.dumps(frame, ensure_ascii=False) + "\n")

    def _fail_pending(self, exc: Exception) -> None:
        pending = list(self._pending.items())
        self._pending.clear()
        for _, fut in pending:
            if not fut.done():
                fut.set_exception(exc)

    async def rpc(self, method: str, params: dict | None = None, *, timeout: float = 30.0) -> Any:
        await self.ensure_connected()
        ws = self._ws
        if ws is None:
            raise HermesError("Hermes WS not connected")
        rid = f"h{next(self._id)}"
        fut: asyncio.Future = asyncio.get_running_loop().create_future()
        self._pending[rid] = fut
        try:
            await self._write_frame(
                    {"jsonrpc": "2.0", "id": rid, "method": method, "params": params or {}},
            )
            return await asyncio.wait_for(fut, timeout=timeout)
        finally:
            self._pending.pop(rid, None)

    async def transcribe(self, wav_bytes: bytes, *, profile: str | None = None) -> str:
        encoded = base64.b64encode(wav_bytes).decode("ascii")
        async with self._http.post(
            f"{self.endpoint.url}/api/audio/transcribe",
            params={"profile": profile} if profile else None,
            json={"data_url": f"data:audio/wav;base64,{encoded}", "mime_type": "audio/wav"},
            headers=self._headers(),
        ) as resp:
            if resp.status >= 400:
                raise HermesError(f"transcribe HTTP {resp.status}: {(await resp.text())[:300]}")
            data = await resp.json()
        return str(data.get("transcript") or "").strip()

    async def file_attach(self, session_id: str, data_url: str, name: str) -> dict:
        return await self.rpc(
            "file.attach",
            {"session_id": session_id, "data_url": data_url, "name": name},
            timeout=60,
        ) or {}

    async def file_attach_wav(self, session_id: str, wav_bytes: bytes, *, name: str) -> dict:
        encoded = base64.b64encode(wav_bytes).decode("ascii")
        return await self.file_attach(
            session_id, f"data:audio/wav;base64,{encoded}", name
        )

    async def speak(self, text: str, *, profile: str | None = None) -> tuple[bytes, str]:
        async with self._http.post(
            f"{self.endpoint.url}/api/audio/speak", json={"text": text}, headers=self._headers(),
            params={"profile": profile} if profile else None
        ) as resp:
            if resp.status >= 400:
                raise HermesError(f"speak HTTP {resp.status}: {(await resp.text())[:300]}")
            data = await resp.json()
        data_url = str(data.get("data_url") or "")
        mime = str(data.get("mime_type") or "audio/ogg")
        if "," not in data_url:
            raise HermesError("speak response missing data_url")
        _, encoded = data_url.split(",", 1)
        return base64.b64decode(encoded), mime

    async def speak_stream(self, text: str, *, profile: str | None = None) -> AsyncIterator[tuple[str, Any]]:
        """Yield ('start', meta) | ('pcm', bytes) | ('end', None) | ('fallback', None).

        Protocol from hermes_cli/web_routers/audio.py speak-stream: client sends
        {text} then {done:true}; server sends {type:start,...} then binary PCM
        then {type:end}, or {type:fallback} when the provider has no chunked API.
        """
        if not self.endpoint:
            raise HermesError("Hermes endpoint not bound")
        url = f"{self.endpoint.url.replace('http://', 'ws://').replace('https://', 'wss://')}/api/audio/speak-stream" + "?" + urlencode({"token": self.endpoint.token, **({"profile": profile} if profile else {})})
        try:
            async with self._http.ws_connect(url, heartbeat=20.0, headers=self._headers()) as ws:
                await ws.send_str(json.dumps({"text": text}))
                await ws.send_str(json.dumps({"done": True}))
                async for msg in ws:
                    if msg.type == aiohttp.WSMsgType.BINARY:
                        yield ("pcm", msg.data)
                    elif msg.type == aiohttp.WSMsgType.TEXT:
                        try:
                            obj = json.loads(msg.data)
                        except json.JSONDecodeError:
                            continue
                        kind = obj.get("type")
                        if kind == "start":
                            yield ("start", obj)
                        elif kind == "end":
                            yield ("end", obj)
                            return
                        elif kind == "fallback":
                            yield ("fallback", obj)
                            return
                    elif msg.type in (aiohttp.WSMsgType.CLOSE, aiohttp.WSMsgType.CLOSED, aiohttp.WSMsgType.ERROR):
                        break
        except Exception as exc:
            log.info("speak-stream failed (%s); caller should fall back to POST speak", type(exc).__name__)
            yield ("fallback", None)

    async def session_create(
        self,
        *,
        source: str = "harmony",
        profile: str | None = None,
        title: str = "Harmony",
        cwd: str | None = None,
    ) -> dict:
        params: dict[str, Any] = {"source": source, "title": title, "close_on_disconnect": False}
        if profile:
            params["profile"] = profile
        if cwd:
            params["cwd"] = cwd
        return await self.rpc("session.create", params, timeout=30) or {}

    async def session_resume(self, session_id: str) -> dict:
        return await self.rpc("session.resume", {"session_id": session_id}, timeout=60) or {}

    async def session_events_since(self, session_id: str, last_seen: int) -> dict:
        return await self.rpc(
            "session.events.since",
            {"session_id": session_id, "last_seen": last_seen},
            timeout=15,
        ) or {}

    async def session_list(self) -> dict:
        return await self.rpc("session.list", {}, timeout=30) or {}

    async def archived_sessions(self) -> list[dict[str, Any]]:
        """Read the recoverable archive through Hermes' authenticated sessions API."""
        if not self.endpoint:
            raise HermesError("Hermes endpoint not bound")
        rows: list[dict[str, Any]] = []
        limit = 100
        max_rows = 2000
        for offset in range(0, max_rows, limit):
            async with self._http.get(
                f"{self.endpoint.url}/api/sessions",
                params={"archived": "only", "order": "recent", "limit": str(limit), "offset": str(offset)},
                headers=self._headers(),
            ) as resp:
                if resp.status >= 400:
                    raise HermesError(f"archived sessions HTTP {resp.status}")
                data = await resp.json()
            page = data.get("sessions") if isinstance(data, dict) else None
            if not isinstance(page, list):
                raise HermesError("archived sessions response is invalid")
            rows.extend(row for row in page if isinstance(row, dict))
            if len(page) < limit:
                break
        return rows

    async def session_set_archived(self, session_id: str, archived: bool) -> dict:
        if not self.endpoint:
            raise HermesError("Hermes endpoint not bound")
        async with self._http.patch(
            f"{self.endpoint.url}/api/sessions/{quote(session_id, safe='')}",
            json={"archived": archived},
            headers=self._headers(),
        ) as resp:
            if resp.status >= 400:
                raise HermesError(f"session archive HTTP {resp.status}")
            data = await resp.json()
        return data if isinstance(data, dict) else {}

    async def session_delete(self, session_id: str) -> dict:
        if not self.endpoint:
            raise HermesError("Hermes endpoint not bound")
        async with self._http.delete(
            f"{self.endpoint.url}/api/sessions/{quote(session_id, safe='')}",
            headers=self._headers(),
        ) as resp:
            if resp.status >= 400:
                raise HermesError(f"session delete HTTP {resp.status}")
            data = await resp.json()
        return data if isinstance(data, dict) else {}

    async def prompt_submit(self, session_id: str, text: str, **extra: Any) -> dict:
        params: dict[str, Any] = {"session_id": session_id, "text": text, **extra}
        return await self.rpc("prompt.submit", params, timeout=30) or {}

    async def session_interrupt(self, session_id: str) -> None:
        await self.rpc("session.interrupt", {"session_id": session_id}, timeout=10)

    async def approval_respond(self, session_id: str, choice: str, request_id: str | None = None) -> dict:
        if not choice:
            raise HermesError("approval choice required; refusing to default")
        params: dict[str, Any] = {"session_id": session_id, "choice": choice}
        if request_id:
            params["request_id"] = request_id
        return await self.rpc("approval.respond", params, timeout=30) or {}

    async def approval_pending(self, session_id: str) -> dict:
        return await self.rpc("approval.pending", {"session_id": session_id}, timeout=15) or {}

    async def clarify_respond(self, session_id: str, request_id: str, answer: Any) -> dict:
        params: dict[str, Any] = {
            "session_id": session_id,
            "request_id": request_id,
            "answer": answer,
        }
        return await self.rpc("clarify.respond", params, timeout=30) or {}

    async def config_set(self, key: str, value: Any, session_id: str | None = None, **extra: Any) -> dict:
        params: dict[str, Any] = {"key": key, "value": value, **extra}
        if session_id:
            params["session_id"] = session_id
        return await self.rpc("config.set", params, timeout=15) or {}
