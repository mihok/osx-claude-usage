#!/usr/bin/env bash
# Builds "Claude Usage.app" into ./build.
#
#   scripts/build-app.sh               # release build for this Mac's architecture
#   UNIVERSAL=1 scripts/build-app.sh   # arm64 + x86_64 (needs full Xcode)
#   CODESIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Claude Usage"
EXECUTABLE="ClaudeUsage"
BUILD_DIR="${BUILD_DIR:-build}"
VERSION="${VERSION:-$(tr -d '[:space:]' < VERSION)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP="$BUILD_DIR/$APP_NAME.app"

swift_flags=(-c release)
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  swift_flags+=(--arch arm64 --arch x86_64)
fi

echo "==> Compiling $EXECUTABLE $VERSION ($BUILD_NUMBER)"
swift build "${swift_flags[@]}"
BIN_DIR="$(swift build "${swift_flags[@]}" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Packaging/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" > /dev/null

echo "==> Rendering app icon"
ICON_WORK="$(mktemp -d)"
trap 'rm -rf "$ICON_WORK"' EXIT
if "$APP/Contents/MacOS/$EXECUTABLE" --render-icon "$ICON_WORK/AppIcon.iconset" \
  && iconutil -c icns "$ICON_WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"; then
  :
else
  echo "warning: icon rendering failed; the app will use the generic icon" >&2
fi

echo "==> Signing"
# Ad-hoc signing ("-") is enough to run locally. Pass a Developer ID to distribute.
codesign --force --sign "${CODESIGN_IDENTITY:--}" --options runtime "$APP"
codesign --verify --strict "$APP"

echo "==> Built $APP"
