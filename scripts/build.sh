#!/usr/bin/env bash
# Builds Perch.app into ./build. Usage: scripts/build.sh [debug|release] [--run]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/Perch.app"
HELPER="libPerchMediaHelper.dylib"

swift build -c "$CONFIG"
swift build -c "$CONFIG" --product PerchMediaHelper
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Perch" "$APP/Contents/MacOS/Perch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
# Focus's sounds, and the launchd agent that relaunches Perch when it is killed (Focus › keep alive).
cp -R Resources/Sounds "$APP/Contents/Resources/Sounds"
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp Resources/LaunchAgents/*.plist "$APP/Contents/Library/LaunchAgents/"
# Loaded into /usr/bin/perl at runtime to read Now Playing (see NowPlayingService); sign it on its own.
cp "$BIN_DIR/$HELPER" "$APP/Contents/Frameworks/$HELPER"
codesign --force --sign - "$APP/Contents/Frameworks/$HELPER" >/dev/null
scripts/sign.sh "$APP"
echo "Built $APP"

if [[ "${2:-}" == "--run" ]]; then
  pkill -x Perch 2>/dev/null || true
  open "$APP"
fi
