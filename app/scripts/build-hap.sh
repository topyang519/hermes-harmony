#!/usr/bin/env bash
# Assemble entry-default HAP when ohpm + hvigorw + HarmonyOS SDK are installed.
# This script never fabricates a .hap; missing tools exit with a clear message.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BUILD_MODE="${BUILD_MODE:-debug}"
case "$BUILD_MODE" in
  debug|release) ;;
  *) echo "BUILD_MODE must be 'debug' or 'release' (got: ${BUILD_MODE})" >&2; exit 2 ;;
esac

if [[ ! -f "${ROOT}/build-profile.json5" ]]; then
  cp "${ROOT}/build-profile.json5.example" "${ROOT}/build-profile.json5"
  echo "Created a local unsigned build profile; configure signing in DevEco to install on a device." >&2
fi

# DevEco may write a local signingConfigs block without linking it to the
# default product (notably when this checkout was opened from the CLI). Bind
# that existing local profile so the documented CLI build produces a signed
# device-installable HAP. Never create or print signing material here.
python3 - "${ROOT}/build-profile.json5" <<'PY'
from pathlib import Path
import re
import sys

profile = Path(sys.argv[1])
source = profile.read_text()
parts = source.split('signingConfigs', 1)
if len(parts) == 2 and not re.search(r'\bsigningConfig\s*:', parts[0]):
    updated, count = re.subn(
        r"(name\s*:\s*(['\"])default\2\s*,)",
        r"\1\n        signingConfig: 'default',",
        parts[0],
        count=1,
    )
    if count:
        profile.write_text(updated + 'signingConfigs' + parts[1])
        print('Bound the existing local signing profile to product default.')
PY

# DevEco Studio's bundled hvigor can inherit an invalid SDK location when the
# standalone CLT is installed alongside it. Prefer the configured CLT SDK.
if [[ -n "${DEVECO_CLI_CLT_PATH:-}" && -d "${DEVECO_CLI_CLT_PATH}/sdk" ]]; then
  export DEVECO_SDK_HOME="${DEVECO_CLI_CLT_PATH}/sdk"
elif [[ -z "${DEVECO_SDK_HOME:-}" && -d "${HOME}/Library/Huawei/command-line-tools/sdk" ]]; then
  export DEVECO_SDK_HOME="${HOME}/Library/Huawei/command-line-tools/sdk"
fi

CANDIDATE_OHPM=(
  "${OHPM:-}"
  "$(command -v ohpm 2>/dev/null || true)"
  "${HOME}/command-line-tools/ohpm/bin/ohpm"
  "${HOME}/Library/Huawei/command-line-tools/bin/ohpm"
  "/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin/ohpm"
  "${HOME}/Library/Huawei/DevEcoStudio/tools/ohpm/bin/ohpm"
)

CANDIDATE_HVIGORW=(
  "${HVIGORW:-}"
  "$(command -v hvigorw 2>/dev/null || true)"
  "${ROOT}/hvigorw"
  "${HOME}/command-line-tools/hvigor/bin/hvigorw"
  "${HOME}/Library/Huawei/command-line-tools/bin/hvigorw"
  "/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw"
  "${HOME}/Library/Huawei/DevEcoStudio/tools/hvigor/bin/hvigorw"
)

if [[ -n "${DEVECO_CLI_CLT_PATH:-}" ]]; then
  CANDIDATE_OHPM+=("${DEVECO_CLI_CLT_PATH}/bin/ohpm" "${DEVECO_CLI_CLT_PATH}/ohpm/bin/ohpm")
  CANDIDATE_HVIGORW+=("${DEVECO_CLI_CLT_PATH}/bin/hvigorw" "${DEVECO_CLI_CLT_PATH}/hvigor/bin/hvigorw")
fi

first_exec() {
  local p
  for p in "$@"; do
    if [[ -n "${p}" && -x "${p}" ]]; then
      echo "${p}"
      return 0
    fi
  done
  return 1
}

OHPM_BIN="$(first_exec "${CANDIDATE_OHPM[@]}")" || true
HVIGORW_BIN="$(first_exec "${CANDIDATE_HVIGORW[@]}")" || true

if [[ -z "${OHPM_BIN}" || -z "${HVIGORW_BIN}" ]]; then
  cat <<'EOF'
HAP was not built: DevEco / HarmonyOS SDK tools are not on this machine.

Need executable:
  ohpm
  hvigorw

Typical locations after installing DevEco Studio on macOS:
  /Applications/DevEco-Studio.app/Contents/tools/ohpm/bin/ohpm
  /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw
  ~/command-line-tools/ohpm/bin/ohpm
  ~/command-line-tools/hvigor/bin/hvigorw

Then:
  1. Open this checkout's app directory in DevEco Studio
  2. Let it write local.properties (see local.properties.example)
  3. Accept a debug signing certificate for bundle ai.hermes.harmes
  4. Re-run for a debug build: app/scripts/build-hap.sh
     For a release build: BUILD_MODE=release app/scripts/build-hap.sh

Expected artifacts (created by hvigor, never checked in):
  entry/build/default/outputs/default/entry-default-signed.hap
  entry/build/default/outputs/default/entry-default-unsigned.hap

Install on your HarmonyOS device (USB debugging enabled):
  hdc list targets
  hdc install entry/build/default/outputs/default/entry-default-signed.hap
EOF
  exit 2
fi

if [[ ! -f "${ROOT}/local.properties" ]]; then
  echo "warning: local.properties is missing. Copy local.properties.example and set sdk.dir" >&2
fi

echo "ohpm:    ${OHPM_BIN}"
echo "hvigorw: ${HVIGORW_BIN}"
"${OHPM_BIN}" install
"${HVIGORW_BIN}" assembleHap --mode module -p buildMode="${BUILD_MODE}" -p product=default -p module=entry@default --no-daemon

SIGNED="${ROOT}/entry/build/default/outputs/default/entry-default-signed.hap"
UNSIGNED="${ROOT}/entry/build/default/outputs/default/entry-default-unsigned.hap"
if [[ -f "${SIGNED}" ]]; then
  echo "HAP: ${SIGNED}"
elif [[ -f "${UNSIGNED}" ]]; then
  echo "HAP (unsigned): ${UNSIGNED}"
  echo "Sign in DevEco with your own signing profile before installing on your device."
else
  echo "hvigorw finished but no .hap was found under entry/build/default/outputs/default/" >&2
  exit 1
fi
