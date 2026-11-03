#!/bin/bash
# Installs the latest CleanBro.app from GitHub Releases.
#   curl -fsSL https://raw.githubusercontent.com/jetorbitdev/cleanbro/main/install.sh | bash
# Files downloaded with curl aren't quarantined, so the app opens without
# the Gatekeeper "Open Anyway" step. Override the target with INSTALL_DIR=...
set -euo pipefail

REPO="jetorbitdev/cleanbro"
BASE="https://github.com/$REPO/releases/latest/download"
DEST="${INSTALL_DIR:-/Applications}"
APP="$DEST/CleanBro.app"

[[ "$(uname -s)" == "Darwin" ]] || { echo "CleanBro only runs on macOS." >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "⬇️  Downloading CleanBro…"
curl -fsSL -o "$TMP/CleanBro.zip" "$BASE/CleanBro.zip"
curl -fsSL -o "$TMP/SHA256SUMS.txt" "$BASE/SHA256SUMS.txt"

echo "🔐 Verifying checksum…"
(cd "$TMP" && grep ' CleanBro.zip$' SHA256SUMS.txt | shasum -a 256 -c - >/dev/null) \
  || { echo "Checksum mismatch, aborting." >&2; exit 1; }

ditto -x -k "$TMP/CleanBro.zip" "$TMP"

# /Applications may need admin rights on some Macs
mkdir -p "$DEST" 2>/dev/null || true
SUDO=""
if [[ ! -w "$DEST" ]] || { [[ -e "$APP" ]] && [[ ! -w "$APP" ]]; }; then
  SUDO="sudo"
  echo "🔑 Admin password needed to write to $DEST"
fi

osascript -e 'quit app "CleanBro"' >/dev/null 2>&1 || true
$SUDO mkdir -p "$DEST"
$SUDO rm -rf "$APP"
$SUDO ditto "$TMP/CleanBro.app" "$APP"
$SUDO xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "✅ Installed to $APP"
open "$APP"
