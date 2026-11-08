#!/usr/bin/env bash
# run-dual-citizen.sh — launch a Dual Citizen browser with the required clean env.
# Usage: run-dual-citizen.sh <binary> [url]
set -euo pipefail

BIN="${1:-dual_citizen_v2}"
URL="${2:-about:blank}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.."

export DISPLAY="${DISPLAY:-:0}"
export HOME="${HOME:-/home/lilareyon}"
export NO_AT_BRIDGE=1
export GTK_A11Y=none
export GTK_MODULES=
export GDK_DEBUG=nograbs
export GSETTINGS_BACKEND=memory
export PATH=/usr/bin:/bin
export DC_CMD_SOCKET="${DC_CMD_SOCKET:-/tmp/aethelgard_cef.sock}"
export DC_BUS_SOCKET="${DC_BUS_SOCKET:-/tmp/aethelgard_bus.sock}"

echo "==> Launching $BIN -> $URL"
echo "    cmd socket: $DC_CMD_SOCKET"
echo "    bus socket: $DC_BUS_SOCKET"
exec "$BUILD_DIR/$BIN" "$URL"