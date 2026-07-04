#!/usr/bin/env bash
# Generate/refresh appcast.xml using Sparkle's tools.
# Uses Sparkle's `generate_appcast` from PATH, or the SwiftPM artifact checkout.
# Requires a private EdDSA key in your login keychain (created once via
# `generate_keys`), or SPARKLE_PRIVATE_KEY in CI.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DIST="$ROOT/dist"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"

GENERATE_APPCAST="${SPARKLE_GENERATE_APPCAST:-}"
if [[ -z "$GENERATE_APPCAST" ]]; then
  if command -v generate_appcast >/dev/null 2>&1; then
    GENERATE_APPCAST="$(command -v generate_appcast)"
  elif [[ -x "$SPARKLE_BIN/generate_appcast" ]]; then
    GENERATE_APPCAST="$SPARKLE_BIN/generate_appcast"
  fi
fi

if [[ -z "$GENERATE_APPCAST" || ! -x "$GENERATE_APPCAST" ]]; then
  cat <<'EOF'
generate_appcast not found.

One-time setup:
  1. Build the project once so SwiftPM downloads Sparkle:
       make app
     Or download Sparkle tools:
       https://github.com/sparkle-project/Sparkle/releases
  2. Run ./bin/generate_keys once. Copy the printed PUBLIC key into
     Scripts/Info.plist -> SUPublicEDKey.
  3. Set SUFeedURL in Scripts/Info.plist to where you'll host appcast.xml.
  4. Re-run: make appcast

By default, generate_appcast signs every DMG in dist/ and writes dist/appcast.xml.
Set SPARKLE_VERSION=1.2.3 to sign only dist/AgentMeter-1.2.3.dmg.
Upload the selected DMG(s) + appcast.xml to your SUFeedURL host.
EOF
  exit 1
fi

if ! find "$DIST" -maxdepth 1 -name '*.dmg' -print -quit | grep -q .; then
  echo "No DMG found in $DIST. Run: make dmg" >&2
  exit 1
fi

ARCHIVES_DIR="$DIST"
APPCAST_OUTPUT=""
TMP_ARCHIVES=""

if [[ -n "${SPARKLE_VERSION:-}" ]]; then
  dmg="$DIST/AgentMeter-$SPARKLE_VERSION.dmg"
  if [[ ! -f "$dmg" ]]; then
    echo "No DMG found for SPARKLE_VERSION=$SPARKLE_VERSION at $dmg" >&2
    exit 1
  fi

  TMP_ARCHIVES="$(mktemp -d)"
  trap 'rm -rf "$TMP_ARCHIVES"' EXIT
  cp "$dmg" "$TMP_ARCHIVES/"
  ARCHIVES_DIR="$TMP_ARCHIVES"
  APPCAST_OUTPUT="$DIST/appcast.xml"
  rm -f "$APPCAST_OUTPUT"
fi

args=()

if [[ -n "${SPARKLE_KEY_ACCOUNT:-}" ]]; then
  args+=(--account "$SPARKLE_KEY_ACCOUNT")
fi

if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  args+=(--ed-key-file -)
fi

if [[ -n "${SPARKLE_DOWNLOAD_URL_PREFIX:-}" ]]; then
  args+=(--download-url-prefix "$SPARKLE_DOWNLOAD_URL_PREFIX")
fi

if [[ -n "$APPCAST_OUTPUT" ]]; then
  args+=(-o "$APPCAST_OUTPUT")
fi

echo "==> Signing DMGs and writing appcast.xml"
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  printf '%s' "$SPARKLE_PRIVATE_KEY" | "$GENERATE_APPCAST" "${args[@]}" "$ARCHIVES_DIR"
else
  "$GENERATE_APPCAST" "${args[@]}" "$ARCHIVES_DIR"
fi
echo "==> Done: $DIST/appcast.xml"
echo "    Upload dist/*.dmg and dist/appcast.xml to your SUFeedURL host."
