#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Spaces.app"
MACOS="$APP/Contents/MacOS"
RESOURCES="$APP/Contents/Resources"
ARCH="$(uname -m)"
SDK="$(xcrun --show-sdk-path)"
INSTALL="$HOME/Applications/Spaces.app"

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

chmod +x "$ROOT/scripts/create-signing-identity.sh"
"$ROOT/scripts/create-signing-identity.sh"
SIGN_ID="$(security find-identity -v -p codesigning | awk '/Spaces Local Signer/ {print $2; exit}')"
if [[ -z "$SIGN_ID" ]]; then
  echo "No Spaces Local Signer identity found" >&2
  exit 1
fi
codesign --force --sign "$SIGN_ID" \
  --identifier com.arnovaneetvelde.macos-spaces \
  --timestamp=none \
  "$APP"

mkdir -p "$HOME/Applications"
rm -rf "$INSTALL"
ditto "$APP" "$INSTALL"

echo "Built $APP"
echo "Installed $INSTALL"
echo "Run with: open \"$INSTALL\""
