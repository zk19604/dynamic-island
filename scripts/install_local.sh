#!/usr/bin/env bash
# Builds IslandClip.app and installs it into ~/Applications, then launches it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/Applications"

"$ROOT/scripts/build_app.sh"

mkdir -p "$DEST"
# Quit a running copy so the bundle can be replaced.
osascript -e 'tell application id "com.example.islandclip" to quit' >/dev/null 2>&1 || true
sleep 0.5
rm -rf "$DEST/IslandClip.app"
cp -R "$ROOT/build/IslandClip.app" "$DEST/IslandClip.app"
echo "==> Installed to $DEST/IslandClip.app"

open "$DEST/IslandClip.app"
echo "==> Launched. Look for the island at the top-center of your screen and the capsule icon in the menu bar."
