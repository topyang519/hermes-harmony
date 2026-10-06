"""PCM16 WAV framing for HarmonyOS uplink. No mu-law, no IMA-ADPCM."""

from __future__ import annotations

import asyncio
import os
import shutil
import struct
import tempfile
from pathlib import Path
from typing import Iterable

PCM_FORMAT_TAG = 0x0001
DEFAULT_SR = 16000


def ffmpeg_available() -> bool:
    return bool(shutil.which("ffmpeg") or any(
        Path(path).is_file() and os.access(path, os.X_OK) for path in ("/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg")
    ))


class WavError(ValueError):
    pass


def pcm16_to_wav(pcm: bytes, sample_rate: int = DEFAULT_SR, channels: int = 1) -> bytes:
    if channels < 1:
        raise WavError("channels must be >= 1")
    byte_rate = sample_rate * channels * 2
    data_size = len(pcm)
    header = struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF",
        36 + data_size,
        b"WAVE",
        b"fmt ",
        16,
        PCM_FORMAT_TAG,
        channels,
        sample_rate,
        byte_rate,
        channels * 2,
        16,
        b"data",
        data_size,
    )
    return header + pcm


def wav_header_for_pcm(data_size: int, sample_rate: int = DEFAULT_SR, channels: int = 1) -> bytes:
    return pcm16_to_wav(b"\x00" * data_size, sample_rate, channels)[:44]


def patch_wav_sizes(buf: bytearray, data_size: int) -> None:
    if len(buf) < 44:
        raise WavError("WAV too short to patch")
    struct.pack_into("<I", buf, 4, 36 + data_size)
    struct.pack_into("<I", buf, 40, data_size)


def parse_wav(blob: bytes) -> dict:
    if len(blob) < 12 or blob[0:4] != b"RIFF" or blob[8:12] != b"WAVE":
        raise WavError("not a RIFF WAVE file")
    pos = 12
    fmt: dict | None = None
    data = b""
    while pos + 8 <= len(blob):
        chunk_id = blob[pos : pos + 4]
        chunk_size = struct.unpack_from("<I", blob, pos + 4)[0]
        pos += 8
        payload = blob[pos : pos + chunk_size]
        pos += chunk_size + (chunk_size % 2)
        if chunk_id == b"fmt ":
            if len(payload) < 16:
                raise WavError("fmt chunk too short")
            audio_format, channels, sample_rate, byte_rate, block_align, bits = struct.unpack_from(
                "<HHIIHH", payload, 0
            )
            fmt = {
                "audio_format": audio_format,
                "channels": channels,
                "sample_rate": sample_rate,
                "byte_rate": byte_rate,
                "block_align": block_align,
                "bits_per_sample": bits,
            }
        elif chunk_id == b"data":
            data = payload
    if fmt is None:
        raise WavError("missing fmt chunk")
    return {**fmt, "data": data}


class PcmAccumulator:
    """In-memory PCM16LE capture for one ASR utterance."""

    def __init__(self, sample_rate: int = DEFAULT_SR):
        self.sample_rate = sample_rate
        self._buf = bytearray()

    def write(self, pcm: bytes) -> None:
        if pcm:
            self._buf.extend(pcm)

    @property
    def data_size(self) -> int:
        return len(self._buf)

    def duration_seconds(self) -> float:
        if self.sample_rate <= 0:
            return 0.0
        return self.data_size / (2.0 * self.sample_rate)

    def to_wav(self) -> bytes:
        return pcm16_to_wav(bytes(self._buf), sample_rate=self.sample_rate)


def make_temp_wav(prefix: str = "harmony-asr-") -> Path:
    fh = tempfile.NamedTemporaryFile(prefix=prefix, suffix=".wav", delete=False)
    path = Path(fh.name)
    fh.close()
    return path


async def ffmpeg_to_pcm_wav(
    src: bytes,
    *,
    ffmpeg_bin: str = "ffmpeg",
    timeout: float = 30.0,
    sample_rate: int = DEFAULT_SR,
) -> bytes:
    """Decode an arbitrary audio blob (ogg/mp3/wav) to mono PCM16 WAV.

    Used only for the POST /api/audio/speak fallback when speak-stream is unavailable.
    """
    resolved_ffmpeg = shutil.which(ffmpeg_bin)
    if resolved_ffmpeg is None and ffmpeg_bin == "ffmpeg":
        # LaunchAgents inherit a minimal PATH on macOS. Homebrew's ffmpeg is
        # present on the bridge host but is otherwise invisible to the daemon.
        for candidate in ("/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"):
            if Path(candidate).is_file():
                resolved_ffmpeg = candidate
                break
    executable = resolved_ffmpeg or ffmpeg_bin
    cmd = [
        executable, "-hide_banner", "-loglevel", "error", "-i", "pipe:0",
        "-ac", "1", "-ar", str(sample_rate), "-c:a", "pcm_s16le", "-f", "wav", "pipe:1",
    ]
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
    except FileNotFoundError as exc:
        raise RuntimeError("ffmpeg not found") from exc
    try:
        stdout, stderr = await asyncio.wait_for(proc.communicate(src), timeout=timeout)
    except asyncio.CancelledError:
        if proc.returncode is None:
            proc.kill()
        await proc.wait()
        raise
    except TimeoutError as exc:
        proc.kill()
        await proc.wait()
        raise RuntimeError("ffmpeg timed out") from exc
    if proc.returncode != 0:
        raise RuntimeError(f"ffmpeg failed ({proc.returncode}): {stderr.decode('utf-8', 'replace')[-400:]}")
    return stdout


def chunk_bytes(data: bytes, size: int) -> list[bytes]:
    if size <= 0:
        return [data] if data else []
    return [data[i : i + size] for i in range(0, len(data), size)]


def iter_pcm_frames(pcm: bytes, frame_bytes: int = 1280) -> Iterable[bytes]:
    for i in range(0, len(pcm), frame_bytes):
        chunk = pcm[i : i + frame_bytes]
        if chunk:
            yield chunk
