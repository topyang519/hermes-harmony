import asyncio
import hashlib
import json
import os
import plistlib

import pytest
from aiohttp import ClientSession, WSServerHandshakeError, WSMsgType, web

from hermes_harmony_bridge.connect import (
    RELAY_CID,
    _config_has_broad_permissions,
    install_service,
    load_or_create,
    pairing_url,
    relay_loop,
    room_id,
    validate_relay,
)
from hermes_harmony_bridge.relay import create_relay_app
import hermes_harmony_bridge.relay as relay_module


async def serve(app):
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", 0)
    await site.start()
    port = site._server.sockets[0].getsockname()[1]
    return runner, port


def test_pairing_config_is_private_and_stable(tmp_path):
    path = tmp_path / "connection.json"
    data = load_or_create(path, "ws://127.0.0.1:8765")
    if os.name != "nt":
        assert path.stat().st_mode & 0o077 == 0
    assert load_or_create(path, None) == data
    assert room_id(data) == hashlib.sha256(data["host_token"].encode()).hexdigest()[:32]
    assert f"/relay/phone/{room_id(data)}?password=" in pairing_url(data)
    assert data["host_token"] not in pairing_url(data)
    with pytest.raises(ValueError):
        validate_relay("ws://public.example.com")
    with pytest.raises(ValueError):
        validate_relay("wss://relay.example.com:not-a-port")
    with pytest.raises(ValueError):
        validate_relay("wss://relay.example.com:")


@pytest.mark.parametrize("cid", ["0" * 32, "a" * 32])
def test_relay_cid_requires_lowercase_hex(cid):
    assert RELAY_CID.fullmatch(cid)


@pytest.mark.parametrize("cid", ["g" * 32, "a" * 31, "A" * 32, "../" + "a" * 29])
def test_relay_cid_rejects_malformed_values(cid):
    assert RELAY_CID.fullmatch(cid) is None


def test_existing_pairing_config_rejects_bool_port_and_missing_relay(tmp_path):
    path = tmp_path / "connection.json"
    data = load_or_create(path, "ws://127.0.0.1:8765")
    data["local_port"] = True
    path.write_text(json.dumps(data), encoding="utf-8")
    path.chmod(0o600)
    with pytest.raises(ValueError, match="local port"):
        load_or_create(path, None)

    data["local_port"] = 17691
    del data["relay"]
    path.write_text(json.dumps(data), encoding="utf-8")
    path.chmod(0o600)
    with pytest.raises(ValueError, match="relay"):
        load_or_create(path, None)


def test_windows_config_permission_check_uses_account_acl_not_posix_bits(tmp_path):
    path = tmp_path / "connection.json"
    path.write_text("{}", encoding="utf-8")
    if os.name != "nt":
        path.chmod(0o644)

    assert _config_has_broad_permissions(path, platform="nt") is False


def test_macos_background_service_starts_on_login(monkeypatch, tmp_path):
    monkeypatch.setattr("sys.platform", "darwin")
    monkeypatch.setattr(os, "getuid", lambda: 501, raising=False)
    calls = []
    monkeypatch.setattr("subprocess.run", lambda argv, **kwargs: calls.append(argv))
    label = install_service(tmp_path / "connection.json", home=tmp_path)
    plist = plistlib.loads((tmp_path / "Library/LaunchAgents/ai.hermes.harmony.connector.plist").read_bytes())
    assert label.startswith("LaunchAgent")
    assert plist["RunAtLoad"] is True and plist["KeepAlive"] is True
    assert plist["ProgramArguments"][-1] == str(tmp_path / "connection.json")
    assert calls[-1][0:2] == ["launchctl", "bootstrap"]


def test_linux_background_service_starts_on_login(monkeypatch, tmp_path):
    monkeypatch.setattr("sys.platform", "linux")
    xdg_config = tmp_path / "xdg config"
    monkeypatch.setenv("XDG_CONFIG_HOME", str(xdg_config))
    calls = []
    monkeypatch.setattr("subprocess.run", lambda argv, **kwargs: calls.append(argv))
    config_path = tmp_path / "custom config.json"
    install_service(config_path, home=tmp_path)
    unit = (xdg_config / "systemd/user/hermes-harmony-connect.service").read_text()
    assert "Restart=always" in unit and "WantedBy=default.target" in unit
    assert str(config_path) in unit
    assert calls[-2] == ["systemctl", "--user", "try-restart", "hermes-harmony-connect.service"]
    assert calls[-1] == ["systemctl", "--user", "enable", "--now", "hermes-harmony-connect.service"]


@pytest.mark.asyncio
async def test_relay_auth_text_binary_and_disconnect(tmp_path):
    relay_runner, relay_port = await serve(create_relay_app())

    async def echo(request):
        ws = web.WebSocketResponse()
        await ws.prepare(request)
        async for msg in ws:
            if msg.type == WSMsgType.TEXT:
                await ws.send_str(msg.data)
            elif msg.type == WSMsgType.BINARY:
                await ws.send_bytes(msg.data)
        return ws

    local_app = web.Application()
    local_app.router.add_get("/v2/app", echo)
    local_runner, local_port = await serve(local_app)
    data = load_or_create(tmp_path / "config.json", f"ws://127.0.0.1:{relay_port}")
    data["local_port"] = local_port
    stop = asyncio.Event()
    tunnel = asyncio.create_task(relay_loop(data, stop))
    url = pairing_url(data)
    try:
        async with ClientSession() as session:
            for _ in range(50):
                try:
                    phone = await session.ws_connect(url)
                    break
                except WSServerHandshakeError as exc:
                    assert exc.status == 503
                    await asyncio.sleep(0.02)
            else:
                pytest.fail("computer never connected to relay")
            async with phone:
                await phone.send_str(json.dumps({"t": "hello"}))
                reply = await asyncio.wait_for(phone.receive(), 3)
                assert reply.type == WSMsgType.TEXT
                assert json.loads(reply.data) == {"t": "hello"}
                await phone.send_bytes(b"\x00\x01audio")
                reply = await asyncio.wait_for(phone.receive(), 3)
                assert reply.type == WSMsgType.BINARY
                assert reply.data == b"\x00\x01audio"
            with pytest.raises(WSServerHandshakeError) as wrong:
                await session.ws_connect(url.replace(str(data["phone_token"]), "wrong"))
            assert wrong.value.status == 401
            with pytest.raises(WSServerHandshakeError) as spoof:
                await session.ws_connect(
                    f'ws://127.0.0.1:{relay_port}/relay/host/{room_id(data)}',
                    headers={"X-Hermes-Host-Token": str(data["phone_token"]), "X-Hermes-Phone-Token": str(data["phone_token"])},
                )
            assert spoof.value.status == 400
    finally:
        stop.set()
        tunnel.cancel()
        await asyncio.gather(tunnel, return_exceptions=True)
        await local_runner.cleanup()
        await relay_runner.cleanup()


@pytest.mark.asyncio
async def test_host_loss_closes_phone_and_rejects_stale_pairing(tmp_path):
    runner, port = await serve(create_relay_app())
    data = load_or_create(tmp_path / "config.json", f"ws://127.0.0.1:{port}")
    host_url = f"ws://127.0.0.1:{port}/relay/host/{room_id(data)}"
    headers = {"X-Hermes-Host-Token": data["host_token"], "X-Hermes-Phone-Token": data["phone_token"]}
    try:
        async with ClientSession() as session:
            host = await session.ws_connect(host_url, headers=headers)
            phone = await session.ws_connect(pairing_url(data))
            opened = await asyncio.wait_for(host.receive(), 2)
            assert json.loads(opened.data)["op"] == "open"
            await host.close()
            closed = await asyncio.wait_for(phone.receive(), 2)
            assert closed.type in (WSMsgType.CLOSE, WSMsgType.CLOSED, WSMsgType.CLOSING)
            with pytest.raises(WSServerHandshakeError) as offline:
                await session.ws_connect(pairing_url(data))
            assert offline.value.status == 503
    finally:
        await runner.cleanup()


@pytest.mark.asyncio
async def test_relay_ignores_non_string_and_malformed_connection_ids(tmp_path):
    runner, port = await serve(create_relay_app())
    data = load_or_create(tmp_path / "config.json", f"ws://127.0.0.1:{port}")
    host_url = f"ws://127.0.0.1:{port}/relay/host/{room_id(data)}"
    headers = {"X-Hermes-Host-Token": data["host_token"], "X-Hermes-Phone-Token": data["phone_token"]}
    try:
        async with ClientSession() as session:
            host = await session.ws_connect(host_url, headers=headers)
            async with host:
                await host.send_json({"op": "data", "id": [], "text": "ignored"})
                await host.send_json({"op": "data", "id": {}, "text": "ignored"})
                await host.send_json({"op": "data", "id": "g" * 32, "text": "ignored"})
                phone = await session.ws_connect(pairing_url(data))
                try:
                    opened = await asyncio.wait_for(host.receive(), 2)
                    assert opened.type == WSMsgType.TEXT
                    assert json.loads(opened.data)["op"] == "open"
                finally:
                    await phone.close()
    finally:
        await runner.cleanup()


@pytest.mark.asyncio
async def test_room_limit_is_enforced_per_source(monkeypatch, tmp_path):
    monkeypatch.setattr(relay_module, "MAX_ROOMS_PER_IP", 1)
    runner, port = await serve(create_relay_app())
    first = load_or_create(tmp_path / "first.json", f"ws://127.0.0.1:{port}")
    second = load_or_create(tmp_path / "second.json", f"ws://127.0.0.1:{port}")
    try:
        async with ClientSession() as session:
            url1 = f"ws://127.0.0.1:{port}/relay/host/{room_id(first)}"
            url2 = f"ws://127.0.0.1:{port}/relay/host/{room_id(second)}"
            host = await session.ws_connect(url1, headers={"X-Hermes-Host-Token": first["host_token"], "X-Hermes-Phone-Token": first["phone_token"]})
            try:
                with pytest.raises(WSServerHandshakeError) as full:
                    await session.ws_connect(url2, headers={"X-Hermes-Host-Token": second["host_token"], "X-Hermes-Phone-Token": second["phone_token"]})
                assert full.value.status == 503
            finally:
                await host.close()
    finally:
        await runner.cleanup()


@pytest.mark.asyncio
async def test_concurrent_host_registration_has_one_owner(tmp_path):
    runner, port = await serve(create_relay_app())
    data = load_or_create(tmp_path / "config.json", f"ws://127.0.0.1:{port}")
    url = f"ws://127.0.0.1:{port}/relay/host/{room_id(data)}"
    headers = {"X-Hermes-Host-Token": data["host_token"], "X-Hermes-Phone-Token": data["phone_token"]}
    try:
        async with ClientSession() as session:
            results = await asyncio.gather(
                session.ws_connect(url, headers=headers),
                session.ws_connect(url, headers=headers),
                return_exceptions=True,
            )
            sockets = [result for result in results if not isinstance(result, Exception)]
            failures = [result for result in results if isinstance(result, WSServerHandshakeError)]
            assert len(sockets) == 1 and len(failures) == 1 and failures[0].status == 409
            await sockets[0].close()
    finally:
        await runner.cleanup()
