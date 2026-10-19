#!/usr/bin/env bash
# Packages Claude Usage for download: build/Claude-Usage.dmg holds the app (Apple silicon and
# Intel) next to a link to Applications, so it installs by dragging one onto the other.
#
#   scripts/make-dmg.sh
#
# Without a Developer ID the app is ad-hoc signed, and people confirm it once in System Settings ›
# Privacy & Security the first time they open it. With an Apple Developer ID it opens like any
# other downloaded app:
#
#   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE=claude-usage scripts/make-dmg.sh
#
# NOTARY_PROFILE names notarization credentials saved once with
#   xcrun notarytool store-credentials claude-usage --apple-id you@example.com --team-id TEAMID
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Claude Usage"
BUILD_DIR="${BUILD_DIR:-build}"
APP="$BUILD_DIR/$APP_NAME.app"
# One name for every version, so the README can link to the latest release's download.
DMG="$BUILD_DIR/Claude-Usage.dmg"
IDENTITY="${CODESIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

if [[ -n "$NOTARY_PROFILE" && "$IDENTITY" == "-" ]]; then
  echo "error: notarizing needs a Developer ID: set CODESIGN_IDENTITY too" >&2
  exit 1
fi

UNIVERSAL="${UNIVERSAL:-1}" BUILD_DIR="$BUILD_DIR" scripts/build-app.sh

notarize() {
  echo "==> Notarizing $(basename "$1") (this can take a few minutes)"
  local log
  if ! log="$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"; then
    echo "$log" >&2
    exit 1
  fi
  echo "$log"
  if ! grep -q "status: Accepted" <<< "$log"; then
    echo "error: Apple didn't accept $(basename "$1"). See why with: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE" >&2
    exit 1
  fi
}

if [[ -n "$NOTARY_PROFILE" ]]; then
  # Notarize and staple the app itself too, so a copy dragged out of the disk image opens
  # without Gatekeeper having to look it up online.
  ZIP="$BUILD_DIR/Claude-Usage-notarize.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP"
  rm -f "$ZIP"
  xcrun stapler staple "$APP"
fi

echo "==> Creating $DMG"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -fs HFS+ -format UDZO "$DMG"

if [[ "$IDENTITY" != "-" ]]; then
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
fi
if [[ -n "$NOTARY_PROFILE" ]]; then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
fi

echo "==> Built $DMG ($(tr -d '[:space:]' < VERSION))"
shasum -a 256 "$DMG"
if [[ "$IDENTITY" == "-" ]]; then
  echo "    Ad-hoc signed: people confirm it in System Settings › Privacy & Security on first open."
fi
