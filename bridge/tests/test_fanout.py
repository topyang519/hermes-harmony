"""Fanout: independent per-subscriber delivery, no event translation."""

from __future__ import annotations

import pytest

from hermes_harmony_bridge.fanout import Fanout


class Sink:
    def __init__(self):
        self.got = []

    async def send_event(self, params):
        self.got.append(params)


@pytest.mark.asyncio
async def test_fanout_isolates_sessions_and_preserves_params():
    fan = Fanout()
    a = Sink()
    b = Sink()
    c = Sink()
    fan.subscribe("s1", a)
    fan.subscribe("s1", b)
    fan.subscribe("s2", c)
    raw = {"type": "message.delta", "session_id": "s1", "payload": {"text": "x"}, "seq": 3}
    await fan.emit(raw)
    await fan.emit({"type": "tool.start", "session_id": "s2", "payload": {"name": "term"}, "seq": 1})
    assert a.got == [raw]
    assert b.got == [raw]
    assert c.got[0]["type"] == "tool.start"
    assert a.got[0] is raw
    fan.unsubscribe("s1", a)
    await fan.emit({"type": "message.complete", "session_id": "s1", "payload": {}, "seq": 4})
    assert len(a.got) == 1
    assert b.got[-1]["seq"] == 4
