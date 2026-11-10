#!/bin/bash
# Builds Snapper.app, signs it, and installs it to /Applications.
# Usage: ./build.sh [--no-install]
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product Snapper
BIN="$(swift build -c release --show-bin-path)/Snapper"

APP="build/Snapper.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Snapper"
cp Info.plist "$APP/Contents/Info.plist"

# The build number is the count of commits, so it rises by itself with every saved change.
# The version (CFBundleShortVersionString in Info.plist) is changed by hand when a release means something.
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then BUILD="$((BUILD + 1))"; fi
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# A stable signing identity keeps the Screen Recording permission across rebuilds.
IDENTITY="$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')"
if [ -z "$IDENTITY" ]; then
  echo "No Apple Development identity found; signing ad hoc (permission will reset on each build)." >&2
  IDENTITY="-"
fi
codesign --force --options runtime --sign "$IDENTITY" "$APP"

if [ "${1:-}" != "--no-install" ]; then
  pkill -x Snapper 2>/dev/null || true
  rm -rf /Applications/Snapper.app
  cp -R "$APP" /Applications/Snapper.app
  echo "Installed /Applications/Snapper.app"
fi
