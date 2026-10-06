from __future__ import annotations

import struct

from hermes_harmony_bridge.audio import PcmAccumulator, chunk_bytes, parse_wav, pcm16_to_wav
from hermes_harmony_bridge.config import BridgeConfig, load_config


def _pcm(n: int = 160) -> bytes:
    return b"\x00\x10" * n


def test_wav_roundtrip():
    pcm = _pcm(200)
    blob = pcm16_to_wav(pcm, sample_rate=16000)
    parsed = parse_wav(blob)
    assert parsed["audio_format"] == 1
    assert parsed["channels"] == 1
    assert parsed["sample_rate"] == 16000
    assert parsed["bits_per_sample"] == 16
    assert parsed["data"] == pcm


def test_accumulator_to_wav():
    acc = PcmAccumulator(16000)
    acc.write(_pcm(40))
    acc.write(_pcm(40))
    assert acc.data_size == 160
    parsed = parse_wav(acc.to_wav())
    assert len(parsed["data"]) == 160


def test_chunk_bytes():
    assert chunk_bytes(b"abcdef", 2) == [b"ab", b"cd", b"ef"]
    assert chunk_bytes(b"", 4) == []


def test_default_port_is_7691_not_7690():
    cfg = BridgeConfig()
    assert cfg.port == 7691
    loaded = load_config("/nonexistent/bridge.toml")
    assert loaded.port == 7691
    assert loaded.hermes.source == "harmony"


def test_pcm16_header_sizes():
    pcm = struct.pack("<hhh", 1, -2, 3)
    blob = pcm16_to_wav(pcm)
    assert blob[0:4] == b"RIFF"
    assert blob[8:12] == b"WAVE"
    riff_size = struct.unpack_from("<I", blob, 4)[0]
    data_size = struct.unpack_from("<I", blob, 40)[0]
    assert data_size == 6
    assert riff_size == 36 + 6
