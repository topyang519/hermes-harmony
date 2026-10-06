#!/bin/sh
set -eu

# One command from an unpacked release or cloned repository:
# ./bridge/install.sh --relay wss://relay.example.com
BRIDGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
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
        --relay|--relay=*) HAS_RELAY=1 ;;
        --config) NEED_CONFIG=1 ;;
        --config=*) CONFIG_FILE=${ARG#--config=} ;;
    esac
done
[ "$NEED_CONFIG" -eq 0 ] || { echo "--config requires a path" >&2; exit 2; }
if [ "$HAS_RELAY" -eq 0 ] && [ ! -f "$CONFIG_FILE" ]; then
    echo "First install requires --relay wss://your-deployed-relay.example" >&2
    exit 2
fi
python3 -c 'import sys; assert sys.version_info >= (3, 11), "Python 3.11+ required"'
mkdir -p "$INSTALL_DIR"
python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/python" -m pip install --quiet --upgrade "$BRIDGE_DIR"
"$INSTALL_DIR/venv/bin/hermes-harmony-connect" setup --config "$CONFIG_FILE" "$@"
if "$INSTALL_DIR/venv/bin/hermes-harmony-connect" install-service --config "$CONFIG_FILE" "$@"; then
    echo "The connector will start automatically when you log in."
else
    echo "Automatic startup is unavailable here; keeping the connector in this terminal."
    exec "$INSTALL_DIR/venv/bin/hermes-harmony-connect" run --config "$CONFIG_FILE" "$@"
fi
