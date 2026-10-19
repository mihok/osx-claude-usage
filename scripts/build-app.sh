#!/usr/bin/env bash
# Builds "Claude Usage.app" into ./build.
#
#   scripts/build-app.sh               # release build for this Mac's architecture
#   UNIVERSAL=1 scripts/build-app.sh   # one app for Apple silicon and Intel Macs
#   CODESIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Claude Usage"
EXECUTABLE="ClaudeUsage"
BUILD_DIR="${BUILD_DIR:-build}"
VERSION="${VERSION:-$(tr -d '[:space:]' < VERSION)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP="$BUILD_DIR/$APP_NAME.app"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Compiling $EXECUTABLE $VERSION ($BUILD_NUMBER)"
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  # One build per architecture, joined with lipo. Unlike `--arch arm64 --arch x86_64`, this
  # works with the Command Line Tools alone. Newer SwiftPM puts every architecture's build in
  # the same folder, so each result is set aside before the next build replaces it.
  binaries=()
  for arch in arm64 x86_64; do
    flags=(-c release --triple "$arch-apple-macosx13.0")
    swift build "${flags[@]}"
    cp "$(swift build "${flags[@]}" --show-bin-path)/$EXECUTABLE" "$WORK/$EXECUTABLE-$arch"
    binaries+=("$WORK/$EXECUTABLE-$arch")
  done
else
  swift build -c release
  binaries=("$(swift build -c release --show-bin-path)/$EXECUTABLE")
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if (( ${#binaries[@]} > 1 )); then
  lipo -create "${binaries[@]}" -output "$APP/Contents/MacOS/$EXECUTABLE"
  archs=" $(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE") "
  if [[ "$archs" != *" arm64 "* || "$archs" != *" x86_64 "* ]]; then
    echo "error: the app isn't universal; it has:$archs" >&2
    exit 1
  fi
else
  cp "${binaries[0]}" "$APP/Contents/MacOS/$EXECUTABLE"
fi
echo "    Architectures: $(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE")"
# The Command Line Tools lack the Intel copy of the library that adds Swift's parameter-pack
# runtime to macOS 13, which is fine unless the app ends up needing it.
for arch in $(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE"); do
  imports="$(nm -u -arch "$arch" "$APP/Contents/MacOS/$EXECUTABLE" 2> /dev/null || true)"
  if grep -Eq '_swift_allocate(Metadata|WitnessTable)Pack$' <<< "$imports"; then
    echo "warning: the $arch build needs Swift runtime support that macOS 13 lacks; it opens only on macOS 14 or later" >&2
  fi
done
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Packaging/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" > /dev/null

echo "==> Rendering app icon"
if "$APP/Contents/MacOS/$EXECUTABLE" --render-icon "$WORK/AppIcon.iconset" \
  && iconutil -c icns "$WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"; then
  :
else
  echo "warning: icon rendering failed; the app will use the generic icon" >&2
fi

echo "==> Signing"
# Ad-hoc signing ("-") is enough to run locally. Pass a Developer ID to distribute.
IDENTITY="${CODESIGN_IDENTITY:--}"
sign_flags=(--force --sign "$IDENTITY" --options runtime)
if [[ "$IDENTITY" != "-" ]]; then
  # Notarization needs a secure timestamp, which ad-hoc signatures can't have.
  sign_flags+=(--timestamp)
fi
codesign "${sign_flags[@]}" "$APP"
codesign --verify --strict "$APP"

echo "==> Built $APP"
