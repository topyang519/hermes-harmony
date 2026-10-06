"""Session-keyed fan-out of raw Hermes event params to subscribed phone sockets."""

from __future__ import annotations

import logging
from collections import defaultdict
from typing import Any, Protocol

log = logging.getLogger(__name__)


class EventSink(Protocol):
    async def send_event(self, params: dict[str, Any]) -> None: ...


class Fanout:
    def __init__(self) -> None:
        self._subs: dict[str, set[EventSink]] = defaultdict(set)
        self._by_sink: dict[EventSink, set[str]] = defaultdict(set)

    def subscribe(self, session_id: str, sink: EventSink) -> None:
        if not session_id:
            return
        self._subs[session_id].add(sink)
        self._by_sink[sink].add(session_id)

    def unsubscribe(self, session_id: str, sink: EventSink) -> None:
        if session_id in self._subs:
            self._subs[session_id].discard(sink)
            if not self._subs[session_id]:
                del self._subs[session_id]
        if sink in self._by_sink:
            self._by_sink[sink].discard(session_id)

    def unsubscribe_all(self, sink: EventSink) -> None:
        for sid in list(self._by_sink.get(sink, ())):
            self.unsubscribe(sid, sink)
        self._by_sink.pop(sink, None)

    def subscribers(self, session_id: str) -> set[EventSink]:
        return set(self._subs.get(session_id, ()))

    async def emit(self, params: dict[str, Any]) -> None:
        sid = str(params.get("session_id") or "")
        if not sid:
            return
        for sink in list(self._subs.get(sid, ())):
            try:
                await sink.send_event(params)
            except Exception:
                log.debug("fanout send failed", exc_info=True)
