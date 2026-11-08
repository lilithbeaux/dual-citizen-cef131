#!/usr/bin/env bash
# build-dual-citizen.sh — clean build of all three Dual Citizen binaries.
# Requires: lazbuild (Lazarus 4.4), FPC 3.2.2, CEF4Delphi source at $CEF4DELPHI,
#           CEF 131 runtime at $CEFRUNTIME.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.."
CEFRUNTIME="${CEFRUNTIME:-/home/lilareyon/cef-runtime/Release}"
CEF4DELPHI="${CEF4DELPHI:-/home/lilareyon/CEF4Delphi}"

echo "==> CEF runtime : $CEFRUNTIME"
echo "==> CEF4Delphi  : $CEF4DELPHI"
echo "==> Build dir   : $BUILD_DIR"

if [ ! -d "$CEFRUNTIME" ]; then
  echo "ERROR: CEF runtime not found at $CEFRUNTIME" >&2
  exit 1
fi
if [ ! -d "$CEF4DELPHI" ]; then
  echo "ERROR: CEF4Delphi source not found at $CEF4DELPHI" >&2
  exit 1
fi

cd "$BUILD_DIR"

# 1. Asset embedding (regenerates uAssetsEmbedded*.pas from assets/)
echo "==> Embedding assets"
python3 scripts/assets_embed.py
python3 scripts/assets_embed_facebook.py

# 2. Build all three targets
for proj in dual_citizen_v2 dual_citizen_reddit dual_citizen_facebook; do
  echo "==> Building $proj"
  lazbuild -B "$proj.lpi"
done

echo "==> Build complete"
ls -lh dual_citizen_v2 dual_citizen_reddit dual_citizen_facebook