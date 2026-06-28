#!/usr/bin/env bash
# Generate/refresh appcast.xml for the latest DMG using Sparkle's tools.
# Requires Sparkle's `generate_appcast` (from the Sparkle release tools) on PATH,
# and a private EdDSA key in your login keychain (created once via `generate_keys`).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DIST="$ROOT/dist"

if ! command -v generate_appcast >/dev/null 2>&1; then
  cat <<'EOF'
generate_appcast not found.

One-time setup:
  1. Download Sparkle tools:  https://github.com/sparkle-project/Sparkle/releases
     (the .tar.xz contains bin/generate_keys and bin/generate_appcast)
  2. Run ./bin/generate_keys once. Copy the printed PUBLIC key into
     Scripts/Info.plist -> SUPublicEDKey (replace REPLACE-WITH-...).
  3. Set SUFeedURL in Scripts/Info.plist to where you'll host appcast.xml
     (e.g. a GitHub Releases raw URL or your own domain).
  4. Put generate_appcast on PATH, then re-run: make appcast

generate_appcast signs every DMG in dist/ and writes dist/appcast.xml.
Upload the DMG(s) + appcast.xml to your SUFeedURL host.
EOF
  exit 1
fi

echo "==> Signing DMGs and writing appcast.xml"
generate_appcast "$DIST"
echo "==> Done: $DIST/appcast.xml"
echo "    Upload dist/*.dmg and dist/appcast.xml to your SUFeedURL host."
