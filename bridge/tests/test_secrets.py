"""Gate 10 helper: the tree must not contain live secrets."""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

_SKIP_DIRS = {
    ".git",
    ".venv",
    "venv",
    "__pycache__",
    ".pytest_cache",
    "oh_modules",
    ".idea",
    "node_modules",
}


def test_gitignore_covers_secrets():
    gi = (ROOT / ".gitignore").read_text()
    assert "bridge.toml" in gi
    assert ".secrets/" in gi
    assert ".venv/" in gi


def test_no_checked_in_bridge_toml_or_secrets():
    # Local ignored configuration is required to run the bridge. Check Git's
    # index rather than deleting or rejecting legitimate untracked credentials.
    import subprocess
    result = subprocess.run(['git', 'ls-files', '-z', '--', 'bridge/bridge.toml', '.secrets'],
                            cwd=ROOT, check=True, capture_output=True)
    tracked = [p for p in result.stdout.decode().split('\0') if p and not p.endswith('/.gitkeep')]
    assert not tracked, 'Secret/config files must not be tracked by Git'
