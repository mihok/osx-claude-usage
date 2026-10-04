#!/usr/bin/env bash
# Builds Claude Usage, copies it to /Applications (or ~/Applications) and starts it.
set -euo pipefail

cd "$(dirname "$0")/.."
scripts/build-app.sh

APP_NAME="Claude Usage.app"
DEST_DIR="/Applications"
if [[ ! -w "$DEST_DIR" ]]; then
  DEST_DIR="$HOME/Applications"
  mkdir -p "$DEST_DIR"
fi

# Quit a running copy so it can be replaced.
osascript -e 'tell application id "com.github.mihok.ClaudeUsage" to quit' > /dev/null 2>&1 || true
pkill -x ClaudeUsage > /dev/null 2>&1 || true
sleep 1

rm -rf "$DEST_DIR/$APP_NAME"
cp -R "build/$APP_NAME" "$DEST_DIR/"
echo "==> Installed $DEST_DIR/$APP_NAME"

open "$DEST_DIR/$APP_NAME"
echo "==> Claude Usage is running in your menu bar. Turn on 'Launch at login' in its Settings to keep it there."
