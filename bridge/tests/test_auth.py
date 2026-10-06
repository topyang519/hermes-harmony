"""Auth: app password required; CF Access headers accepted and never logged."""

from __future__ import annotations

import io
import logging

import pytest
from aiohttp import web

from hermes_harmony_bridge.config import BridgeConfig
from hermes_harmony_bridge.server import create_app

from fakes import FakeHermes

PASSWORD = "unit-app-password"


async def _start(tmp_path):
    cfg = BridgeConfig()
    cfg.host = "127.0.0.1"
    cfg.port = 0
    cfg.app_password = PASSWORD
    cfg.state_dir = tmp_path / "state"
    cfg.state_dir.mkdir()
    cfg.ping_interval_seconds = 60
    fake = FakeHermes()
    app = create_app(cfg, hermes=fake)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", 0)
    await site.start()
    port = runner.addresses[0][1]
    return runner, port, fake


@pytest.mark.asyncio
async def test_missing_and_wrong_password_rejected(tmp_path, aiohttp_client=None):
    import aiohttp

    runner, port, _ = await _start(tmp_path)
    url = f"http://127.0.0.1:{port}/v2/app"
    try:
        async with aiohttp.ClientSession() as session:
            resp = await session.get(url)
            assert resp.status == 401
            resp = await session.get(url, headers={"X-Hermes-App-Password": "wrong"})
            assert resp.status == 401
            async with session.ws_connect(url, headers={"X-Hermes-App-Password": PASSWORD}) as ws:
                await ws.send_json({"t": "hello", "app": "0.1.0", "proto": 2, "dev": "auth-test"})
                msg = await ws.receive_json()
                assert msg["t"] == "ready"
                assert msg["hermes"] is True
                assert "epoch" in msg
    finally:
        await runner.cleanup()


@pytest.mark.asyncio
async def test_cf_access_headers_accepted_and_not_logged(tmp_path, caplog):
    import aiohttp

    runner, port, _ = await _start(tmp_path)
    url = f"http://127.0.0.1:{port}/v2/app"
    cf_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.access"
    cf_secret = "cf-unit-secret-value-do-not-leak"
    stream = io.StringIO()
    handler = logging.StreamHandler(stream)
    logging.getLogger("hermes_harmony_bridge.server").addHandler(handler)
    caplog.set_level(logging.INFO)
    try:
        async with aiohttp.ClientSession() as session:
            async with session.ws_connect(
                url,
                headers={
                    "X-Hermes-App-Password": PASSWORD,
                    "CF-Access-Client-Id": cf_id,
                    "CF-Access-Client-Secret": cf_secret,
                },
            ) as ws:
                await ws.send_json({"t": "hello", "app": "0.1.0", "proto": 2, "dev": "cf-test"})
                msg = await ws.receive_json()
                assert msg["t"] == "ready"
        text = stream.getvalue() + caplog.text
        assert "CF Access client id present" in text
        assert cf_secret not in text
        assert PASSWORD not in text
        assert "unit-test-token" not in text
    finally:
        logging.getLogger("hermes_harmony_bridge.server").removeHandler(handler)
        await runner.cleanup()


@pytest.mark.asyncio
async def test_healthz_has_no_token(tmp_path):
    import aiohttp

    runner, port, _ = await _start(tmp_path)
    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(f"http://127.0.0.1:{port}/healthz") as resp:
                body = await resp.json()
        assert body["ok"] is True
        dumped = str(body)
        assert PASSWORD not in dumped
        assert "unit-test-token" not in dumped
    finally:
        await runner.cleanup()
