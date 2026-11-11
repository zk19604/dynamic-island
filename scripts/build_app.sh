#!/usr/bin/env bash
# Builds IslandClip.app from source and ad-hoc signs it.
#
#   scripts/build_app.sh                 # native arch, output in ./build
#   UNIVERSAL=1 scripts/build_app.sh     # arm64 + x86_64 (needs full Xcode)
#
# Environment:
#   OUTPUT_DIR         where IslandClip.app goes (default: ./build)
#   SWIFT_BUILD_FLAGS  extra flags for `swift build` (Homebrew passes --disable-sandbox)
#
# Ad-hoc signing ("codesign --sign -") needs no Apple account or certificate.
# Apple Silicon refuses to run unsigned arm64 code, so this step is required.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/build}"
APP="$OUTPUT_DIR/IslandClip.app"
# shellcheck disable=SC2206
FLAGS=(-c release ${SWIFT_BUILD_FLAGS:-})
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  FLAGS+=(--arch arm64 --arch x86_64)
fi

echo "==> swift build ${FLAGS[*]}"
swift build "${FLAGS[@]}"
BIN_DIR="$(swift build "${FLAGS[@]}" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN_DIR/IslandClip" "$APP/Contents/MacOS/IslandClip"
cp "$BIN_DIR/libIslandMediaHelper.dylib" "$APP/Contents/Frameworks/libIslandMediaHelper.dylib"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Ad-hoc signing"
codesign --force --sign - "$APP/Contents/Frameworks/libIslandMediaHelper.dylib"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Built $APP"
