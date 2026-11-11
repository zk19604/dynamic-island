#!/usr/bin/env bash
# Builds dynamic-island.app and installs it into ~/Applications, then launches it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/Applications"
APP_NAME="dynamic-island.app"

"$ROOT/scripts/build_app.sh"

mkdir -p "$DEST"
# Quit a running copy so the bundle can be replaced (also the pre-rename IslandClip).
osascript -e 'tell application id "com.zk19604.dynamic-island" to quit' >/dev/null 2>&1 || true
osascript -e 'tell application id "com.example.islandclip" to quit' >/dev/null 2>&1 || true
sleep 0.5
rm -rf "$DEST/IslandClip.app" # old name
rm -rf "$DEST/$APP_NAME"
cp -R "$ROOT/build/$APP_NAME" "$DEST/$APP_NAME"
echo "==> Installed to $DEST/$APP_NAME"

open "$DEST/$APP_NAME"
echo "==> Launched. Look for the island at the top-center of your screen and the capsule icon in the menu bar."
