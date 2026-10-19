#!/usr/bin/env bash
# Builds build/Claude-Usage.dmg and publishes it as the GitHub release for the version in VERSION.
#
#   scripts/release.sh
#
# Needs the GitHub CLI (brew install gh, then gh auth login). Set CODESIGN_IDENTITY and
# NOTARY_PROFILE as for make-dmg.sh to publish a build that opens without a Gatekeeper warning.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v$VERSION"

if ! command -v gh > /dev/null; then
  echo "error: this needs the GitHub CLI: brew install gh, then gh auth login" >&2
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: commit your changes first, so the release matches a pushed commit" >&2
  exit 1
fi
if [[ -z "$(git branch -r --contains HEAD 2> /dev/null)" ]]; then
  echo "error: push this commit to GitHub first" >&2
  exit 1
fi
if gh release view "$TAG" > /dev/null 2>&1; then
  echo "error: $TAG is already released; raise the number in VERSION for a new release" >&2
  exit 1
fi

scripts/make-dmg.sh

echo "==> Publishing $TAG"
gh release create "$TAG" build/Claude-Usage.dmg \
  --target "$(git rev-parse HEAD)" \
  --title "Claude Usage $VERSION" \
  --notes "Download **Claude-Usage.dmg** below, open it and drag Claude Usage onto Applications. Needs macOS 13 or later and Claude Code signed in with your Claude account (\`claude auth login\`). See the [README](https://github.com/mihok/osx-claude-usage#install) for the first launch." \
  --generate-notes
