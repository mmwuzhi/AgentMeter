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

By default, generate_appcast signs every release DMG in dist/ (never an
AgentMeter-<version>-rc.dmg) and writes dist/appcast.xml.
Set SPARKLE_VERSION=1.2.3 to sign only dist/AgentMeter-1.2.3.dmg.
Upload the selected DMG(s) + appcast.xml to your SUFeedURL host.
EOF
  exit 1
fi

# An rc image (AgentMeter-<version>-rc.dmg, from UPDATE_CHANNEL=rc) is a test
# build and must never be signed into a feed.
release_dmgs=()
rc_dmgs=()
while IFS= read -r dmg; do
  case "$dmg" in
    *-rc.dmg) rc_dmgs+=("$dmg") ;;
    *) release_dmgs+=("$dmg") ;;
  esac
done < <(find "$DIST" -maxdepth 1 -name '*.dmg' | sort)

if [[ ${#release_dmgs[@]} -eq 0 ]]; then
  if [[ ${#rc_dmgs[@]} -gt 0 ]]; then
    echo "Only rc DMGs found in $DIST; an rc image is never signed into a feed." >&2
    echo "Build the release image first: make dmg (without UPDATE_CHANNEL=rc)" >&2
  else
    echo "No DMG found in $DIST. Run: make dmg" >&2
  fi
  exit 1
fi

ARCHIVES_DIR="$DIST"
APPCAST_OUTPUT=""
TMP_ARCHIVES="$(mktemp -d)"
trap 'rm -rf "$TMP_ARCHIVES"' EXIT
STAGED_APPCAST=""

if [[ -n "${SPARKLE_VERSION:-}" ]]; then
  dmg="$DIST/AgentMeter-$SPARKLE_VERSION.dmg"
  if [[ "$dmg" == *-rc.dmg ]]; then
    echo "SPARKLE_VERSION=$SPARKLE_VERSION names an rc image; it is never signed into a feed." >&2
    exit 1
  fi
  if [[ ! -f "$dmg" ]]; then
    echo "No DMG found for SPARKLE_VERSION=$SPARKLE_VERSION at $dmg" >&2
    exit 1
  fi

  cp "$dmg" "$TMP_ARCHIVES/"
  ARCHIVES_DIR="$TMP_ARCHIVES"
  APPCAST_OUTPUT="$DIST/appcast.xml"
  rm -f "$APPCAST_OUTPUT"
else
  # Stage the release DMGs (with their release notes) and any existing feed, so
  # generate_appcast updates that feed and sees no rc image.
  for dmg in "${release_dmgs[@]}"; do
    cp "$dmg" "$TMP_ARCHIVES/"
    for notes in "${dmg%.dmg}".html "${dmg%.dmg}".md "${dmg%.dmg}".txt; do
      if [[ -f "$notes" ]]; then cp "$notes" "$TMP_ARCHIVES/"; fi
    done
  done
  if [[ -f "$DIST/appcast.xml" ]]; then cp "$DIST/appcast.xml" "$TMP_ARCHIVES/"; fi
  ARCHIVES_DIR="$TMP_ARCHIVES"
  STAGED_APPCAST="$TMP_ARCHIVES/appcast.xml"
  if [[ ${#rc_dmgs[@]} -gt 0 ]]; then
    echo "==> Skipping rc image(s), never signed into a feed:"
    printf '    %s\n' "${rc_dmgs[@]}"
  fi
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
# ${args[@]+...}: an empty array is an unbound variable under set -u in macOS's bash 3.2.
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  printf '%s' "$SPARKLE_PRIVATE_KEY" | "$GENERATE_APPCAST" ${args[@]+"${args[@]}"} "$ARCHIVES_DIR"
else
  "$GENERATE_APPCAST" ${args[@]+"${args[@]}"} "$ARCHIVES_DIR"
fi
if [[ -n "$STAGED_APPCAST" ]]; then
  cp "$STAGED_APPCAST" "$DIST/appcast.xml"
fi
echo "==> Done: $DIST/appcast.xml"
echo "    Upload dist/*.dmg and dist/appcast.xml to your SUFeedURL host."
