"""Live gates against a real `hermes serve`. Opt-in: pytest -m live."""

from __future__ import annotations

import json

import pytest

from hermes_harmony_bridge.config import HermesSettings
from hermes_harmony_bridge.discovery import discover_endpoint

pytestmark = pytest.mark.live


def test_tier2_discovers_live_hermes():
    ep = discover_endpoint(HermesSettings(allow_spawn=False), probe=True)
    assert ep.tier == 2
    assert ep.pid
    assert ep.port
    assert ep.url.startswith("http://127.0.0.1:")
    assert ep.token and len(ep.token) >= 8
    print(json.dumps({"tier": ep.tier, "pid": ep.pid, "url": ep.url, "token_len": len(ep.token)}))
