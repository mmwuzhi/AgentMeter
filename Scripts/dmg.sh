#!/usr/bin/env bash
# Package dist/AgentMeter.app into a compressed DMG with a styled install window.
# Uses dmgbuild (writes the .DS_Store directly, no Finder scripting) so the
# background renders reliably, including in headless CI. Falls back to a plain
# hdiutil DMG (no background) only if dmgbuild is unavailable.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/dist/AgentMeter.app"
VERSION="${MARKETING_VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"

[ -d "$APP" ] || { echo "Build the app first: make app"; exit 1; }

# An rc image is named so it is never taken for a release one. The name comes
# from the app being packaged, not from the environment: an rc app left in
# dist/ must never become AgentMeter-<version>.dmg (appcast.sh would sign it
# into the feed and strand everyone who took it without updates).
CHANNEL="$(/usr/libexec/PlistBuddy -c 'Print :AgentMeterUpdateChannel' "$APP/Contents/Info.plist" 2>/dev/null || echo release)"
if [ -n "${UPDATE_CHANNEL:-}" ] && [ "$UPDATE_CHANNEL" != "$CHANNEL" ]; then
    echo "UPDATE_CHANNEL=$UPDATE_CHANNEL, but dist/AgentMeter.app is a $CHANNEL build. Rebuild it: UPDATE_CHANNEL=$UPDATE_CHANNEL make app" >&2
    exit 1
fi
SUFFIX=""
if [ "$CHANNEL" = "rc" ]; then SUFFIX="-rc"; fi
DMG="$ROOT/dist/AgentMeter-$VERSION$SUFFIX.dmg"
rm -f "$DMG"

if command -v dmgbuild >/dev/null 2>&1; then
    echo "==> Creating DMG with dmgbuild"
    dmgbuild -s "$ROOT/Scripts/dmg-settings.py" \
        -D app="$APP" \
        -D background="$ROOT/Scripts/dmg-background.tiff" \
        "AgentMeter" "$DMG"
else
    echo "==> dmgbuild not found; building a plain DMG (no background)."
    echo "    Install it with: pipx install dmgbuild"
    STAGE="$(mktemp -d)"
    ditto "$APP" "$STAGE/AgentMeter.app"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "AgentMeter" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
    rm -rf "$STAGE"
fi

echo "==> Done: $DMG"
