from __future__ import annotations

import logging
from urllib.error import URLError

from hermes_harmony_bridge.discovery import HermesEndpoint, _discover_live_processes, _probe
from hermes_harmony_bridge.hermes import HermesClient


def test_safe_url_omits_userinfo_query_fragment_and_path():
    endpoint = HermesEndpoint(
        "https://private-user:private-pass@example.test:8443/base?password=query-secret#token",
        "session-token",
        1,
    )

    assert endpoint.safe_url == "https://example.test:8443"


def test_hermes_base_url_is_safe_for_health_reporting():
    endpoint = HermesEndpoint(
        "https://private-user:private-pass@example.test/base?password=query-secret",
        "session-token",
        1,
    )
    client = HermesClient(None)
    client.endpoint = endpoint

    assert client.base_url == "https://example.test"


def test_safe_url_brackets_ipv6_host():
    endpoint = HermesEndpoint("https://user:secret@[2001:db8::1]:9443/path?token=x", "token", 1)

    assert endpoint.safe_url == "https://[2001:db8::1]:9443"


def test_process_discovery_invokes_ps_with_argument_vector(monkeypatch):
    calls = []

    def check_output(args, **kwargs):
        calls.append((args, kwargs))
        return "  1 launchd\n"

    monkeypatch.setattr("hermes_harmony_bridge.discovery._resolve_tool", lambda *_args: "ps")
    monkeypatch.setattr("hermes_harmony_bridge.discovery.subprocess.check_output", check_output)

    assert list(_discover_live_processes()) == []
    assert calls[0][0] == ["ps", "-ax", "-o", "pid=,command="]
    assert calls[0][1]["text"] is True
    assert "shell" not in calls[0][1]


def test_probe_failure_does_not_log_configured_url_credentials(monkeypatch, caplog):
    caplog.set_level(logging.INFO, logger="hermes_harmony_bridge.discovery")
    endpoint = HermesEndpoint(
        "https://private-user:private-pass@example.test/base?password=query-secret",
        "session-token",
        1,
    )

    def fail(*_args, **_kwargs):
        raise URLError("https://example.test/base?password=response-secret")

    monkeypatch.setattr("hermes_harmony_bridge.discovery.urlopen", fail)

    assert _probe(endpoint) is False
    assert "example.test" in caplog.text
    for secret in ("private-user", "private-pass", "query-secret", "session-token", "response-secret"):
        assert secret not in caplog.text
