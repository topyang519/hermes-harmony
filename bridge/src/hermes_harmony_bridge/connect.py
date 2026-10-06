"""Computer connector: local bridge plus outbound relay tunnel."""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import logging
import os
import plistlib
import re
import secrets
import signal
import stat
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlencode, urlsplit, urlunsplit

from aiohttp import ClientSession, WSMsgType, web

from hermes_harmony_bridge.config import BridgeConfig
from hermes_harmony_bridge.server import RedactingAccessLogger, create_app

log = logging.getLogger(__name__)
CONFIG = Path.home() / ".config" / "hermes-harmony" / "connection.json"
RELAY_CID = re.compile(r"[0-9a-f]{32}\Z")


def _config_has_broad_permissions(path: Path, *, platform: str | None = None) -> bool:
    """Check POSIX mode bits; Windows access is governed by account ACLs."""
    if (platform or os.name) == "nt":
        return False
    return bool(path.stat().st_mode & (stat.S_IRWXG | stat.S_IRWXO))


def validate_relay(url: str) -> str:
    parts = urlsplit(url.strip().rstrip("/"))
    if parts.scheme not in ("wss", "ws") or not parts.hostname or parts.username or parts.password or parts.query or parts.fragment or parts.path not in ("", "/"):
        raise ValueError("relay must be a bare wss://host address")
    try:
        parts.port  # Force urllib to reject nonnumeric and out-of-range ports.
    except ValueError as exc:
        raise ValueError("relay must be a bare wss://host address") from exc
    if parts.netloc.endswith(":"):
        raise ValueError("relay must be a bare wss://host address")
    if parts.scheme == "ws" and parts.hostname not in ("localhost", "127.0.0.1", "::1"):
        raise ValueError("public relay must use wss://")
    return urlunsplit((parts.scheme, parts.netloc, "", "", ""))


def load_or_create(path: Path, relay: str | None) -> dict[str, str | int]:
    if path.exists():
        if _config_has_broad_permissions(path):
            raise ValueError(f"configuration permissions are too broad: {path}; chmod 600 it")
        data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict) or any(
            not isinstance(data.get(key), str) or len(data[key]) < 32
            for key in ("host_token", "phone_token", "bridge_password")
        ):
            raise ValueError(f"invalid connection configuration: {path}")
        if type(data.get("local_port")) is not int or not 1 <= data["local_port"] <= 65535:
            raise ValueError(f"invalid local port in {path}")
        if relay is not None:
            data["relay"] = validate_relay(relay)
        if not isinstance(data.get("relay"), str):
            raise ValueError(f"invalid relay in {path}")
        if relay is not None:
            path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        validate_relay(str(data["relay"]))
        return data
    if relay is None:
        raise ValueError("first run requires --relay wss://your-relay.example")
    data: dict[str, str | int] = {
        "relay": validate_relay(relay),
        "host_token": secrets.token_urlsafe(32),
        "phone_token": secrets.token_urlsafe(32),
        "bridge_password": secrets.token_urlsafe(32),
        "local_port": 17691,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        json.dump(data, stream, indent=2)
        stream.write("\n")
    return data


def room_id(data: dict[str, str | int]) -> str:
    return hashlib.sha256(str(data["host_token"]).encode()).hexdigest()[:32]


def pairing_url(data: dict[str, str | int]) -> str:
    return f'{data["relay"]}/relay/phone/{room_id(data)}?{urlencode({"password": data["phone_token"]})}'


def install_service(config_path: Path, home: Path | None = None) -> str:
    """Start at desktop login; do not require administrator privileges."""
    home = home or Path.home()
    command = [sys.executable, "-m", "hermes_harmony_bridge.connect", "run", "--config", str(config_path)]
    if sys.platform == "darwin":
        label = "ai.hermes.harmony.connector"
        directory = home / "Library" / "LaunchAgents"
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / f"{label}.plist"
        logs = home / "Library" / "Logs"
        logs.mkdir(parents=True, exist_ok=True)
        payload = {
            "Label": label,
            "ProgramArguments": command,
            "RunAtLoad": True,
            "KeepAlive": True,
            "ThrottleInterval": 10,
            "StandardOutPath": str(logs / "hermes-harmony-connect.log"),
            "StandardErrorPath": str(logs / "hermes-harmony-connect.log"),
        }
        with path.open("wb") as stream:
            plistlib.dump(payload, stream)
        domain = f"gui/{os.getuid()}"
        subprocess.run(["launchctl", "bootout", f"{domain}/{label}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        subprocess.run(["launchctl", "bootstrap", domain, str(path)], check=True)
        return f"LaunchAgent {label}"
    if sys.platform.startswith("linux"):
        xdg_config_home = os.environ.get("XDG_CONFIG_HOME")
        config_home = Path(xdg_config_home).expanduser() if xdg_config_home else home / ".config"
        if not config_home.is_absolute():
            config_home = home / ".config"
        directory = config_home / "systemd" / "user"
        directory.mkdir(parents=True, exist_ok=True)
        unit = "hermes-harmony-connect.service"
        # systemd quotes arguments itself; quote paths containing spaces.
        args = " ".join('"' + part.replace('"', '\\"') + '"' for part in command)
        (directory / unit).write_text(
            "[Unit]\nDescription=Hermes Harmony computer connector\nAfter=network-online.target\n"
            "[Service]\nType=simple\nExecStart=" + args + "\nRestart=always\nRestartSec=5\n"
            "[Install]\nWantedBy=default.target\n", encoding="utf-8"
        )
        subprocess.run(["systemctl", "--user", "daemon-reload"], check=True)
        # daemon-reload updates the unit definition but leaves an already
        # running process on its previous command until it is restarted.
        subprocess.run(["systemctl", "--user", "try-restart", unit], check=True)
        subprocess.run(["systemctl", "--user", "enable", "--now", unit], check=True)
        return f"systemd --user {unit}"
    raise RuntimeError("automatic startup is supported on macOS and Linux")


async def relay_loop(data: dict[str, str | int], stop: asyncio.Event) -> None:
    host_url = f'{data["relay"]}/relay/host/{room_id(data)}'
    headers = {"X-Hermes-Host-Token": str(data["host_token"]), "X-Hermes-Phone-Token": str(data["phone_token"])}
    local_url = f'ws://127.0.0.1:{data["local_port"]}/v2/app?{urlencode({"password": data["bridge_password"]})}'
    delay = 1.0
    async with ClientSession() as session:
        while not stop.is_set():
            local: dict[str, object] = {}
            opening: dict[str, asyncio.Event] = {}
            tasks: set[asyncio.Task] = set()
            try:
                async with session.ws_connect(host_url, headers=headers, heartbeat=30, max_msg_size=8 * 1024 * 1024) as relay:
                    log.info("relay connected room=%s", room_id(data)[:8])
                    delay = 1.0
                    send_lock = asyncio.Lock()

                    async def send(payload: str | bytes) -> None:
                        async with send_lock:
                            if isinstance(payload, str):
                                await relay.send_str(payload)
                            else:
                                await relay.send_bytes(payload)

                    async def serve_phone(cid: str) -> None:
                        try:
                            async with session.ws_connect(local_url, max_msg_size=8 * 1024 * 1024) as bridge:
                                local[cid] = bridge
                                opening[cid].set()
                                async for msg in bridge:
                                    if msg.type == WSMsgType.TEXT:
                                        await send(json.dumps({"op": "data", "id": cid, "text": msg.data}))
                                    elif msg.type == WSMsgType.BINARY:
                                        await send(bytes.fromhex(cid) + msg.data)
                        except Exception as exc:
                            log.warning("local bridge session ended: %s", type(exc).__name__)
                        finally:
                            opening.pop(cid, asyncio.Event()).set()
                            local.pop(cid, None)
                            if not relay.closed:
                                await send(json.dumps({"op": "close", "id": cid}))

                    async for msg in relay:
                        if msg.type == WSMsgType.TEXT:
                            try:
                                packet = json.loads(msg.data)
                                op, cid = packet["op"], packet["id"]
                                if not isinstance(cid, str) or not RELAY_CID.fullmatch(cid):
                                    continue
                            except (ValueError, KeyError, TypeError):
                                continue
                            if op == "open" and cid not in opening:
                                opening[cid] = asyncio.Event()
                                task = asyncio.create_task(serve_phone(cid))
                                tasks.add(task)
                                task.add_done_callback(tasks.discard)
                            elif op == "data" and isinstance(packet.get("text"), str):
                                if cid in opening:
                                    try:
                                        await asyncio.wait_for(opening[cid].wait(), timeout=15)
                                    except asyncio.TimeoutError:
                                        log.warning("local bridge did not open phone session in time")
                                        continue
                                bridge = local.get(cid)
                                if bridge is not None:
                                    await bridge.send_str(packet["text"])
                            elif op == "close":
                                bridge = local.get(cid)
                                if bridge is not None:
                                    await bridge.close()
                        elif msg.type == WSMsgType.BINARY and len(msg.data) >= 16:
                            cid = msg.data[:16].hex()
                            if cid in opening:
                                try:
                                    await asyncio.wait_for(opening[cid].wait(), timeout=15)
                                except asyncio.TimeoutError:
                                    log.warning("local bridge did not open phone session in time")
                                    continue
                            bridge = local.get(cid)
                            if bridge is not None:
                                await bridge.send_bytes(msg.data[16:])
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                log.warning("relay connection lost: %s; retry in %.0fs", type(exc).__name__, delay)
            finally:
                for task in tasks:
                    task.cancel()
                await asyncio.gather(*tasks, return_exceptions=True)
            try:
                await asyncio.wait_for(stop.wait(), timeout=delay)
            except asyncio.TimeoutError:
                delay = min(delay * 2, 30.0)


async def run(data: dict[str, str | int], config_path: Path) -> None:
    cfg = BridgeConfig(host="127.0.0.1", port=int(data["local_port"]), app_password=str(data["bridge_password"]), state_dir=config_path.parent / "state")
    runner = web.AppRunner(create_app(cfg), access_log_class=RedactingAccessLogger)
    await runner.setup()
    await web.TCPSite(runner, cfg.host, cfg.port).start()
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, stop.set)
        except NotImplementedError:
            pass
    task = asyncio.create_task(relay_loop(data, stop))
    log.info("local bridge on 127.0.0.1:%s; outbound relay starting", cfg.port)
    try:
        await stop.wait()
    finally:
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)
        await runner.cleanup()


def main() -> None:
    parser = argparse.ArgumentParser(description="Pair this computer with Hermes Harmony")
    parser.add_argument("command", choices=("setup", "run", "start", "install-service"))
    parser.add_argument("--relay", help="public wss:// relay address (required on first setup)")
    parser.add_argument("--config", type=Path, default=CONFIG)
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    try:
        data = load_or_create(args.config, args.relay)
    except (ValueError, KeyError, TypeError, OSError) as exc:
        parser.error(str(exc))
    if args.command in ("setup", "start"):
        print("Open Settings in the Harmony app, then scan or paste this pairing link:")
        print(pairing_url(data))
        if sys.stdout.isatty():
            import qrcode
            qr = qrcode.QRCode(border=1)
            qr.add_data(pairing_url(data))
            qr.make(fit=True)
            qr.print_ascii(invert=True)
        print("Keep this link private. It grants access to your local Hermes Agent.")
    if args.command in ("run", "start"):
        asyncio.run(run(data, args.config))
    if args.command == "install-service":
        try:
            print("Background service installed:", install_service(args.config))
        except (OSError, subprocess.CalledProcessError, RuntimeError) as exc:
            parser.error(f"background service could not be installed: {type(exc).__name__}")


if __name__ == "__main__":
    main()
