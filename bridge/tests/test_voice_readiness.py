"""Configuration authority and rejection at the voice boundary."""
import asyncio
import json

import aiohttp
import pytest
from aiohttp import web

from hermes_harmony_bridge.discovery import HermesEndpoint
from hermes_harmony_bridge.hermes import HermesClient
from hermes_harmony_bridge.server import create_app
from hermes_harmony_bridge.config import BridgeConfig
from fakes import FakeHermes
from fake_phone import FakePhone


@pytest.mark.parametrize('stt,tts,enabled,ffmpeg,old_api,expected', [
    ('ready', 'ready', True, True, False, True),
    ('needs_keys', 'ready', True, True, False, False),
    ('ready', 'needs_setup', True, True, False, False),
    ('ready', 'ready', False, True, False, False),
    ('ready', 'ready', True, False, False, False),
    ('ready', 'ready', True, True, True, False),
])
async def test_only_active_ready_providers_unlock_voice(monkeypatch, stt, tts, enabled, ffmpeg, old_api, expected):
    async def toolsets(request):
        assert request.query.get('profile') == 'phone'
        return web.json_response([{'name': name, 'enabled': enabled} for name in ('stt', 'tts')])

    async def config(request):
        assert request.query.get('profile') == 'phone'
        if old_api:
            raise web.HTTPNotFound()
        status = stt if request.match_info['name'] == 'stt' else tts
        return web.json_response({'providers': [
            {'is_active': True, 'status': status, 'api_key': 'secret-never-forward'},
            {'is_active': False, 'status': 'ready'},
        ]})

    app = web.Application()
    app.router.add_get('/api/tools/toolsets', toolsets)
    app.router.add_get('/api/tools/toolsets/{name}/config', config)
    runner = web.AppRunner(app)
    await runner.setup()
    await web.TCPSite(runner, '127.0.0.1', 0).start()
    monkeypatch.setattr('hermes_harmony_bridge.audio.ffmpeg_available', lambda: ffmpeg)
    monkeypatch.setattr(HermesClient, 'connected', property(lambda self: True))
    try:
        async with aiohttp.ClientSession() as session:
            client = HermesClient(session)
            client.bind(HermesEndpoint(url=f'http://127.0.0.1:{runner.addresses[0][1]}', token='test', tier=2))
            capability = await client.voice_capabilities(profile='phone')
            assert capability['ready'] is expected
            assert 'secret-never-forward' not in json.dumps(capability)
            assert set(capability) == {'ready', 'stt', 'tts', 'ffmpeg', 'reason'}
    finally:
        await runner.cleanup()


async def test_stale_status_cannot_authorize_voice(tmp_path):
    cfg = BridgeConfig(app_password='test-password', state_dir=tmp_path)
    fake = FakeHermes()
    fake.voice_ready = False
    runner = web.AppRunner(create_app(cfg, hermes=fake))
    await runner.setup()
    await web.TCPSite(runner, '127.0.0.1', 0).start()
    try:
        async with aiohttp.ClientSession() as session:
            ws = await session.ws_connect(f'http://127.0.0.1:{runner.addresses[0][1]}/v2/app',
                                          headers={'X-Hermes-App-Password': 'test-password'})
            phone = FakePhone(ws)
            ready = await phone.hello()
            assert 'voice_readiness_v1' in ready['features']
            status = await phone.wait_for(lambda msg: msg.get('t') == 'voice_capabilities')
            assert status['voice']['ready'] is False
            for kind in ('asr_start', 'tts'):
                await phone.send(t=kind, sr=16000, text='must not play')
                error = await phone.wait_for(lambda msg: msg.get('t') == 'error')
                assert error['code'] == 'voice_unavailable'
            await phone.send_bin(b'\x00\x01' * 1000)
            assert not fake.attaches and not fake.prompts
            fake.voice_ready = True
            await phone.send(t='voice_check', request_id='phone-recheck-17')
            status = await phone.wait_for(lambda msg: msg.get('t') == 'voice_capabilities'
                                          and msg.get('request_id') == 'phone-recheck-17')
            assert status['voice']['ready'] is True
            fake.voice_ready = False
            await phone.send(t='asr_start', sr=16000)
            error = await phone.wait_for(lambda msg: msg.get('t') == 'error')
            assert error['code'] == 'voice_unavailable'
            await ws.close()
    finally:
        await runner.cleanup()


async def test_voice_check_never_delays_text_handshake(tmp_path):
    cfg = BridgeConfig(app_password='test-password', state_dir=tmp_path)
    fake = FakeHermes()
    release = asyncio.Event()
    original = fake.voice_capabilities

    async def slow_check(*, profile=None):
        await release.wait()
        return await original(profile=profile)

    fake.voice_capabilities = slow_check
    runner = web.AppRunner(create_app(cfg, hermes=fake))
    await runner.setup()
    await web.TCPSite(runner, '127.0.0.1', 0).start()
    try:
        async with aiohttp.ClientSession() as session:
            ws = await session.ws_connect(f'http://127.0.0.1:{runner.addresses[0][1]}/v2/app',
                                          headers={'X-Hermes-App-Password': 'test-password'})
            phone = FakePhone(ws)
            await asyncio.wait_for(phone.hello(), timeout=1)
            await asyncio.wait_for(phone.new_session(), timeout=1)
            release.set()
            await phone.wait_for(lambda msg: msg.get('t') == 'voice_capabilities')
            await ws.close()
    finally:
        release.set()
        await runner.cleanup()
