#!/usr/bin/env bash
# Package dist/AgentMeter.app into a compressed DMG with a styled install window.
# Uses dmgbuild (writes the .DS_Store directly, no Finder scripting) so the
# background renders reliably, including in headless CI. Falls back to a plain
# hdiutil DMG (no background) only if dmgbuild is unavailable.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/dist/AgentMeter.app"
VERSION="${MARKETING_VERSION:-1.0.2}"
DMG="$ROOT/dist/AgentMeter-$VERSION.dmg"

[ -d "$APP" ] || { echo "Build the app first: make app"; exit 1; }
rm -f "$DMG"

if command -v dmgbuild >/dev/null 2>&1; then
    echo "==> Creating DMG with dmgbuild"
    dmgbuild -s "$ROOT/Scripts/dmg-settings.py" \
        -D app="$APP" \
        -D background="$ROOT/Scripts/dmg-background.tiff" \
        "AgentMeter" "$DMG"
else
    echo "==> dmgbuild not found; building a plain DMG (no background)."
    echo "    Install it with: pip3 install dmgbuild"
    STAGE="$(mktemp -d)"
    ditto "$APP" "$STAGE/AgentMeter.app"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "AgentMeter" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
    rm -rf "$STAGE"
fi

echo "==> Done: $DMG"
