"""Per-device cursor and epoch persistence. Tokens never written here."""

from __future__ import annotations

import json
import logging
import math
import os
import stat
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path

log = logging.getLogger(__name__)


def _load_agent_turns(raw: object) -> list[dict[str, object]]:
    if not isinstance(raw, list):
        return []
    turns: list[dict[str, object]] = []
    for raw_turn in raw:
        if not isinstance(raw_turn, dict):
            continue
        values = (raw_turn.get("session_id"), raw_turn.get("request_id"), raw_turn.get("user_row_id"))
        created_at = raw_turn.get("created_at")
        if (not all(isinstance(value, str) and value for value in values)
                or isinstance(created_at, bool)
                or not isinstance(created_at, (int, float))
                or not math.isfinite(created_at)):
            continue
        turn: dict[str, object] = {
            "session_id": values[0],
            "request_id": values[1],
            "user_row_id": values[2],
            "created_at": float(created_at),
        }
        control_ids = raw_turn.get("control_ids")
        if isinstance(control_ids, list):
            turn["control_ids"] = list(dict.fromkeys(
                control_id for control_id in control_ids
                if isinstance(control_id, str) and 0 < len(control_id) <= 320
            ))[-32:]
        turns.append(turn)
    return turns[-256:]


@dataclass
class DeviceRecord:
    device_id: str = ""
    epoch: str | None = None
    cursors: dict[str, int] = field(default_factory=dict)
    stored_ids: dict[str, str] = field(default_factory=dict)
    agent_sessions: list[str] = field(default_factory=list)
    agent_turns: list[dict[str, object]] = field(default_factory=list)


class SidMap:
    """Runtime session_id (event seq key) ↔ stored session_id (session.resume / session.list)."""

    def __init__(self) -> None:
        self._to_runtime: dict[str, str] = {}
        self._to_stored: dict[str, str] = {}

    def remember(self, runtime: str, stored: str | None = None) -> None:
        if not runtime:
            return
        stored = stored or runtime
        self._to_runtime[runtime] = runtime
        self._to_runtime[stored] = runtime
        self._to_stored[runtime] = stored
        self._to_stored[stored] = stored

    def runtime(self, sid: str) -> str:
        return self._to_runtime.get(sid) or sid

    def stored(self, sid: str) -> str:
        return self._to_stored.get(sid) or sid

    def known(self, sid: str) -> bool:
        return sid in self._to_runtime or sid in self._to_stored

    def forget(self, sid: str) -> None:
        runtime = self.runtime(sid)
        stored = self.stored(sid)
        related = {sid, runtime, stored}
        for key, value in list(self._to_runtime.items()):
            if key in related or value in related:
                self._to_runtime.pop(key, None)
        for key, value in list(self._to_stored.items()):
            if key in related or value in related:
                self._to_stored.pop(key, None)


class DeviceStore:
    def __init__(self, path: Path):
        self.path = path
        self._records: dict[str, DeviceRecord] = {}
        self.sid_map = SidMap()
        self._secure_storage_permissions()
        self._load()

    def _secure_storage_permissions(self, *, platform: str | None = None) -> None:
        """Restrict persisted device/session metadata to the bridge owner."""
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if (platform or os.name) != "nt":
            os.chmod(self.path.parent, 0o700)
        try:
            mode = self.path.lstat().st_mode
        except FileNotFoundError:
            return
        if not stat.S_ISREG(mode):
            raise OSError("device state must be a regular file")
        if (platform or os.name) != "nt":
            os.chmod(self.path, 0o600)

    def _load(self) -> None:
        if not self.path.is_file():
            return
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            log.warning("could not read device store: %s", exc)
            return
        devices = raw.get("devices") if isinstance(raw, dict) else None
        if not isinstance(devices, dict):
            return
        for key, value in devices.items():
            if not isinstance(value, dict):
                continue
            cursors = value.get("cursors") or {}
            stored = value.get("stored_ids") or {}
            safe_cursors: dict[str, int] = {}
            if isinstance(cursors, dict):
                for cursor_key, cursor_value in cursors.items():
                    if isinstance(cursor_value, bool):
                        continue
                    try:
                        safe_cursors[str(cursor_key)] = int(cursor_value)
                    except (TypeError, ValueError, OverflowError):
                        continue
            rec = DeviceRecord(
                device_id=str(value.get("device_id") or key),
                epoch=value.get("epoch"),
                cursors=safe_cursors,
                stored_ids={str(k): str(v) for k, v in stored.items()} if isinstance(stored, dict) else {},
                agent_sessions=[str(sid) for sid in value.get("agent_sessions", [])
                                if isinstance(sid, str)]
                if isinstance(value.get("agent_sessions", []), list) else [],
                agent_turns=_load_agent_turns(value.get("agent_turns", [])),
            )
            self._records[str(key)] = rec
            for runtime, stored_id in rec.stored_ids.items():
                self.sid_map.remember(runtime, stored_id)

    def get(self, key: str) -> DeviceRecord:
        rec = self._records.get(key)
        if rec is None:
            rec = DeviceRecord(device_id=key)
            self._records[key] = rec
        return rec

    def mark_agent_session(self, device_key: str, runtime_id: str, stored_id: str) -> None:
        """Persist session IDs reserved for the Xiaoyi Agent integration."""
        if not device_key or not runtime_id:
            return
        rec = self.get(device_key)
        stored_id = stored_id or runtime_id
        self.sid_map.remember(runtime_id, stored_id)
        rec.stored_ids[runtime_id] = stored_id
        canonical = self.sid_map.runtime(runtime_id)
        rec.agent_sessions = [
            sid for sid in rec.agent_sessions if self.sid_map.runtime(sid) != canonical
        ]
        rec.agent_sessions.append(stored_id)
        rec.agent_sessions = rec.agent_sessions[-24:]
        self.save()

    def is_agent_session(self, session_id: str) -> bool:
        if not session_id:
            return False
        canonical = self.sid_map.runtime(session_id)
        return any(
            self.sid_map.runtime(agent_sid) == canonical
            for rec in self._records.values()
            for agent_sid in rec.agent_sessions
        )

    def remember_agent_turn(
        self, device_key: str, session_id: str, request_id: str, user_row_id: str
    ) -> None:
        """Persist request-to-Hermes-turn correlation for reconnects and bridge restarts."""
        if not all((device_key, session_id, request_id, user_row_id)):
            return
        rec = self.get(device_key)
        now = time.time()
        rec.agent_turns = [
            turn for turn in rec.agent_turns
            if now - float(turn.get("created_at", 0)) <= 3600
            and turn.get("request_id") != request_id
        ]
        rec.agent_turns.append({
            "session_id": session_id,
            "request_id": request_id,
            "user_row_id": user_row_id,
            "created_at": now,
            "control_ids": [],
        })
        rec.agent_turns = rec.agent_turns[-256:]
        self.save()

    def agent_request_for_event(self, session_id: str, params: dict) -> str:
        """Find persisted turn completions or fenced control events by exact identity."""
        event_type = params.get("type")
        payload = params.get("payload") or {}
        if event_type == "message.complete":
            persisted = payload.get("persisted_turn") if isinstance(payload, dict) else None
            row_id = persisted.get("user_row_id") if isinstance(persisted, dict) else None
            if row_id is None:
                return ""
        elif event_type in {"approval.request", "clarify.request"}:
            if not isinstance(payload, dict):
                return ""
            control_ids = set()
            control_request_id = payload.get("request_id")
            if isinstance(control_request_id, str) and control_request_id:
                control_ids.add(f"{event_type}:{control_request_id}")
            server_request_id = payload.get("harmony_server_request_id")
            if isinstance(server_request_id, str) and server_request_id:
                control_ids.add(f"{event_type}:server:{server_request_id}")
            if not control_ids:
                return ""
            row_id = None
        else:
            return ""
        canonical = self.sid_map.runtime(session_id)
        now = time.time()
        for rec in self._records.values():
            for turn in reversed(rec.agent_turns):
                if now - float(turn.get("created_at", 0)) > 3600:
                    continue
                if self.sid_map.runtime(str(turn.get("session_id") or "")) != canonical:
                    continue
                if row_id is not None and str(turn.get("user_row_id") or "") == str(row_id):
                    return str(turn.get("request_id") or "")
                if (row_id is None and control_ids.intersection(turn.get("control_ids", []))):
                    return str(turn.get("request_id") or "")
        return ""

    def remember_agent_control_event(
        self, session_id: str, request_id: str, event_type: str, control_request_id: str,
        *, server_request_id: str = "",
    ) -> None:
        """Persist a control event only after the live watchdog fenced it to a turn."""
        if (not session_id or not request_id
                or event_type not in {"approval.request", "clarify.request"}
                or not control_request_id or len(control_request_id) > 256):
            return
        new_control_ids = {f"{event_type}:{control_request_id}"}
        if server_request_id and len(server_request_id) <= 256:
            new_control_ids.add(f"{event_type}:server:{server_request_id}")
        canonical = self.sid_map.runtime(session_id)
        now = time.time()
        for rec in self._records.values():
            for turn in reversed(rec.agent_turns):
                if (self.sid_map.runtime(str(turn.get("session_id") or "")) != canonical
                        or turn.get("request_id") != request_id
                        or now - float(turn.get("created_at", 0)) > 3600):
                    continue
                stored_control_ids = turn.setdefault("control_ids", [])
                if not isinstance(stored_control_ids, list):
                    stored_control_ids = []
                    turn["control_ids"] = stored_control_ids
                new_ids = new_control_ids.difference(stored_control_ids)
                if new_ids:
                    stored_control_ids.extend(sorted(new_ids))
                    del stored_control_ids[:-32]
                    self.save()
                return

    def forget_session(self, *session_ids: str) -> None:
        related = {sid for sid in session_ids if sid}
        for sid in tuple(related):
            related.add(self.sid_map.runtime(sid))
            related.add(self.sid_map.stored(sid))
        if not related:
            return
        for rec in self._records.values():
            for runtime, stored in list(rec.stored_ids.items()):
                if runtime in related or stored in related:
                    related.add(runtime)
                    related.add(stored)
                    rec.stored_ids.pop(runtime, None)
            rec.agent_sessions = [
                sid for sid in rec.agent_sessions
                if sid not in related and self.sid_map.runtime(sid) not in related
            ]
            rec.agent_turns = [
                turn for turn in rec.agent_turns
                if str(turn.get("session_id") or "") not in related
                and self.sid_map.runtime(str(turn.get("session_id") or "")) not in related
            ]
            for sid in related:
                rec.cursors.pop(sid, None)
        for sid in related:
            self.sid_map.forget(sid)
        self.save()

    def save(self) -> None:
        self._secure_storage_permissions()
        payload = {"devices": {k: asdict(v) for k, v in self._records.items()}}
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        if os.name != "nt":
            os.chmod(tmp, 0o600)
        tmp.replace(self.path)
