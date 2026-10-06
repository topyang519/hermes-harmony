"""ASR + TTS against FakeHermes (no live dashboard)."""

from __future__ import annotations

import struct
from pathlib import Path

import pytest
from aiohttp import web

from hermes_harmony_bridge.audio import pcm16_to_wav
from hermes_harmony_bridge.config import BridgeConfig
from hermes_harmony_bridge.server import create_app

from fakes import FakeHermes
from fake_phone import FakePhone

PASSWORD = "unit-app-password-audio"


def _wav(path: Path, seconds: float = 0.2) -> Path:
    n = int(16000 * seconds)
    pcm = b"".join(struct.pack("<h", int(8000 * (i % 20 - 10) / 10)) for i in range(n))
    path.write_bytes(pcm16_to_wav(pcm))
    return path


@pytest.mark.asyncio
async def test_asr_then_tts_bytes_match(tmp_path):
    import aiohttp

    cfg = BridgeConfig()
    cfg.app_password = PASSWORD
    cfg.state_dir = tmp_path / "state"
    cfg.state_dir.mkdir()
    cfg.ping_interval_seconds = 120
    fake = FakeHermes()
    fake.transcript = "voice ping"
    app = create_app(cfg, hermes=fake)
    runner = web.AppRunner(app)
    await runner.setup()
    await web.TCPSite(runner, "127.0.0.1", 0).start()
    port = runner.addresses[0][1]
    wav = _wav(tmp_path / "in.wav")
    try:
        async with aiohttp.ClientSession() as session:
            ws = await session.ws_connect(
                f"ws://127.0.0.1:{port}/v2/app",
                headers={"X-Hermes-App-Password": PASSWORD},
            )
            phone = FakePhone(ws, device_id="voice")
            await phone.hello()
            sid = await phone.new_session()
            await phone.sub(sid, 0)
            transcript = await phone.asr_wav(wav, session=sid)
            assert transcript == ""
            assert fake.transcribe_calls == 1
            assert fake.attaches and fake.attaches[-1]["name"].endswith(".wav")
            assert fake.prompts and "@file:" in fake.prompts[-1][1]
            assert "voice message" in fake.prompts[-1][1]
            assert "private server-side transcript hint" in fake.prompts[-1][1]
            if phone.state.tts_end is None:
                await phone.wait_for(lambda m: m.get("t") == "tts_end", timeout=10)
            assert phone.state.tts_end and phone.state.tts_end.get("aborted") is False
            assert len(phone.state.pcm) == len(fake.speak_pcm)
            assert phone.state.tts_sr == 16000
            pcm, end = await phone.tts("hello from unit")
            assert end.get("aborted") is False
            assert end.get("bytes") == len(pcm)
            assert len(pcm) == len(fake.speak_pcm)
    finally:
        await runner.cleanup()
