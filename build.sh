#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Spaces.app"
MACOS="$APP/Contents/MacOS"
RESOURCES="$APP/Contents/Resources"
ARCH="$(uname -m)"
SDK="$(xcrun --show-sdk-path)"

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

swiftc -O \
  -module-name Spaces \
  -target "${ARCH}-apple-macos14.0" \
  -sdk "$SDK" \
  -framework AppKit \
  -framework SwiftUI \
  -framework ServiceManagement \
  -framework ApplicationServices \
  -o "$MACOS/Spaces" \
  "$ROOT"/Sources/*.swift

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP" >/dev/null

echo "Built $APP"
echo "Run with: open \"$APP\""
