from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover
    import tomli as tomllib  # type: ignore


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


@dataclass
class HermesSettings:
    url: str | None = None
    token: str | None = None
    profile: str | None = None
    source: str = "harmony"
    cwd: str | None = None
    allow_spawn: bool = False
    spawn_port: int = 9121
    hermes_bin: str | None = None


@dataclass
class BridgeConfig:
    host: str = "127.0.0.1"
    port: int = 7691
    app_password: str = ""
    max_devices: int = 4
    turns_per_minute: int = 10
    max_recording_seconds: int = 120
    ping_interval_seconds: float = 20.0
    # No-progress timeout for a phone turn. Hermes events renew this deadline.
    phone_turn_timeout_seconds: float = 600.0
    phone_turn_max_seconds: float = 3600.0
    state_dir: Path = field(default_factory=lambda: _repo_root() / "bridge" / "state")
    hermes: HermesSettings = field(default_factory=HermesSettings)

    @property
    def workspace_dir(self) -> Path:
        if self.hermes.cwd:
            return Path(self.hermes.cwd).expanduser()
        return self.state_dir / "workspace"


def _opt_str(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def load_config(path: str | Path | None = None) -> BridgeConfig:
    cfg = BridgeConfig()
    chosen = Path(path) if path else None
    if chosen is None:
        env = os.environ.get("HERMES_HARMONY_BRIDGE_CONFIG") or os.environ.get("HERMES_BRIDGE_CONFIG")
        chosen = Path(env) if env else None
        if chosen is None:
            candidate = Path.cwd() / "bridge.toml"
            chosen = candidate if candidate.is_file() else _repo_root() / "bridge" / "bridge.toml"
    raw = tomllib.loads(chosen.read_text(encoding="utf-8")) if chosen.is_file() else {}
    bridge = raw.get("bridge") or {}
    hermes = raw.get("hermes") or {}
    cfg.host = str(bridge.get("host", cfg.host))
    cfg.port = int(bridge.get("port", cfg.port))
    # app_token remains a one-release config migration fallback only.
    cfg.app_password = str(bridge.get("app_password", bridge.get("app_token", cfg.app_password)))
    cfg.max_devices = int(bridge.get("max_devices", cfg.max_devices))
    cfg.turns_per_minute = int(bridge.get("turns_per_minute", cfg.turns_per_minute))
    cfg.max_recording_seconds = int(bridge.get("max_recording_seconds", cfg.max_recording_seconds))
    cfg.ping_interval_seconds = float(bridge.get("ping_interval_seconds", cfg.ping_interval_seconds))
    cfg.phone_turn_timeout_seconds = float(
        bridge.get("phone_turn_timeout_seconds", cfg.phone_turn_timeout_seconds)
    )
    cfg.phone_turn_max_seconds = float(
        bridge.get("phone_turn_max_seconds", cfg.phone_turn_max_seconds)
    )
    if bridge.get("state_dir"):
        cfg.state_dir = Path(str(bridge["state_dir"])).expanduser()
    cfg.hermes.url = _opt_str(hermes.get("url"))
    cfg.hermes.token = _opt_str(hermes.get("token"))
    cfg.hermes.profile = _opt_str(hermes.get("profile"))
    cfg.hermes.source = str(hermes.get("source", cfg.hermes.source) or "harmony")
    cfg.hermes.cwd = _opt_str(hermes.get("cwd"))
    cfg.hermes.allow_spawn = bool(hermes.get("allow_spawn", False))
    cfg.hermes.spawn_port = int(hermes.get("spawn_port", cfg.hermes.spawn_port))
    cfg.hermes.hermes_bin = _opt_str(hermes.get("hermes_bin"))
    return cfg
