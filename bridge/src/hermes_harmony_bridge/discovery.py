"""Three-tier discovery of the local `hermes serve` dashboard.

Ported from hermes-cardputer/bridge/src/hermes_bridge/discovery.py. Do not log
the session token.
"""

from __future__ import annotations

import logging
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable
from urllib.parse import urlparse
from urllib.request import Request, urlopen

from hermes_harmony_bridge.config import HermesSettings

log = logging.getLogger(__name__)
_TOKEN_ENV = "HERMES_DASHBOARD_SESSION_TOKEN"


@dataclass(frozen=True)
class HermesEndpoint:
    url: str
    token: str
    tier: int
    pid: int | None = None
    port: int | None = None

    @property
    def ws_url(self) -> str:
        parsed = urlparse(self.url)
        scheme = "wss" if parsed.scheme == "https" else "ws"
        netloc = parsed.netloc or parsed.path
        return f"{scheme}://{netloc}/api/ws"

    @property
    def safe_url(self) -> str:
        """Return only the HTTP origin, excluding URL credentials and request data."""
        try:
            parsed = urlparse(self.url)
            host = parsed.hostname
            if not host:
                return "<invalid-url>"
            if ":" in host:  # Keep IPv6 host syntax valid when rebuilding netloc.
                host = f"[{host}]"
            port = parsed.port
            netloc = f"{host}:{port}" if port is not None else host
            return f"{parsed.scheme}://{netloc}"
        except ValueError:
            return "<invalid-url>"


def discover_endpoint(settings: HermesSettings, *, probe: bool = True) -> HermesEndpoint:
    errors: list[str] = []
    if settings.url and settings.token:
        ep = HermesEndpoint(url=_normalize_url(settings.url), token=settings.token, tier=1)
        if not probe or _probe(ep):
            return ep
        errors.append(f"tier1 probe failed for {ep.safe_url}")
    live = list(_discover_live_processes())
    for ep in live:
        if not probe or _probe(ep):
            return ep
        errors.append(f"tier2 probe failed pid={ep.pid} url={ep.safe_url}")
    if settings.allow_spawn and not live:
        ep = _spawn_hermes(settings)
        if not probe or _probe(ep):
            return ep
        errors.append(f"tier3 spawn probe failed for {ep.safe_url}")
    detail = "; ".join(errors) if errors else "no hermes serve process found"
    raise RuntimeError(f"Hermes dashboard discovery failed: {detail}")


def _normalize_url(url: str) -> str:
    text = url.strip().rstrip("/")
    if text.startswith("ws://"):
        text = "http://" + text[5:]
    elif text.startswith("wss://"):
        text = "https://" + text[6:]
    if "://" not in text:
        text = "http://" + text
    return text


def _probe(endpoint: HermesEndpoint, timeout: float = 3.0) -> bool:
    url = f"{endpoint.url}/api/audio/voice-config"
    req = Request(url, headers={"X-Hermes-Session-Token": endpoint.token})
    try:
        with urlopen(req, timeout=timeout) as resp:  # noqa: S310
            return 200 <= resp.status < 300
    except Exception as exc:
        log.info("probe failed %s: %s", endpoint.safe_url, type(exc).__name__)
        return False


def _discover_live_processes() -> Iterable[HermesEndpoint]:
    ps = _resolve_tool("ps", "/bin/ps")
    try:
        listing = subprocess.check_output(
            [ps, "-ax", "-o", "pid=,command="], text=True, stderr=subprocess.DEVNULL
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        log.warning("cannot list processes with %s: %s", ps, exc)
        return
    for line in listing.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            pid_s, command = line.split(None, 1)
            pid = int(pid_s)
        except ValueError:
            continue
        if "gateway" in command:
            continue
        if not ("hermes_cli.main serve" in command or ("hermes_cli.main" in command and " serve" in command)):
            continue
        port = _listening_port(pid)
        token = _process_token(pid)
        if port and token:
            yield HermesEndpoint(url=f"http://127.0.0.1:{port}", token=token, tier=2, pid=pid, port=port)


def _resolve_tool(name: str, *fallbacks: str) -> str:
    found = shutil.which(name)
    if found:
        return found
    for candidate in fallbacks:
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return name


def _listening_port(pid: int) -> int | None:
    lsof = _resolve_tool("lsof", "/usr/sbin/lsof", "/usr/bin/lsof")
    try:
        out = subprocess.check_output(
            [lsof, "-nP", "-a", "-p", str(pid), "-iTCP", "-sTCP:LISTEN"],
            text=True, stderr=subprocess.DEVNULL,
        )
    except OSError as exc:
        log.warning("cannot run %s (PATH=%s): %s", lsof, os.environ.get("PATH", ""), exc)
        return None
    except subprocess.CalledProcessError:
        return None
    loopback = [int(m.group(1)) for line in out.splitlines()[1:] if (m := re.search(r"127\.0\.0\.1:(\d+)\s+\(LISTEN\)", line))]
    ports = [int(m.group(1)) for line in out.splitlines()[1:] if (m := re.search(r":(\d+)\s+\(LISTEN\)", line))]
    return (loopback or ports or [None])[0]


def _process_token(pid: int) -> str | None:
    env = _read_process_environ(pid)
    token = (env.get(_TOKEN_ENV) or "").strip()
    return token or None


def _read_process_environ(pid: int) -> dict[str, str]:
    if sys.platform == "darwin":
        try:
            return _macos_procargs2_environ(pid)
        except Exception:
            pass
    try:
        out = subprocess.check_output(
            ["ps", "eww", "-ww", "-p", str(pid), "-o", "command="], text=True, stderr=subprocess.DEVNULL
        )
    except (OSError, subprocess.CalledProcessError):
        return {}
    return {m.group(1): m.group(2) for m in re.finditer(r"([A-Z_][A-Z0-9_]*)=([^\s]*)", out)}


def _macos_procargs2_environ(pid: int) -> dict[str, str]:
    import ctypes
    from ctypes import POINTER, c_int, c_size_t, c_void_p, create_string_buffer

    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    sysctl = libc.sysctl
    sysctl.argtypes = [POINTER(c_int), c_int, c_void_p, POINTER(c_size_t), c_void_p, c_size_t]
    sysctl.restype = c_int
    mib = (c_int * 3)(1, 49, pid)
    size = c_size_t(0)
    if sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0:
        raise OSError(ctypes.get_errno(), "sysctl size")
    buf = create_string_buffer(size.value)
    if sysctl(mib, 3, buf, ctypes.byref(size), None, 0) != 0:
        raise OSError(ctypes.get_errno(), "sysctl data")
    data = bytes(buf[: size.value])
    argc = int.from_bytes(data[:4], "little")
    rest = data[4:]
    nul = rest.find(b"\x00")
    rest = rest[nul + 1 :]
    while rest.startswith(b"\x00"):
        rest = rest[1:]
    for _ in range(argc):
        nul = rest.find(b"\x00")
        if nul < 0:
            break
        rest = rest[nul + 1 :]
    while rest.startswith(b"\x00"):
        rest = rest[1:]
    env: dict[str, str] = {}
    while rest:
        nul = rest.find(b"\x00")
        if nul <= 0:
            break
        item = rest[:nul].decode("utf-8", "replace")
        rest = rest[nul + 1 :]
        if "=" in item:
            k, _, v = item.partition("=")
            env[k] = v
    return env


def _spawn_hermes(settings: HermesSettings) -> HermesEndpoint:
    import secrets
    import time

    binary = settings.hermes_bin or str(Path.home() / ".hermes/hermes-agent/venv/bin/hermes")
    if not Path(binary).is_file():
        binary = shutil.which("hermes") or ""
    if not binary:
        raise RuntimeError("hermes binary not found for tier-3 spawn")
    token = secrets.token_urlsafe(32)
    env = os.environ.copy()
    env[_TOKEN_ENV] = token
    port = int(settings.spawn_port)
    subprocess.Popen(
        [binary, "serve", "--host", "127.0.0.1", "--port", str(port)],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    ep = HermesEndpoint(url=f"http://127.0.0.1:{port}", token=token, tier=3, port=port)
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if _probe(ep, timeout=1.0):
            return ep
        time.sleep(0.4)
    return ep
