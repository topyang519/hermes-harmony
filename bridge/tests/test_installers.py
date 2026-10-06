from __future__ import annotations

import os
import hashlib
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SHELL_INSTALLER = ROOT / "deploy" / "install-connector.sh"


def _run_installer(home: Path, *args: str, extra_path: Path | None = None) -> subprocess.CompletedProcess[str]:
    env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / ".config"))
    if extra_path is not None:
        env["PATH"] = f"{extra_path}{os.pathsep}{env['PATH']}"
    return subprocess.run(
        ["sh", str(SHELL_INSTALLER), *args],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )


def test_release_installer_requires_relay_on_first_install(tmp_path: Path) -> None:
    result = _run_installer(tmp_path)

    assert result.returncode == 2
    assert "First install requires --relay" in result.stderr


def test_release_installer_checksums_wheel_and_accepts_custom_config(tmp_path: Path) -> None:
    config = tmp_path / "custom.json"
    config.write_text("{}", encoding="utf-8")
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    fake_curl = fake_bin / "curl"
    fake_curl.write_text(
        "#!/usr/bin/env python3\n"
        "import pathlib, sys\n"
        "out = pathlib.Path(sys.argv[sys.argv.index('-o') + 1])\n"
        "if out.name == 'SHA256SUMS':\n"
        "    out.write_text('0' * 64 + '  hermes_harmony_bridge-0.3.8-py3-none-any.whl\\n')\n"
        "else:\n"
        "    out.write_bytes(b'wheel bytes')\n",
        encoding="utf-8",
    )
    fake_curl.chmod(0o755)

    result = _run_installer(tmp_path, "--config", str(config), extra_path=fake_bin)

    assert result.returncode == 1
    assert "checksum verification failed" in result.stderr


def test_release_installer_accepts_checksum_and_forwards_config_and_relay(tmp_path: Path) -> None:
    config = tmp_path / "custom.json"
    config.write_text("{}", encoding="utf-8")
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    wheel = b"verified wheel bytes"
    checksum = hashlib.sha256(wheel).hexdigest()
    (fake_bin / "curl").write_text(
        f"#!{sys.executable}\n"
        "import pathlib, sys\n"
        "out = pathlib.Path(sys.argv[sys.argv.index('-o') + 1])\n"
        "if out.name == 'SHA256SUMS':\n"
        f"    out.write_text('{checksum}  hermes_harmony_bridge-0.3.8-py3-none-any.whl\\n')\n"
        "else:\n"
        f"    out.write_bytes({wheel!r})\n",
        encoding="utf-8",
    )
    (fake_bin / "curl").chmod(0o755)
    python = fake_bin / "python3"
    python.write_text(
        "#!/bin/sh\n"
        "if [ \"$1\" = -c ]; then exit 0; fi\n"
        "if [ \"$1\" = -m ] && [ \"$2\" = venv ]; then\n"
        "  mkdir -p \"$3/bin\"\n"
        "  cat > \"$3/bin/python\" <<'MOCK'\n#!/bin/sh\nexit 0\nMOCK\n"
        "  cat > \"$3/bin/hermes-harmony-connect\" <<'MOCK'\n"
        "#!/bin/sh\nprintf '%s\\n' \"$@\" >> \"$CLI_LOG\"\nexit 0\nMOCK\n"
        "  chmod +x \"$3/bin/python\" \"$3/bin/hermes-harmony-connect\"\n"
        "  exit 0\nfi\n"
        "exit 1\n",
        encoding="utf-8",
    )
    python.chmod(0o755)
    log = tmp_path / "connector-args.txt"
    env = dict(
        os.environ,
        HOME=str(tmp_path),
        XDG_CONFIG_HOME=str(tmp_path / ".config"),
        XDG_DATA_HOME=str(tmp_path / "data"),
        CLI_LOG=str(log),
        PATH=f"{fake_bin}{os.pathsep}{os.environ['PATH']}",
    )

    result = subprocess.run(
        ["sh", str(SHELL_INSTALLER), "--config", str(config), "--relay", "wss://relay.example.test"],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    calls = log.read_text(encoding="utf-8")
    assert "setup\n--config\n" + str(config) in calls
    assert "--relay\nwss://relay.example.test" in calls
    assert "install-service\n--config\n" + str(config) in calls
    assert "checksum verification failed" not in result.stderr


def test_connector_installers_use_github_and_no_personal_relay() -> None:
    scripts = [
        SHELL_INSTALLER,
        ROOT / "deploy" / "install-connector.ps1",
        ROOT / "bridge" / "install.sh",
        ROOT / "app" / "entry" / "src" / "main" / "ets" / "pages" / "SetupPage.ets",
    ]
    for path in scripts:
        source = path.read_text(encoding="utf-8")
        assert "sslip.io" not in source
        if path.name in {"install-connector.sh", "install.sh"}:
            assert "RELAY_URL=" not in source
    assert "github.com/topyang519/hermes-harmony" in SHELL_INSTALLER.read_text(encoding="utf-8")
    setup_page = (ROOT / "app" / "entry" / "src" / "main" / "ets" / "pages" / "SetupPage.ets").read_text(encoding="utf-8")
    release_workflow = (ROOT / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8")
    assert "releases/latest/download/install.ps1" in setup_page
    assert "releases/latest/download/install-connector.ps1" not in setup_page
    assert 'cp deploy/install-connector.ps1 "$OUT/install.ps1"' in release_workflow
