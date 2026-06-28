#!/usr/bin/env bash
# Package dist/AgentMeter.app into a compressed DMG with an /Applications symlink.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/dist/AgentMeter.app"
VERSION="${MARKETING_VERSION:-1.0.0}"
DMG="$ROOT/dist/AgentMeter-$VERSION.dmg"
STAGE="$(mktemp -d)"

[ -d "$APP" ] || { echo "Build the app first: make app"; exit 1; }

echo "==> Staging"
ditto "$APP" "$STAGE/AgentMeter.app"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating DMG"
rm -f "$DMG"
hdiutil create -volname "AgentMeter" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

rm -rf "$STAGE"
echo "==> Done: $DMG"
