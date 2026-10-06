#!/bin/sh
set -eu

# Connector release assets are published on GitHub. Keep this version aligned
# with bridge/pyproject.toml and SHA256SUMS in the v0.6.8 release.
RELEASE_TAG=v0.6.8
RELEASE_URL="https://github.com/topyang519/hermes-harmony/releases/download/$RELEASE_TAG"
WHEEL=hermes_harmony_bridge-0.3.8-py3-none-any.whl
INSTALL_DIR=${XDG_DATA_HOME:-"$HOME/.local/share"}/hermes-harmony
CONFIG_FILE=${XDG_CONFIG_HOME:-"$HOME/.config"}/hermes-harmony/connection.json
HAS_RELAY=0

NEED_CONFIG=0
for ARG do
    if [ "$NEED_CONFIG" -eq 1 ]; then
        CONFIG_FILE=$ARG
        NEED_CONFIG=0
        continue
    fi
    case "$ARG" in
        --relay) HAS_RELAY=1 ;;
        --relay=*) HAS_RELAY=1 ;;
        --config) NEED_CONFIG=1 ;;
        --config=*) CONFIG_FILE=${ARG#--config=} ;;
    esac
done
[ "$NEED_CONFIG" -eq 0 ] || { echo "--config requires a path" >&2; exit 2; }
# Preserve all original arguments so --config and --relay reach every command.
if [ "$HAS_RELAY" -eq 0 ] && [ ! -f "$CONFIG_FILE" ]; then
    echo "First install requires --relay wss://your-deployed-relay.example" >&2
    exit 2
fi

python3 -c 'import sys; assert sys.version_info >= (3, 11), "Python 3.11+ required"'
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
if command -v sha256sum >/dev/null 2>&1; then
    hash_file() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
    hash_file() { shasum -a 256 "$1" | awk '{print $1}'; }
else
    echo "sha256sum or shasum is required to verify the connector download" >&2
    exit 1
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM
curl --fail --location --silent --show-error "$RELEASE_URL/SHA256SUMS" -o "$TMP_DIR/SHA256SUMS"
curl --fail --location --silent --show-error "$RELEASE_URL/$WHEEL" -o "$TMP_DIR/$WHEEL"
EXPECTED=$(awk -v name="$WHEEL" '$2 == name || $2 == "*" name {print $1; exit}' "$TMP_DIR/SHA256SUMS")
ACTUAL=$(hash_file "$TMP_DIR/$WHEEL")
if [ -z "$EXPECTED" ] || [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "Connector wheel checksum verification failed" >&2
    exit 1
fi

mkdir -p "$INSTALL_DIR"
python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/python" -m pip install --quiet --upgrade "$TMP_DIR/$WHEEL"
"$INSTALL_DIR/venv/bin/hermes-harmony-connect" setup --config "$CONFIG_FILE" "$@"
if "$INSTALL_DIR/venv/bin/hermes-harmony-connect" install-service --config "$CONFIG_FILE" "$@"; then
    echo "The connector will start automatically when you log in."
else
    echo "Automatic startup is unavailable here; keeping the connector in this terminal."
    exec "$INSTALL_DIR/venv/bin/hermes-harmony-connect" run --config "$CONFIG_FILE" "$@"
fi
