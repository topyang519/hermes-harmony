"""Phone WebSocket server: /v2/app + /healthz. Port 7691. Never log tokens."""

from __future__ import annotations

import argparse
import asyncio
import hmac
import json
import logging
import os
import signal
import sys
import time
from collections import OrderedDict, defaultdict, deque
from pathlib import Path
from typing import Any

from aiohttp import WSMsgType, web
from aiohttp.web_log import AccessLogger

from hermes_harmony_bridge.audio import PcmAccumulator, chunk_bytes, ffmpeg_to_pcm_wav, parse_wav
from hermes_harmony_bridge.config import BridgeConfig, load_config
from hermes_harmony_bridge.discovery import discover_endpoint
from hermes_harmony_bridge.fanout import Fanout
from hermes_harmony_bridge.hermes import HermesClient, HermesError, voice_turn_text
from hermes_harmony_bridge.state import DeviceStore

log = logging.getLogger(__name__)
APPROVE_CHOICES = {"once", "session", "always", "deny"}
_SPEAK_SKIP_STATUS = {"error", "cancelled", "interrupted", "aborted"}


def assistant_speech_text(params: dict[str, Any]) -> str:
    """Visible assistant text from a Hermes message.complete, if it should be spoken."""
    if params.get("type") != "message.complete":
        return ""
    payload = params.get("payload") or {}
    if not isinstance(payload, dict):
        return ""
    role = str(payload.get("role") or "").strip().lower()
    if role and role != "assistant":
        return ""
    display_kind = str(payload.get("display_kind") or "").strip().lower()
    if display_kind in {"hidden", "tool", "internal"}:
        return ""
    status = str(payload.get("status") or "").strip().lower()
    if status in _SPEAK_SKIP_STATUS:
        return ""
    for key in ("text", "content", "message"):
        raw = payload.get(key)
        if isinstance(raw, str) and raw.strip():
            return raw.strip()[:4000]
    return ""


def is_turn_terminal(params: dict[str, Any]) -> bool:
    payload = params.get("payload") or {}
    status = str(payload.get("status") or "").lower() if isinstance(payload, dict) else ""
    return (
        bool(assistant_speech_text(params))
        or params.get("type") in {"approval.request", "clarify.request"}
        or (params.get("type") == "message.complete" and status in _SPEAK_SKIP_STATUS)
    )


def _is_agent_turn_terminal(params: dict[str, Any]) -> bool:
    """Control cards pause a Xiaoyi turn; they do not finish it."""
    if params.get("type") in {"approval.request", "clarify.request"}:
        return False
    return is_turn_terminal(params)


class RedactingAccessLogger(AccessLogger):
    """Never render query credentials or authentication headers."""

    def log(self, request: web.BaseRequest, response: web.StreamResponse, time: float) -> None:
        # Do not format raw URLs, headers, or arbitrary query values: all may
        # contain credentials, including percent-encoded authentication keys.
        self.logger.info('%s "%s %s HTTP/%s.%s" %s', request.remote,
                         request.method, request.path,
                         request.version.major, request.version.minor, response.status)


class RateLimiter:
    def __init__(self, max_events: int, window: float = 60.0):
        self.max_events = max_events
        self.window = window
        self._hits: dict[str, deque[float]] = defaultdict(deque)

    def allow(self, key: str) -> bool:
        now = time.monotonic()
        q = self._hits[key]
        while q and now - q[0] >= self.window:
            q.popleft()
        if len(q) >= self.max_events:
            return False
        q.append(now)
        return True


class TurnWatchdog:
    """Bound phone-initiated turns even when the phone disconnects mid-turn."""

    def __init__(
        self, hermes: HermesClient, timeout: float, notify, *, max_duration: float = 3600.0
    ):
        self.hermes = hermes
        self.timeout = max(15.0, float(timeout))
        self.max_duration = max(self.timeout, float(max_duration))
        self.notify = notify
        self._tasks: dict[str, asyncio.Task] = {}
        self._started_at: dict[str, float] = {}
        self._last_activity: dict[str, float] = {}
        self._activity_events: dict[str, asyncio.Event] = {}
        self._timeout_interrupt_confirmed: dict[str, bool] = {}
        self._request_ids: dict[str, str] = {}
        self._phases: dict[str, str] = {}
        self._turn_started: set[str] = set()
        self._turn_start_seq: dict[str, int] = {}
        self._start_after_seq: dict[str, int] = {}
        self._user_row_ids: dict[str, str] = {}
        self._pending_events: dict[str, list[dict[str, Any]]] = {}
        self._recent_event_requests: dict[str, OrderedDict[int, tuple[str, float]]] = {}
        self._correlation_ttl_seconds = 300.0
        self._max_correlated_events_per_session = 512

    def arm(
        self, sid: str, request_id: str = "", *, start_after_seq: int | None = None
    ) -> bool:
        if not sid:
            return False
        current = self._tasks.get(sid)
        if current and not current.done():
            return False
        task = asyncio.create_task(self._watch(sid), name=f"harmony-turn-timeout-{sid[:8]}")
        self._tasks[sid] = task
        now = time.monotonic()
        self._started_at[sid] = now
        self._last_activity[sid] = now
        self._activity_events[sid] = asyncio.Event()
        if request_id:
            self._request_ids[sid] = request_id
            self._phases[sid] = "pending"
            self._pending_events.pop(sid, None)
            self._turn_start_seq.pop(sid, None)
            if start_after_seq is not None:
                self._start_after_seq[sid] = start_after_seq
            else:
                self._start_after_seq.pop(sid, None)
        else:
            self._request_ids.pop(sid, None)
            self._phases[sid] = "active"
            self._turn_start_seq.pop(sid, None)
            self._start_after_seq.pop(sid, None)
        return True

    def progress(self, sid: str, request_id: str = "") -> bool:
        """Renew the idle deadline when the active turn emits a Hermes event."""
        task = self._tasks.get(sid)
        if not task or task.done():
            return False
        active_request_id = self._request_ids.get(sid, "")
        if active_request_id and active_request_id != request_id:
            return False
        self._last_activity[sid] = time.monotonic()
        activity = self._activity_events.get(sid)
        if activity:
            activity.set()
        return True

    def request_id(self, sid: str) -> str:
        return self._request_ids.get(sid, "")

    def interrupt_confirmed(self, sid: str) -> bool:
        return self._timeout_interrupt_confirmed.get(sid, False)

    def accept(
        self, sid: str, request_id: str, user_row_id: Any = None
    ) -> list[dict[str, Any]]:
        """Mark an A2A dispatch accepted and correlate events received before its RPC reply."""
        if self._request_ids.get(sid) != request_id:
            return []
        self._phases[sid] = "active"
        self.progress(sid, request_id)
        if user_row_id is not None:
            self._user_row_ids[sid] = str(user_row_id)
        pending = self._pending_events.pop(sid, [])
        start_index = next((
            index for index in range(len(pending) - 1, -1, -1)
            if pending[index].get("type") == "message.start"
            and self._seq_is_after_fence(sid, pending[index].get("seq"))
        ), -1)
        selected = pending[start_index:] if start_index >= 0 else [
            event for event in pending if self._matches_user_row(sid, event)
        ]
        if start_index >= 0:
            self._turn_started.add(sid)
            self._turn_start_seq[sid] = int(pending[start_index]["seq"])
        accepted: list[dict[str, Any]] = []
        for event in selected:
            if event.get("type") in {"approval.request", "clarify.request"}:
                # Control cards lack a user-row ID. Attribute one only when the
                # accepted submit's new turn-start sequence fences it in this turn.
                if not self._control_is_after_turn_start(sid, event):
                    continue
            if (event.get("type") == "message.complete"
                    and self._user_row_ids.get(sid)
                    and not self._matches_user_row(sid, event)):
                continue
            accepted.append(self._tag_event(event, request_id))
        return accepted

    def observe_event(
        self, params: dict[str, Any], *, agent_session: bool
    ) -> tuple[dict[str, Any], str, bool]:
        """Correlate only accepted turns on dedicated Xiaoyi sessions.

        While prompt.submit is awaiting its RPC response, events stay untagged and are
        buffered. A rejected/busy submit therefore cannot claim another turn's reply.
        Completion events require the exact persisted user row. Approval/clarification
        events are correlated only after an accepted submit and a new, sequence-fenced
        message.start on the reserved Xiaoyi session.
        """
        sid = str(params.get("session_id") or "")
        request_id = self._request_ids.get(sid, "")
        if request_id and agent_session:
            if self._phases.get(sid) == "pending":
                pending = self._pending_events.setdefault(sid, [])
                pending.append(dict(params))
                if len(pending) > self._max_correlated_events_per_session:
                    del pending[:-self._max_correlated_events_per_session]
                return params, "", False
            if self._phases.get(sid) == "active":
                if params.get("type") == "message.start":
                    seq = params.get("seq")
                    if self._seq_is_after_fence(sid, seq) and sid not in self._turn_started:
                        self._turn_started.add(sid)
                        self._turn_start_seq[sid] = int(seq)
                if params.get("type") in {"approval.request", "clarify.request"}:
                    if not self._control_is_after_turn_start(sid, params):
                        return params, "", False
                expected_row = self._user_row_ids.get(sid)
                if (params.get("type") == "message.complete" and expected_row
                        and not self._matches_user_row(sid, params)):
                    return params, "", False
                if sid not in self._turn_started and not self._matches_user_row(sid, params):
                    return params, "", False
                event = self._tag_event(params, request_id)
                return event, request_id, _is_agent_turn_terminal(event)
        return params, "", _is_agent_turn_terminal(params) if agent_session else is_turn_terminal(params)

    def _seq_is_after_fence(self, sid: str, seq: Any) -> bool:
        if not isinstance(seq, int) or isinstance(seq, bool):
            return False
        fence = self._start_after_seq.get(sid)
        return fence is None or seq > fence

    def _control_is_after_turn_start(self, sid: str, params: dict[str, Any]) -> bool:
        start_seq = self._turn_start_seq.get(sid)
        payload = params.get("payload") or {}
        server_request_id = (
            payload.get("harmony_server_request_id") if isinstance(payload, dict) else None
        )
        if server_request_id:
            # These JSON-RPC frames share the WebSocket's ordered stream but have
            # no Hermes event sequence. Live frames follow message.start; buffered
            # ones are selected only after the fenced start in accept().
            return sid in self._turn_started and start_seq is not None
        seq = params.get("seq")
        return (
            sid in self._turn_started
            and start_seq is not None
            and isinstance(seq, int)
            and not isinstance(seq, bool)
            and seq > start_seq
        )

    def restore_event(self, params: dict[str, Any]) -> dict[str, Any]:
        """Restore request correlation for a replayed event after a phone reconnect."""
        if params.get("harmony_request_id"):
            return params
        sid = str(params.get("session_id") or "")
        seq = params.get("seq")
        if not sid or not isinstance(seq, int):
            return params
        recent = self._recent_event_requests.get(sid)
        if not recent:
            return params
        now = time.monotonic()
        for old_seq, (_, timestamp) in list(recent.items()):
            if now - timestamp > self._correlation_ttl_seconds:
                recent.pop(old_seq, None)
        match = recent.get(seq)
        if match is None:
            return params
        event = dict(params)
        event["harmony_request_id"] = match[0]
        return event

    def _matches_user_row(self, sid: str, params: dict[str, Any]) -> bool:
        expected = self._user_row_ids.get(sid)
        if not expected:
            return False
        payload = params.get("payload") or {}
        persisted = payload.get("persisted_turn") if isinstance(payload, dict) else None
        actual = persisted.get("user_row_id") if isinstance(persisted, dict) else None
        return actual is not None and str(actual) == expected

    def _tag_event(self, params: dict[str, Any], request_id: str) -> dict[str, Any]:
        event = dict(params)
        event["harmony_request_id"] = request_id
        sid = str(event.get("session_id") or "")
        seq = event.get("seq")
        if sid and isinstance(seq, int):
            recent = self._recent_event_requests.setdefault(sid, OrderedDict())
            recent[seq] = (request_id, time.monotonic())
            recent.move_to_end(seq)
            while len(recent) > self._max_correlated_events_per_session:
                recent.popitem(last=False)
        return event

    def settle(self, sid: str, request_id: str = "") -> bool:
        active_request_id = self._request_ids.get(sid, "")
        if request_id and active_request_id != request_id:
            return False
        task = self._tasks.pop(sid, None)
        self._request_ids.pop(sid, None)
        self._phases.pop(sid, None)
        self._turn_started.discard(sid)
        self._turn_start_seq.pop(sid, None)
        self._start_after_seq.pop(sid, None)
        self._user_row_ids.pop(sid, None)
        self._pending_events.pop(sid, None)
        self._started_at.pop(sid, None)
        self._last_activity.pop(sid, None)
        self._activity_events.pop(sid, None)
        self._timeout_interrupt_confirmed.pop(sid, None)
        if task and task is not asyncio.current_task():
            task.cancel()
        return task is not None

    async def _watch(self, sid: str) -> None:
        try:
            reason = "idle"
            while True:
                now = time.monotonic()
                started_at = self._started_at.get(sid, now)
                last_activity = self._last_activity.get(sid, started_at)
                idle_remaining = self.timeout - (now - last_activity)
                max_remaining = self.max_duration - (now - started_at)
                if idle_remaining <= 0 or max_remaining <= 0:
                    reason = "max_duration" if max_remaining <= idle_remaining else "idle"
                    break
                activity = self._activity_events.get(sid)
                if activity is None:
                    return
                activity.clear()
                try:
                    await asyncio.wait_for(activity.wait(), timeout=min(idle_remaining, max_remaining))
                except asyncio.TimeoutError:
                    continue

            if self._tasks.get(sid) is not asyncio.current_task():
                return
            now = time.monotonic()
            elapsed = now - self._started_at.get(sid, now)
            idle = now - self._last_activity.get(sid, now)
            interrupted = False
            try:
                await self.hermes.session_interrupt(sid)
                interrupted = True
            except Exception as exc:
                # Still notify the phone: a failed interrupt must not leave its
                # spinner running or falsely claim that Hermes stopped.
                log.warning("turn watchdog interrupt not confirmed: %s", type(exc).__name__)
            log.warning(
                "turn watchdog expired reason=%s elapsed=%.1fs idle=%.1fs interrupt_confirmed=%s",
                reason, elapsed, idle, interrupted,
            )
            self._timeout_interrupt_confirmed[sid] = interrupted
            await self.notify(sid)
        except asyncio.CancelledError:
            return
        except Exception as exc:
            log.warning("turn watchdog failed: %s", type(exc).__name__)
        finally:
            if self._tasks.get(sid) is asyncio.current_task():
                self._tasks.pop(sid, None)
                self._request_ids.pop(sid, None)
                self._started_at.pop(sid, None)
                self._last_activity.pop(sid, None)
                self._activity_events.pop(sid, None)
                self._timeout_interrupt_confirmed.pop(sid, None)
                self._phases.pop(sid, None)
                self._turn_started.discard(sid)
                self._turn_start_seq.pop(sid, None)
                self._start_after_seq.pop(sid, None)
                self._user_row_ids.pop(sid, None)
                self._pending_events.pop(sid, None)

    async def close(self) -> None:
        tasks = list(self._tasks.values())
        self._tasks.clear()
        self._started_at.clear()
        self._last_activity.clear()
        self._activity_events.clear()
        self._timeout_interrupt_confirmed.clear()
        self._request_ids.clear()
        self._phases.clear()
        self._turn_started.clear()
        self._turn_start_seq.clear()
        self._start_after_seq.clear()
        self._user_row_ids.clear()
        self._pending_events.clear()
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)


class AppSession:
    def __init__(self, ws, cfg: BridgeConfig, hermes: HermesClient, store: DeviceStore, limiter: RateLimiter, fanout: Fanout, connected: dict[str, AppSession], watchdog: TurnWatchdog | None = None):
        self.ws = ws
        self.cfg = cfg
        self.hermes = hermes
        self.store = store
        self.limiter = limiter
        self.fanout = fanout
        self.connected = connected
        self.watchdog = watchdog
        self.sid_map = store.sid_map
        self.device_key = ""
        self.device_id = ""
        self._pcm: PcmAccumulator | None = None
        self._recording = False
        self._record_started = 0.0
        self._send_lock = asyncio.Lock()
        self._helloed = False
        self._live_sids: dict[str, str] = {}
        self._turn_request_ids: dict[str, str] = {}
        self._active_session = ""
        self._auto_speak_sid = ""
        self._last_spoken = ""
        self._last_spoken_at = 0.0
        self._tts_lock = asyncio.Lock()
        self._tts_tasks: set[asyncio.Task] = set()
        self._voice_reply = True  # legacy phones; new clients explicitly opt in
        self._replaying: dict[str, list[dict[str, Any]]] = {}
        self._last_pong = time.monotonic()
        self._processing_message = False

    async def send_json(self, **fields: Any) -> None:
        try:
            if not self.ws.closed:
                async with self._send_lock:
                    if not self.ws.closed:
                        await self.ws.send_str(json.dumps(fields, ensure_ascii=False))
        except Exception:
            log.debug("phone json send skipped after disconnect", exc_info=True)

    async def send_bin(self, payload: bytes) -> bool:
        try:
            if not self.ws.closed:
                async with self._send_lock:
                    if not self.ws.closed:
                        await self.ws.send_bytes(payload)
                        return True
        except Exception:
            log.debug("phone audio send skipped after disconnect", exc_info=True)
        return False

    async def send_event(self, params: dict[str, Any]) -> None:
        sid = str(params.get("session_id") or "")
        if sid in self._replaying:
            self._replaying[sid].append(dict(params))
            return
        await self.send_event_unbuffered(params)

    def _arm_auto_speak(self, sid: str) -> None:
        self._auto_speak_sid = sid if self._voice_reply else ""

    def _disarm_auto_speak(self) -> None:
        self._auto_speak_sid = ""

    def _schedule_auto_speak(self, params: dict[str, Any]) -> None:
        sid = str(params.get("session_id") or "")
        if not self._auto_speak_sid or sid != self._auto_speak_sid:
            return
        if params.get("type") != "message.complete":
            return
        text = assistant_speech_text(params)
        if not text:
            return
        self._auto_speak_sid = ""
        if self.ws.closed:
            return
        task = asyncio.create_task(self._auto_speak(text), name="harmony-auto-tts")
        self._tts_tasks.add(task)
        task.add_done_callback(self._tts_tasks.discard)

    async def _auto_speak(self, text: str) -> None:
        try:
            await self._connect_hermes()
            await self._speak_to_phone(text)
        except Exception as exc:
            log.warning("auto tts failed: %s", exc)
            try:
                await self.send_json(t="error", msg="tts failed", code="tts")
            except Exception:
                pass

    async def run(self) -> None:
        ping = asyncio.create_task(self._ping_loop())
        try:
            async for msg in self.ws:
                if msg.type == WSMsgType.TEXT:
                    self._processing_message = True
                    try:
                        await self._on_text(msg.data)
                    finally:
                        self._processing_message = False
                        self._last_pong = time.monotonic()
                elif msg.type == WSMsgType.BINARY:
                    self._processing_message = True
                    try:
                        await self._on_binary(msg.data)
                    finally:
                        self._processing_message = False
                        self._last_pong = time.monotonic()
                elif msg.type in (WSMsgType.CLOSE, WSMsgType.CLOSING, WSMsgType.ERROR):
                    break
        finally:
            ping.cancel()
            self._cancel_recording()
            self._disarm_auto_speak()
            tasks = list(self._tts_tasks)
            for task in tasks:
                task.cancel()
            await asyncio.gather(ping, *tasks, return_exceptions=True)
            self.fanout.unsubscribe_all(self)
            if self.connected.get(self.device_key) is self:
                self.connected.pop(self.device_key, None)
            if hasattr(self, "_registry"):
                self._registry.discard(self)
            if self.device_key:
                self.store.save()

    async def _ping_loop(self) -> None:
        try:
            while not self.ws.closed:
                interval = max(5.0, float(self.cfg.ping_interval_seconds))
                await asyncio.sleep(interval)
                if self._helloed and not self._processing_message and time.monotonic() - self._last_pong > interval * 3:
                    log.info("phone heartbeat expired; closing stale socket")
                    await self.ws.close()
                    return
                await self.send_json(
                    t="ping", hermes=bool(self.hermes.connected),
                    epoch=self.hermes.replay_epoch or "",
                )
        except asyncio.CancelledError:
            return
        except Exception:
            log.debug("ping loop ended", exc_info=True)

    async def _on_text(self, raw: str) -> None:
        try:
            obj = json.loads(raw)
        except json.JSONDecodeError:
            await self.send_json(t="error", msg="invalid json", code="bad_json")
            return
        if not isinstance(obj, dict):
            await self.send_json(t="error", msg="invalid message", code="bad_json")
            return
        kind = obj.get("t")
        if kind == "hello":
            await self._on_hello(obj)
        elif not self._helloed:
            await self.send_json(t="error", msg="send hello first", code="no_hello")
        elif kind == "sub":
            await self._on_sub(obj)
        elif kind == "dispatch":
            await self._on_dispatch(obj)
        elif kind == "interrupt":
            await self._on_interrupt(obj)
        elif kind == "approve":
            await self._on_approve(obj)
        elif kind == "clarify":
            await self._on_clarify(obj)
        elif kind == "sessions":
            await self._on_sessions()
        elif kind == "session_archive":
            await self._on_session_archive(obj)
        elif kind == "session_delete":
            await self._on_session_delete(obj)
        elif kind == "new_session":
            await self._on_new_session(obj)
        elif kind == "asr_start":
            await self._on_asr_start(obj)
        elif kind == "asr_cancel":
            self._cancel_recording()
        elif kind == "asr_end":
            await self._on_asr_end()
        elif kind == "tts":
            await self._on_tts(obj)
        elif kind == "voice_check":
            request_id = str(obj.get("request_id") or "")
            await self._send_voice_capabilities(request_id=request_id)
        elif kind == "voice_preferences":
            self._voice_reply = obj.get("voice_reply") is True
            if not self._voice_reply:
                self._disarm_auto_speak()
        elif kind == "pong":
            self._last_pong = time.monotonic()
            return
        else:
            await self.send_json(t="error", msg=f"unknown type {kind}", code="unknown")

    async def _on_hello(self, obj: dict) -> None:
        proto = obj.get("proto")
        if proto not in (2, "2", None):
            await self.send_json(t="error", msg="unsupported proto", code="proto")
            await self.ws.close()
            return
        self.device_id = str(obj.get("dev") or "")
        self.device_key = self.device_id or "unnamed-device"
        previous = self.connected.get(self.device_key)
        if len(self.connected) >= self.cfg.max_devices and previous is None:
            await self.send_json(t="error", msg="too many devices", code="busy")
            await self.ws.close()
            return
        # A suspended phone socket may not report close. Replace it immediately
        # so the same device has one subscriber and one active audio stream.
        if previous is not None and previous is not self:
            try:
                await previous.ws.close()
            except Exception:
                log.debug("stale phone socket already closed", exc_info=True)
        self.connected[self.device_key] = self
        self._helloed = True
        self._voice_reply = obj.get("voice_reply", True) is True
        self._last_pong = time.monotonic()
        rec = self.store.get(self.device_key)
        rec.device_id = self.device_id or rec.device_id
        # The bridge has its own reconnect monitor. Do not hold the phone's
        # handshake behind endpoint discovery or a slow Hermes WS timeout.
        hermes_ok = bool(self.hermes.connected)
        epoch = self.hermes.replay_epoch or rec.epoch
        rec.epoch = epoch
        self.store.save()
        try:
            await self.send_json(t="ready", epoch=epoch or "", hermes=hermes_ok,
                                 features=["a2a_task_correlation_v1", "a2a_control_handoff_v1", "voice_readiness_v1"])
            # Readiness can take seconds. Keep the text handshake immediate.
            task = asyncio.create_task(self._send_voice_capabilities(), name="harmony-voice-check")
            self._tts_tasks.add(task)
            task.add_done_callback(self._tts_tasks.discard)
        except Exception:
            log.debug("ready send failed", exc_info=True)

    async def _connect_hermes(self) -> None:
        if self.hermes.endpoint is None:
            self.hermes.bind(await asyncio.to_thread(discover_endpoint, self.cfg.hermes))
        try:
            await self.hermes.ensure_connected(attempts=2)
        except HermesError:
            self.hermes.bind(await asyncio.to_thread(discover_endpoint, self.cfg.hermes))
            await self.hermes.ensure_connected(attempts=4)

    def _live_sid(self, requested: str) -> str:
        return self._live_sids.get(requested) or requested

    def _remember_resumed_session(self, requested: str, resume: dict[str, Any]) -> str:
        live = str(resume.get("session_id") or requested)
        stored = str(resume.get("stored_session_id") or resume.get("session_key") or self.sid_map.stored(requested))
        self.sid_map.remember(live, stored)
        self._live_sids[requested] = live
        self._live_sids[stored] = live
        self._live_sids[live] = live
        if self.device_key:
            rec = self.store.get(self.device_key)
            rec.stored_ids[live] = stored
        return live

    async def _resolve_live_sid(self, requested: str) -> str:
        """Map a stored session id (session.list) onto the runtime sid events.since uses."""
        if not requested:
            return requested
        if requested in self._live_sids:
            return self._live_sids[requested]
        if self.sid_map.known(requested):
            # Runtime ids become invalid when Hermes restarts. Re-resolve the
            # durable id once per phone connection instead of trusting disk.
            stored = self.sid_map.stored(requested)
            try:
                resume = await self.hermes.session_resume(stored)
                return self._remember_resumed_session(requested, resume)
            except HermesError:
                # The requested id may itself be a valid current runtime id.
                pass
        since = await self.hermes.session_events_since(requested, 0)
        if int(since.get("latest_seq") or 0) > 0 or since.get("events") or since.get("truncated"):
            self.sid_map.remember(requested, requested)
            self._live_sids[requested] = requested
            return requested
        try:
            resume = await self.hermes.session_resume(requested)
        except HermesError:
            self._live_sids[requested] = requested
            return requested
        return self._remember_resumed_session(requested, resume)

    async def _ensure_active_session(self) -> str:
        rec = self.store.get(self.device_key) if self.device_key else None
        candidate = self._active_session or (
            next(iter(rec.cursors), "") if rec and rec.cursors else ""
        )
        if candidate:
            live = await self._resolve_live_sid(candidate)
            self._active_session = live
            self.fanout.subscribe(live, self)
            return live
        created = await self.hermes.session_create(
            source=self.cfg.hermes.source,
            profile=self.cfg.hermes.profile,
            title=f"Harmony {self.device_id or 'phone'}",
            cwd=str(self.cfg.workspace_dir),
        )
        sid = str(created.get("session_id") or "")
        if not sid:
            raise HermesError("session.create returned empty id")
        stored = str(created.get("stored_session_id") or sid)
        self.sid_map.remember(sid, stored)
        self._live_sids[sid] = sid
        self._live_sids[stored] = sid
        if rec is not None:
            rec.cursors[sid] = 0
            rec.stored_ids[sid] = stored
        self._active_session = sid
        self.fanout.subscribe(sid, self)
        return sid

    async def _on_sub(self, obj: dict) -> None:
        requested = str(obj.get("session") or "")
        try:
            last_seen = int(obj.get("last_seen") or 0)
        except (TypeError, ValueError):
            await self.send_json(t="error", msg="last_seen must be an integer", code="bad_cursor")
            return
        if not requested:
            await self.send_json(t="error", msg="session required", code="no_session")
            return
        try:
            await self._connect_hermes()
            live = await self._resolve_live_sid(requested)
            self._active_session = live
            self._replaying[live] = []
            self.fanout.subscribe(live, self)
            if live != requested:
                self.fanout.subscribe(requested, self)
            latest_seq = await self._replay(live, last_seen)
            # Replay must reach the phone before newer live events. Events
            # already included by the snapshot are discarded by sequence.
            while self._replaying[live]:
                pending = self._replaying[live]
                self._replaying[live] = []
                for event in pending:
                    seq = event.get("seq")
                    if not isinstance(seq, int) or seq > latest_seq:
                        await self.send_event_unbuffered(event)
            self._replaying.pop(live, None)
        except Exception as exc:
            if 'live' in locals():
                self._replaying.pop(live, None)
            log.warning("sub/replay failed: %s", exc)
            code = "session_gone" if isinstance(exc, HermesError) and "RPC 4007" in str(exc) else "replay"
            await self.send_json(t="error", msg="replay failed", code=code, session=requested)

    async def send_event_unbuffered(self, params: dict[str, Any]) -> None:
        seq = params.get("seq")
        sid = str(params.get("session_id") or "")
        if self.device_key and sid and isinstance(seq, int):
            rec = self.store.get(self.device_key)
            rec.cursors[sid] = max(int(rec.cursors.get(sid) or 0), seq)
        event = dict(params)
        request_id = str(params.get("harmony_request_id") or "")
        if request_id:
            event["harmony_request_id"] = request_id
        await self.send_json(t="ev", p=event)
        terminal = is_turn_terminal(event)
        if (request_id and self.watchdog
                and self.watchdog.request_id(sid) == request_id
                and self.store.is_agent_session(sid)):
            terminal = _is_agent_turn_terminal(event)
        if terminal and request_id and self._turn_request_ids.get(sid) == request_id:
            self._turn_request_ids.pop(sid, None)
        self._schedule_auto_speak(params)

    async def _replay(self, session_id: str, last_seen: int) -> int:
        """Replay-or-resume. truncated:true MUST go through session.resume (plan §3.3)."""
        since = await self.hermes.session_events_since(session_id, last_seen)
        truncated = bool(since.get("truncated"))
        latest_seq = int(since.get("latest_seq") or 0)
        # A zero cursor means the app has no trusted local history. Raw Hermes
        # history can contain tool/protocol completions; session.resume carries
        # canonical role-tagged chat messages that the app can safely filter.
        if truncated or last_seen <= 0:
            stored = self.sid_map.stored(session_id)
            resume = await self.hermes.session_resume(stored)
            live = str(resume.get("session_id") or session_id)
            stored_out = str(resume.get("stored_session_id") or resume.get("session_key") or stored)
            self.sid_map.remember(live, stored_out)
            if live != session_id:
                self._live_sids[session_id] = live
                self.fanout.subscribe(live, self)
            await self.send_json(
                t="replay",
                session=live,
                truncated=True,
                latest_seq=int(since.get("latest_seq") or 0),
                resume=resume,
            )
            open_requests: list[dict[str, Any]] = []
            seen_request_ids: set[str] = set()
            for snapshot in (resume, since):
                requests = snapshot.get("open_requests")
                if not isinstance(requests, list):
                    continue
                for request in requests:
                    if not isinstance(request, dict):
                        continue
                    request_id = request.get("id")
                    if isinstance(request_id, str) and request_id in seen_request_ids:
                        continue
                    if isinstance(request_id, str):
                        seen_request_ids.add(request_id)
                    open_requests.append(request)
            await self._replay_server_requests(live, open_requests)
            # A fresh/expired cursor needs the canonical transcript snapshot, but
            # Xiaoyi may still be waiting for a correlated task result. Replay only
            # A2A-tagged Hermes events after the snapshot so the task waiter can
            # complete even when its event sequence was never stored on the phone.
            if self.watchdog and self.store.is_agent_session(live):
                for raw_event in since.get("events") or []:
                    if not isinstance(raw_event, dict):
                        continue
                    event = self.watchdog.restore_event(raw_event)
                    if not event.get("harmony_request_id"):
                        request_id = self.store.agent_request_for_event(live, event)
                        if request_id:
                            event = dict(event)
                            event["harmony_request_id"] = request_id
                    if event.get("harmony_request_id"):
                        await self.send_json(t="ev", p=event)
            if self.device_key:
                rec = self.store.get(self.device_key)
                rec.cursors[live] = latest_seq
            return latest_seq
        for event in since.get("events") or []:
            if isinstance(event, dict):
                event = self.watchdog.restore_event(event) if self.watchdog else event
                if not event.get("harmony_request_id") and self.store.is_agent_session(session_id):
                    request_id = self.store.agent_request_for_event(session_id, event)
                    if request_id:
                        event = dict(event)
                        event["harmony_request_id"] = request_id
                await self.send_json(t="ev", p=event)
                seq = event.get("seq")
                if self.device_key and isinstance(seq, int):
                    rec = self.store.get(self.device_key)
                    rec.cursors[session_id] = max(int(rec.cursors.get(session_id) or 0), seq)
        await self._replay_server_requests(session_id, since.get("open_requests"))
        await self.send_json(
            t="replay",
            session=session_id,
            truncated=False,
            latest_seq=latest_seq,
        )
        return latest_seq

    async def _replay_server_requests(self, session_id: str, requests: Any) -> None:
        """Restore pending modern approval/clarify cards omitted from event history."""
        if not isinstance(requests, list):
            return
        for raw_request in requests:
            if not isinstance(raw_request, dict):
                continue
            restore = getattr(self.hermes, "restore_server_request", None)
            event = restore(raw_request) if callable(restore) else None
            if event is None:
                reject = getattr(self.hermes, "reject_server_request", None)
                request_id = raw_request.get("id")
                if callable(reject) and isinstance(request_id, str):
                    await reject(request_id, "Unsupported server request")
                continue
            event["session_id"] = session_id
            if self.watchdog and self.store.is_agent_session(session_id):
                event, request_id, _ = self.watchdog.observe_event(event, agent_session=True)
            else:
                request_id = ""
            if not request_id and self.store.is_agent_session(session_id):
                request_id = self.store.agent_request_for_event(session_id, event)
                if request_id:
                    event = dict(event)
                    event["harmony_request_id"] = request_id
            if request_id:
                payload = event.get("payload") or {}
                control_request_id = payload.get("request_id") if isinstance(payload, dict) else None
                server_request_id = (
                    payload.get("harmony_server_request_id") if isinstance(payload, dict) else None
                )
                control_id = (
                    str(control_request_id) if isinstance(control_request_id, str) and control_request_id
                    else str(server_request_id or "")
                )
                if control_id:
                    self.store.remember_agent_control_event(
                        session_id, request_id, str(event["type"]), control_id,
                        server_request_id=(str(server_request_id) if server_request_id else ""),
                    )
            await self.send_event_unbuffered(event)

    async def _on_dispatch(self, obj: dict) -> None:
        request_id = str(obj.get("request_id") or "") or None
        agent_session = obj.get("agent_session") is True
        sid = str(obj.get("session") or "")
        text = str(obj.get("text") or "").strip()
        if not sid or not text:
            await self.send_json(t="error", msg="session and text required", code="bad_dispatch", request_id=request_id)
            return
        if not self.limiter.allow(self.device_key):
            await self.send_json(t="error", msg="rate limited", code="rate", request_id=request_id)
            return
        try:
            await self._connect_hermes()
            live = await self._resolve_live_sid(sid)
            start_after_seq: int | None = None
            if agent_session and request_id:
                # Reject sessions already occupied by another turn, then take a
                # sequence watermark so stale control cards cannot attach to this task.
                resumed = await self.hermes.session_resume(self.sid_map.stored(live))
                if resumed.get("running") is True:
                    await self.send_json(t="error", msg="session already has an active turn", code="busy",
                                         session=live, request_id=request_id)
                    return
                pending_approval = resumed.get("pending_approval")
                inflight = resumed.get("inflight")
                open_requests = resumed.get("open_requests")
                has_pending_approval = pending_approval not in (None, False, "", [], {})
                has_inflight = inflight not in (None, False, "", [], {})
                has_open_requests = isinstance(open_requests, list) and bool(open_requests)
                if has_pending_approval or has_inflight or has_open_requests:
                    await self.send_json(t="error", msg="session has an unresolved Hermes request", code="busy",
                                         session=live, request_id=request_id)
                    return
                resumed_live = str(resumed.get("session_id") or live)
                if resumed_live != live:
                    live = self._remember_resumed_session(live, resumed)
                snapshot = await self.hermes.session_events_since(live, 0)
                watermark = snapshot.get("latest_seq")
                if not isinstance(watermark, int) or isinstance(watermark, bool) or watermark < 0:
                    raise HermesError("Hermes did not provide an event sequence watermark for Xiaoyi")
                start_after_seq = watermark
            if agent_session and self.device_key:
                self.store.mark_agent_session(
                    self.device_key, live, self.sid_map.stored(live)
                )
            if request_id:
                await self.send_json(t="session_resolved", request_id=request_id, requested=sid, session=live)
            if self.watchdog and not self.watchdog.arm(
                live, request_id or "", start_after_seq=start_after_seq
            ):
                await self.send_json(t="error", msg="session already has an active turn", code="busy",
                                     session=live, request_id=request_id)
                return
            self._active_session = live
            self.fanout.subscribe(live, self)
            self._arm_auto_speak(live)
            if request_id:
                self._turn_request_ids[live] = request_id
            try:
                result = await self.hermes.prompt_submit(live, text)
                status = str(result.get("status") or "").lower()
                if request_id and status != "streaming":
                    raise HermesError(
                        "Hermes did not confirm an immediate streaming turn for this Xiaoyi request"
                    )
                if not request_id and status == "queued":
                    raise HermesError("Hermes queued this command behind another session turn")
                user_row_id = result.get("user_row_id")
                if request_id and user_row_id is None:
                    raise HermesError(
                        "Hermes did not return the user row ID required to safely correlate this Xiaoyi task"
                    )
                if request_id and self.device_key:
                    self.store.remember_agent_turn(
                        self.device_key,
                        self.sid_map.stored(live),
                        request_id,
                        str(user_row_id),
                    )
                if self.watchdog and request_id:
                    for event in self.watchdog.accept(
                        live, request_id, user_row_id
                    ):
                        if event.get("type") in {"approval.request", "clarify.request"}:
                            payload = event.get("payload") or {}
                            control_request_id = payload.get("request_id") if isinstance(payload, dict) else None
                            server_request_id = (
                                payload.get("harmony_server_request_id") if isinstance(payload, dict) else None
                            )
                            if (isinstance(control_request_id, str) and control_request_id) or server_request_id:
                                self.store.remember_agent_control_event(
                                    live, request_id, str(event["type"]),
                                    str(control_request_id or server_request_id),
                                    server_request_id=(str(server_request_id) if server_request_id else ""),
                                )
                        await self.send_event_unbuffered(event)
                        if _is_agent_turn_terminal(event):
                            self.watchdog.settle(live, request_id)
            except Exception:
                self._disarm_auto_speak()
                if self.watchdog:
                    self.watchdog.settle(live, request_id or "")
                if request_id and self._turn_request_ids.get(live) == request_id:
                    self._turn_request_ids.pop(live, None)
                raise
        except Exception as exc:
            log.warning("dispatch failed: %s", exc)
            await self.send_json(t="error", msg="dispatch failed", code="dispatch", request_id=request_id)

    async def _on_interrupt(self, obj: dict) -> None:
        sid = str(obj.get("session") or "")
        request_id = str(obj.get("request_id") or "")
        task_request_id = str(obj.get("task_request_id") or request_id)
        if not sid:
            await self.send_json(t="error", msg="session required", code="no_session")
            return
        try:
            await self._connect_hermes()
            live = await self._resolve_live_sid(sid)
            active_request_id = self.watchdog.request_id(live) if self.watchdog else ""
            if task_request_id and active_request_id != task_request_id:
                await self.send_json(t="interrupt_result", request_id=request_id,
                                     task_request_id=task_request_id, session=live, status="inactive")
                return
            interrupted_request_id = task_request_id or active_request_id
            self._disarm_auto_speak()
            await self.hermes.session_interrupt(live)
            if self.watchdog:
                self.watchdog.settle(live, interrupted_request_id)
            if self._turn_request_ids.get(live) == interrupted_request_id:
                self._turn_request_ids.pop(live, None)
            await self.send_json(t="interrupt_result", request_id=request_id,
                                 task_request_id=interrupted_request_id, session=live, status="interrupted")
        except Exception as exc:
            log.warning("interrupt failed: %s", exc)
            if request_id:
                await self.send_json(t="interrupt_result", request_id=request_id,
                                     task_request_id=task_request_id, session=sid, status="failed")
            await self.send_json(t="error", msg="interrupt failed", code="interrupt")

    async def _on_approve(self, obj: dict) -> None:
        sid = str(obj.get("session") or "")
        choice = str(obj.get("choice") or "").strip()
        request_id = str(obj.get("request_id") or "") or None
        server_request_id = str(obj.get("harmony_server_request_id") or "")
        if not sid:
            await self.send_json(t="error", msg="session required", code="no_session")
            return
        if choice not in APPROVE_CHOICES:
            await self.send_json(
                t="error",
                msg="choice required (once|session|always|deny); refusing to default",
                code="no_choice",
            )
            return
        try:
            await self._connect_hermes()
            if server_request_id:
                await self.hermes.respond_server_request(
                    server_request_id, {"choice": choice}, expected_method="approval"
                )
            else:
                await self.hermes.approval_respond(self._live_sid(sid), choice, request_id)
        except Exception as exc:
            log.warning("approve failed: %s", exc)
            await self.send_json(t="error", msg="approve failed", code="approve")

    async def _on_clarify(self, obj: dict) -> None:
        sid = str(obj.get("session") or "")
        request_id = str(obj.get("request_id") or "")
        server_request_id = str(obj.get("harmony_server_request_id") or "")
        if not sid or (not request_id and not server_request_id):
            await self.send_json(t="error", msg="session and request_id required", code="bad_clarify")
            return
        try:
            await self._connect_hermes()
            if server_request_id:
                await self.hermes.respond_server_request(
                    server_request_id, {"answer": obj.get("answer")}, expected_method="clarify"
                )
            else:
                await self.hermes.clarify_respond(self._live_sid(sid), request_id, obj.get("answer"))
        except Exception as exc:
            log.warning("clarify failed: %s", exc)
            await self.send_json(t="error", msg="clarify failed", code="clarify")

    async def _on_sessions(self) -> None:
        try:
            await self._connect_hermes()
            result = await self.hermes.session_list()
            rows = result.get("sessions") or []
            for row in rows:
                if not isinstance(row, dict):
                    continue
                stored = str(row.get("stored_session_id") or row.get("id") or row.get("session_id") or "")
                live = str(row.get("session_id") or row.get("id") or stored)
                if stored and live:
                    self.sid_map.remember(live, stored)
                    self._live_sids[stored] = live
                    self._live_sids[live] = live
            payload: dict[str, Any] = {"t": "sessions", "list": rows}
            try:
                archived = await self.hermes.archived_sessions()
                archived_ids = {
                    str(row.get("id") or row.get("stored_session_id") or row.get("session_id") or "")
                    for row in archived
                }
                archived_ids.discard("")
                if archived_ids:
                    rows = [
                        row for row in rows if not isinstance(row, dict) or not (
                            str(row.get("stored_session_id") or "") in archived_ids or
                            str(row.get("id") or "") in archived_ids or
                            str(row.get("session_id") or "") in archived_ids
                        )
                    ]
                payload["list"] = rows
                payload["archived_list"] = archived
            except Exception as exc:
                log.warning("archived session list failed: %s", type(exc).__name__)
            await self.send_json(**payload)
        except Exception as exc:
            log.warning("session.list failed: %s", exc)
            await self.send_json(t="error", msg="session list failed", code="sessions")

    async def _on_session_archive(self, obj: dict) -> None:
        sid = str(obj.get("session") or "")
        request_id = str(obj.get("request_id") or "") or None
        correlation = {"request_id": request_id} if request_id else {}
        archive_value = obj.get("archived")
        if not isinstance(archive_value, bool):
            await self.send_json(
                t="error", msg="archived must be a boolean", code="session_action", **correlation
            )
            return
        archived = archive_value
        if not sid:
            await self.send_json(t="error", msg="session required", code="session_action", **correlation)
            return
        action = "archive" if archived else "restore"
        try:
            await self._connect_hermes()
            live = self._live_sid(sid)
            stored = self.sid_map.stored(live)
            await self.hermes.session_set_archived(stored, archived)
            await self.send_json(
                t="session_action", action=action, session=sid, stored=stored,
                archived=archived, ok=True, **correlation,
            )
            await self._on_sessions()
        except Exception as exc:
            log.warning("session %s failed: %s", action, type(exc).__name__)
            await self.send_json(
                t="error", msg="会话归档操作失败，请检查连接后重试",
                code="session_action", action=action, session=sid, **correlation,
            )

    async def _on_session_delete(self, obj: dict) -> None:
        sid = str(obj.get("session") or "")
        request_id = str(obj.get("request_id") or "") or None
        correlation = {"request_id": request_id} if request_id else {}
        if not sid:
            await self.send_json(t="error", msg="session required", code="session_action", **correlation)
            return
        try:
            await self._connect_hermes()
            live = self._live_sid(sid)
            stored = self.sid_map.stored(live)
            await self.hermes.session_delete(stored)
            self.fanout.unsubscribe(live, self)
            if self._active_session == live:
                self._active_session = ""
            if self._auto_speak_sid == live:
                self._disarm_auto_speak()
            self._live_sids.pop(live, None)
            self._live_sids.pop(stored, None)
            try:
                self.store.forget_session(live, stored)
            except Exception as exc:
                log.warning("session tracking cleanup failed: %s", type(exc).__name__)
            await self.send_json(
                t="session_action", action="delete", session=sid, stored=stored, ok=True, **correlation,
            )
            await self._on_sessions()
        except Exception as exc:
            log.warning("session delete failed: %s", type(exc).__name__)
            await self.send_json(
                t="error", msg="会话删除失败，请检查连接后重试",
                code="session_action", action="delete", session=sid, **correlation,
            )

    async def _on_new_session(self, obj: dict) -> None:
        request_id = str(obj.get("request_id") or "") or None
        correlation = {"request_id": request_id} if request_id else {}
        title = str(obj.get("title") or "Harmony")
        try:
            await self._connect_hermes()
            cwd = str(self.cfg.workspace_dir)
            Path(cwd).mkdir(parents=True, exist_ok=True)
            result = await self.hermes.session_create(
                source=self.cfg.hermes.source,
                profile=self.cfg.hermes.profile,
                title=title,
                cwd=cwd,
            )
            sid = str(result.get("session_id") or "")
            stored = str(result.get("stored_session_id") or sid)
            if sid:
                stored = str(result.get("stored_session_id") or sid)
                self.sid_map.remember(sid, stored)
                self._live_sids[sid] = sid
                self._live_sids[stored] = sid
                if obj.get("agent_session") is True and self.device_key:
                    self.store.mark_agent_session(self.device_key, sid, stored)
                self._active_session = sid
                self.fanout.subscribe(sid, self)
                if self.device_key:
                    rec = self.store.get(self.device_key)
                    rec.stored_ids[sid] = stored
                    rec.cursors[sid] = 0
            listing = []
            try:
                listing = (await self.hermes.session_list()).get("sessions") or []
            except Exception:
                pass
            await self.send_json(t="sessions", list=listing, created=sid, stored=stored, **correlation)
        except Exception as exc:
            log.warning("session.create failed: %s", exc)
            await self.send_json(t="error", msg="create session failed", code="new_session", **correlation)

    def _cancel_recording(self) -> None:
        self._recording = False
        self._pcm = None
        self._record_started = 0.0

    async def _send_voice_capabilities(self, *, request_id: str = "") -> dict:
        capabilities = await self.hermes.voice_capabilities(profile=self.cfg.hermes.profile)
        correlation = {"request_id": request_id} if request_id else {}
        await self.send_json(t="voice_capabilities", voice=capabilities, **correlation)
        return capabilities

    async def _require_voice(self) -> bool:
        # Refresh at the server boundary so a stale phone status cannot bypass it.
        capabilities = await self._send_voice_capabilities()
        if capabilities.get("ready") is not True:
            await self.send_json(t="error", code="voice_unavailable", msg=capabilities["reason"])
            return False
        return True

    async def _on_asr_start(self, obj: dict) -> None:
        self._cancel_recording()
        if not await self._require_voice():
            return
        if not self.limiter.allow(self.device_key):
            await self.send_json(t="error", msg="rate limited", code="rate")
            return
        try:
            sample_rate = int(obj.get("sr") or 16000)
        except (ValueError, TypeError):
            sample_rate = 0
        if sample_rate not in (8000, 16000, 24000, 32000, 44100, 48000):
            await self.send_json(t="error", msg="unsupported sample rate", code="asr_fmt")
            return
        session = str(obj.get("session") or "")
        if session:
            self._active_session = self._live_sid(session)
        self._pcm = PcmAccumulator(sample_rate=sample_rate)
        self._recording = True
        self._record_started = time.monotonic()

    async def _on_binary(self, payload: bytes) -> None:
        if not self._recording or self._pcm is None:
            return
        if time.monotonic() - self._record_started > self.cfg.max_recording_seconds:
            await self._on_asr_end()
            return
        budget = int(self.cfg.max_recording_seconds * self._pcm.sample_rate * 2)
        remaining = max(0, budget - self._pcm.data_size)
        self._pcm.write(payload[:remaining])
        if self._pcm.data_size >= budget:
            await self._on_asr_end()

    async def _on_asr_end(self) -> None:
        if not self._recording:
            return
        self._recording = False
        acc = self._pcm
        self._pcm = None
        if not await self._require_voice():
            return
        if acc is None or acc.data_size < 320:
            await self.send_json(t="error", msg="recording too short", code="asr_short")
            return
        seconds = acc.duration_seconds()
        name = time.strftime("harmony-voice-%Y%m%dT%H%M%S.wav", time.gmtime())
        try:
            await self._connect_hermes()
            sid = await self._ensure_active_session()
            wav_bytes = acc.to_wav()
            attached = await self.hermes.file_attach_wav(sid, wav_bytes, name=name)
            ref_text = str(attached.get("ref_text") or "").strip()
            if not ref_text:
                path = str(attached.get("path") or attached.get("ref_path") or name)
                ref_text = f"@file:{path}"
            transcript_hint = ""
            try:
                transcript_hint = await asyncio.wait_for(self.hermes.transcribe(wav_bytes, profile=self.cfg.hermes.profile), timeout=20.0)
            except Exception as exc:
                log.info("private voice transcript unavailable: %s", type(exc).__name__)
            text = voice_turn_text(
                ref_text=ref_text,
                name=name,
                seconds=seconds,
                transcript_hint=transcript_hint,
            )
            if self.watchdog and not self.watchdog.arm(sid):
                await self.send_json(t="error", msg="session already has an active turn", code="busy", session=sid)
                return
            self._arm_auto_speak(sid)
            try:
                await self.hermes.prompt_submit(sid, text, display_kind="hidden")
            except Exception:
                self._disarm_auto_speak()
                if self.watchdog:
                    self.watchdog.settle(sid)
                raise
        except Exception as exc:
            log.warning("voice attach failed: %s", exc)
            await self.send_json(t="error", msg="voice send failed", code="asr")
            return
        # Empty body: old phones wait on this frame; do not put words in the chat.
        await self.send_json(t="transcript", body="", kind="voice", seconds=round(seconds))

    async def _on_tts(self, obj: dict) -> None:
        text = str(obj.get("text") or "").strip()
        if not text:
            await self.send_json(t="error", msg="text required", code="tts")
            return
        try:
            await self._connect_hermes()
            await self._speak_to_phone(text)
        except Exception as exc:
            log.warning("tts failed: %s", exc)
            await self.send_json(t="error", msg="tts failed", code="tts")

    async def _speak_to_phone(self, text: str) -> None:
        if not await self._require_voice():
            return
        async with self._tts_lock:
            if self.ws.closed:
                return
            now = time.monotonic()
            if text == self._last_spoken and (now - self._last_spoken_at) < 12:
                return
            await self._speak_to_phone_locked(text)
            self._last_spoken = text
            self._last_spoken_at = time.monotonic()

    async def _speak_to_phone_locked(self, text: str) -> None:
        sent_start = False
        sent_bytes = 0
        aborted = False
        sample_rate = 16000
        stream_complete = False
        try:
            async for kind, payload in self.hermes.speak_stream(text, profile=self.cfg.hermes.profile):
                if kind == "fallback":
                    break
                if kind == "start":
                    sample_rate = int((payload or {}).get("sample_rate") or 16000)
                    await self.send_json(t="tts_start", sr=sample_rate, fmt="pcm16")
                    sent_start = True
                elif kind == "pcm":
                    if not sent_start:
                        await self.send_json(t="tts_start", sr=sample_rate, fmt="pcm16")
                        sent_start = True
                    chunk = payload if isinstance(payload, (bytes, bytearray)) else b""
                    if chunk and not await self.send_bin(bytes(chunk)):
                        aborted = True
                        break
                    sent_bytes += len(chunk)
                elif kind == "end":
                    stream_complete = True
                    break
            if sent_start and sent_bytes:
                await self.send_json(t="tts_end", aborted=aborted or not stream_complete, bytes=sent_bytes)
                sent_start = False
                if not stream_complete:
                    raise HermesError("speech stream ended before completion")
                return
            if sent_start:
                await self.send_json(t="tts_end", aborted=True, bytes=0)
                sent_start = False
            if self.ws.closed:
                return
            audio, mime = await self.hermes.speak(text, profile=self.cfg.hermes.profile)
            pcm, sr = await self._to_pcm(audio, mime)
            await self.send_json(t="tts_start", sr=sr, fmt="pcm16", bytes=len(pcm))
            sent_start = True
            for frame in chunk_bytes(pcm, 4096):
                if not await self.send_bin(frame):
                    aborted = True
                    break
                sent_bytes += len(frame)
            await self.send_json(t="tts_end", aborted=aborted, bytes=sent_bytes)
        except BaseException:
            if sent_start and not self.ws.closed:
                await self.send_json(t="tts_end", aborted=True, bytes=sent_bytes)
            raise

    async def _to_pcm(self, blob: bytes, mime: str) -> tuple[bytes, int]:
        if "wav" in (mime or "") or blob[:4] == b"RIFF":
            parsed = parse_wav(blob)
            if parsed["audio_format"] == 1 and parsed["channels"] == 1 and parsed["bits_per_sample"] == 16 and parsed["sample_rate"] in (16000, 24000):
                return parsed["data"], int(parsed["sample_rate"] or 16000)
        wav = await ffmpeg_to_pcm_wav(blob)
        parsed = parse_wav(wav)
        return parsed["data"], int(parsed["sample_rate"] or 16000)


def aiohttp_session():
    import aiohttp

    return aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=None, sock_connect=10, sock_read=300))


def _check_app_password(request: web.Request, cfg: BridgeConfig) -> None:
    cf_id = request.headers.get("cf-access-client-id") or request.headers.get("CF-Access-Client-Id")
    if cf_id:
        log.info("CF Access client id present (len=%s)", len(cf_id))
    cf_secret = request.headers.get("cf-access-client-secret") or request.headers.get("CF-Access-Client-Secret")
    if cf_secret:
        log.info("CF Access client secret present (len=%s)", len(cf_secret))

    # HarmonyOS / some mobile WS stacks drop custom headers. Accept the password
    # from the query as a fallback. Access logging never includes query values.
    provided = request.headers.get("X-Hermes-App-Password", "")
    if not provided:
        q = request.rel_url.query
        raw = (q.get("password") or "").strip()
        if raw:
            provided = raw
            log.info("app password supplied via query (len=%s)", len(raw))

    expected = cfg.app_password
    password_ok = (
        bool(expected)
        and len(provided) == len(expected)
        and hmac.compare_digest(provided, expected)
    )
    if not password_ok:
        raise web.HTTPUnauthorized(text="invalid app password")


async def maintain_hermes(client: HermesClient, cfg: BridgeConfig, *, interval: float = 5.0) -> None:
    """Reconnect idle dashboard links with bounded backoff; never replace a healthy link."""
    delay = interval
    while True:
        await asyncio.sleep(delay)
        if client.connected:
            delay = interval
            continue
        try:
            # Rediscovery handles a serve restart and its dynamic port/token.
            await client.close(clear_server_requests=False)
            client.bind(await asyncio.to_thread(discover_endpoint, cfg.hermes))
            await client.ensure_connected(attempts=1)
            delay = interval
        except Exception as exc:
            log.warning("Hermes reconnect pending: %s", type(exc).__name__)
            delay = min(max(interval, delay * 2), 60.0)


def create_app(cfg: BridgeConfig, *, hermes: HermesClient | None = None) -> web.Application:
    app = web.Application()
    app["cfg"] = cfg
    app["hermes"] = hermes
    app["store"] = DeviceStore(cfg.state_dir / "devices.json")
    app["limiter"] = RateLimiter(cfg.turns_per_minute)
    app["fanout"] = Fanout()
    app["connected"] = {}
    app["phones"] = set()
    app["turn_watchdog"] = None
    app["hermes_event_lock"] = asyncio.Lock()
    app["http"] = None

    async def on_startup(_app):
        session = aiohttp_session()
        _app["http"] = session
        client = _app["hermes"] or HermesClient(session)
        _app["hermes"] = client

        async def _on_hermes_event(params: dict) -> None:
            async with _app["hermes_event_lock"]:
                if params.get("type") == "gateway.ready":
                    epoch = (params.get("payload") or {}).get("replay_epoch")
                    for phone in list(_app["phones"]):
                        try:
                            await phone.send_json(t="ready", epoch=epoch or "", hermes=True,
                                                  features=["a2a_task_correlation_v1", "a2a_control_handoff_v1"])
                        except Exception:
                            log.debug("epoch broadcast failed", exc_info=True)
                sid = str(params.get("session_id") or "")
                event, request_id, terminal = _app["turn_watchdog"].observe_event(
                    params, agent_session=_app["store"].is_agent_session(sid)
                )
                if (not request_id and sid and _app["store"].is_agent_session(sid)):
                    request_id = _app["store"].agent_request_for_event(sid, params)
                    if request_id:
                        event = dict(params)
                        event["harmony_request_id"] = request_id
                        terminal = _is_agent_turn_terminal(event)
                if sid:
                    watchdog = _app["turn_watchdog"]
                    activity_request_id = request_id
                    if not _app["store"].is_agent_session(sid):
                        activity_request_id = watchdog.request_id(sid)
                    watchdog.progress(sid, activity_request_id)
                if request_id and params.get("type") in {"approval.request", "clarify.request"}:
                    payload = params.get("payload") or {}
                    control_request_id = payload.get("request_id") if isinstance(payload, dict) else None
                    server_request_id = (
                        payload.get("harmony_server_request_id") if isinstance(payload, dict) else None
                    )
                    if (isinstance(control_request_id, str) and control_request_id) or server_request_id:
                        _app["store"].remember_agent_control_event(
                            sid, request_id, str(params["type"]),
                            str(control_request_id or server_request_id),
                            server_request_id=(str(server_request_id) if server_request_id else ""),
                        )
                await _app["fanout"].emit(event)
                if terminal and sid:
                    _app["turn_watchdog"].settle(sid, request_id)

        client.on_event(_on_hermes_event)
        async def _notify_turn_timeout(sid: str) -> None:
            interrupted = _app["turn_watchdog"].interrupt_confirmed(sid)
            for phone in list(_app["fanout"].subscribers(sid)):
                request_id = phone._turn_request_ids.pop(sid, "") or _app["turn_watchdog"].request_id(sid)
                await phone.send_json(
                    t="error", msg="assistant turn timed out", code="turn_timeout", session=sid,
                    interrupted=interrupted,
                    request_id=request_id or None,
                )

        _app["turn_watchdog"] = TurnWatchdog(
            client, cfg.phone_turn_timeout_seconds, _notify_turn_timeout,
            max_duration=cfg.phone_turn_max_seconds,
        )

        try:
            if client.endpoint is None:
                client.bind(await asyncio.to_thread(discover_endpoint, cfg.hermes))
            await client.ensure_connected(attempts=1)
            log.info("Hermes bound tier=%s url=%s", client.discovery_tier, client.base_url)
        except Exception as exc:
            log.warning("Hermes not available at startup: %s", type(exc).__name__)
        _app["hermes_monitor"] = asyncio.create_task(maintain_hermes(client, cfg), name="hermes-monitor")

    async def on_cleanup(_app):
        watchdog = _app.get("turn_watchdog")
        if watchdog:
            await watchdog.close()
        monitor = _app.get("hermes_monitor")
        if monitor:
            monitor.cancel()
            await asyncio.gather(monitor, return_exceptions=True)
        client = _app.get("hermes")
        if client:
            await client.close()
        session = _app.get("http")
        if session:
            await session.close()

    async def healthz(request):
        client = request.app.get("hermes")
        return web.json_response(
            {
                "ok": True,
                "hermes": {
                    "url": client.base_url if client else None,
                    "connected": bool(client and client.connected),
                    "tier": client.discovery_tier if client else None,
                    "epoch": client.replay_epoch if client else None,
                },
            }
        )

    async def app_ws(request):
        cfg_local = request.app["cfg"]
        _check_app_password(request, cfg_local)
        # Long voice submission occupies this connection's receive loop. An
        # aiohttp heartbeat would time out while its pong waits unread; the
        # application ping/pong loop above provides the liveness check.
        ws = web.WebSocketResponse(autoping=True, max_msg_size=8 * 1024 * 1024)
        await ws.prepare(request)
        session = AppSession(
            ws,
            cfg_local,
            request.app["hermes"],
            request.app["store"],
            request.app["limiter"],
            request.app["fanout"],
            request.app["connected"],
            request.app["turn_watchdog"],
        )
        session._registry = request.app["phones"]
        request.app["phones"].add(session)
        await session.run()
        return ws

    app.router.add_get("/healthz", healthz)
    app.router.add_get("/v2/app", app_ws)
    app.on_startup.append(on_startup)
    app.on_cleanup.append(on_cleanup)
    return app


async def _run(cfg: BridgeConfig) -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    if cfg.port == 7690:
        raise SystemExit("port 7690 is reserved for hermes-cardputer; use 7691")
    runner = web.AppRunner(create_app(cfg), access_log_class=RedactingAccessLogger)
    await runner.setup()
    await web.TCPSite(runner, cfg.host, cfg.port).start()
    log.info("bridge listening on ws://%s:%s/v2/app", cfg.host, cfg.port)
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, stop.set)
        except NotImplementedError:
            pass
    try:
        await stop.wait()
    finally:
        await runner.cleanup()


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description="Hermes HarmonyOS bridge")
    parser.add_argument("--config", default=os.environ.get("HERMES_HARMONY_BRIDGE_CONFIG"))
    parser.add_argument("--host")
    parser.add_argument("--port", type=int)
    args = parser.parse_args(argv)
    cfg = load_config(args.config)
    if args.host:
        cfg.host = args.host
    if args.port:
        cfg.port = args.port
    try:
        asyncio.run(_run(cfg))
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
