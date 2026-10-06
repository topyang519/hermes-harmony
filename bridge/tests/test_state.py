from __future__ import annotations

import json
import os
import stat

import pytest

from hermes_harmony_bridge.state import DeviceStore


def test_state_directory_and_file_are_owner_only(tmp_path):
    state_dir = tmp_path / "state"
    state_dir.mkdir(mode=0o755)
    path = state_dir / "devices.json"
    path.write_text(json.dumps({"devices": {"phone": {"device_id": "phone-1"}}}))
    if os.name != "nt":
        state_dir.chmod(0o755)
        path.chmod(0o644)

    store = DeviceStore(path)

    if os.name != "nt":
        assert stat.S_IMODE(state_dir.stat().st_mode) == 0o700
        assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert store.get("phone").device_id == "phone-1"

    store.save()
    if os.name != "nt":
        assert stat.S_IMODE(path.stat().st_mode) == 0o600


def test_invalid_persisted_cursors_do_not_abort_state_load(tmp_path):
    path = tmp_path / "state" / "devices.json"
    path.parent.mkdir()
    path.write_text(json.dumps({"devices": {"phone": {
        "cursors": {"valid": 12, "invalid": "not-a-number", "infinite": 1e1000, "boolean": True}
    }}}))

    store = DeviceStore(path)

    assert store.get("phone").cursors == {"valid": 12}


def test_windows_state_permission_helper_skips_posix_chmod(tmp_path, monkeypatch):
    path = tmp_path / "state" / "devices.json"
    path.parent.mkdir()
    path.write_text(json.dumps({"devices": {}}))
    store = DeviceStore(path)
    chmod_calls = []
    monkeypatch.setattr("hermes_harmony_bridge.state.os.chmod", lambda *args: chmod_calls.append(args))
    store._secure_storage_permissions(platform="nt")

    assert chmod_calls == []


def test_device_store_rejects_symlink_state_file(tmp_path):
    target = tmp_path / "outside.json"
    target.write_text(json.dumps({"devices": {}}))
    state_dir = tmp_path / "state"
    state_dir.mkdir()
    link = state_dir / "devices.json"
    try:
        link.symlink_to(target)
    except (NotImplementedError, OSError) as exc:
        pytest.skip(f"symlink creation is unavailable: {type(exc).__name__}")

    with pytest.raises(OSError, match="regular file"):
        DeviceStore(link)
