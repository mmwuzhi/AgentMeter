#!/usr/bin/env bash
# Build AgentMeter and assemble a runnable .app bundle (Sparkle embedded, ad-hoc signed).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CONFIG="${CONFIG:-release}"
MARKETING_VERSION="${MARKETING_VERSION:-1.0.1}"
BUILD_VERSION="${BUILD_VERSION:-$(date +%Y%m%d%H%M)}"
APP="$ROOT/dist/AgentMeter.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
echo "    bin: $BIN_DIR"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

# Executable
cp "$BIN_DIR/AgentMeter" "$APP/Contents/MacOS/AgentMeter"

# Resources go in Contents/Resources (the only place codesign accepts). The SPM
# resource bundle's generated Bundle.module accessor looks at the .app root, which
# is illegal for signing, so we ALSO drop embedded-pricing.json loose here and load
# it via Bundle.main first (see PricingService.loadEmbedded).
cp -R "$BIN_DIR/AgentMeter_AgentMeter.bundle" "$APP/Contents/Resources/"
cp "$ROOT/Sources/AgentMeter/Resources/embedded-pricing.json" "$APP/Contents/Resources/"

# App icon (CFBundleIconFile = AppIcon -> Contents/Resources/AppIcon.icns)
cp "$ROOT/Scripts/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Sparkle framework
cp -R "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/"

# Info.plist (substitute versions)
sed -e "s/__MARKETING_VERSION__/$MARKETING_VERSION/" \
    -e "s/__BUILD_VERSION__/$BUILD_VERSION/" \
    "$ROOT/Scripts/Info.plist" > "$APP/Contents/Info.plist"

# Ensure the binary can find the framework in Contents/Frameworks
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/AgentMeter" 2>/dev/null || true

SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' \
        | head -n 1 || true)"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="-"
    echo "==> Codesigning ad-hoc"
else
    echo "==> Codesigning with $SIGN_IDENTITY"
fi

# Sign framework first, then the app bundle.
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP/Contents/Frameworks/Sparkle.framework" 2>/dev/null || true
codesign --force --deep --sign "$SIGN_IDENTITY" --timestamp=none "$APP" 2>/dev/null || true

echo "==> Done: $APP"
echo "    open \"$APP\""
