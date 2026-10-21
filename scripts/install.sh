#!/usr/bin/env sh
set -eu

REPO="andymitch/pulse"
DEST="/Applications/Pulse.app"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Pulse is a macOS app." >&2
  exit 1
fi
if [ "$(uname -m)" != "arm64" ]; then
  echo "Only Apple silicon builds are published. Build from source instead, see the README." >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "==> Downloading the latest Pulse release"
curl -fsSL "https://github.com/$REPO/releases/latest/download/Pulse_aarch64.zip" -o "$tmp/Pulse.zip"

echo "==> Installing to $DEST"
pkill -x Pulse 2>/dev/null || true
rm -rf "$DEST"
ditto -x -k "$tmp/Pulse.zip" /Applications

echo "==> Clearing Gatekeeper quarantine"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

open "$DEST"
echo "==> Done. Pulse is in your menu bar, and updates itself from here on."
