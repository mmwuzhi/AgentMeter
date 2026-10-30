#!/usr/bin/env bash
# Build AgentMeter and assemble a runnable .app bundle (Sparkle embedded, signed).
#
# Environment (all optional):
#   MARKETING_VERSION  CFBundleShortVersionString; defaults to the VERSION file.
#   BUILD_VERSION      CFBundleVersion; defaults to Scripts/build-number.sh.
#   UPDATE_CHANNEL     release (default) keeps the public Sparkle feed;
#                      rc is a test build that never updates itself.
#   CODESIGN_IDENTITY  signing identity; defaults to the first Developer ID
#                      Application identity, else the first Apple Development
#                      one, else ad-hoc ("-").
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CONFIG="${CONFIG:-release}"
MARKETING_VERSION="${MARKETING_VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"
BUILD_VERSION="${BUILD_VERSION:-$(bash "$ROOT/Scripts/build-number.sh")}"
UPDATE_CHANNEL="${UPDATE_CHANNEL:-release}"
APP="$ROOT/dist/AgentMeter.app"

case "$UPDATE_CHANNEL" in
    release|rc) ;;
    *) echo "UPDATE_CHANNEL must be release or rc, got: $UPDATE_CHANNEL" >&2; exit 1 ;;
esac
echo "==> AgentMeter $MARKETING_VERSION ($BUILD_VERSION), update channel: $UPDATE_CHANNEL"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
echo "    bin: $BIN_DIR"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" "$APP/Contents/Helpers"

# Executable
cp "$BIN_DIR/AgentMeter" "$APP/Contents/MacOS/AgentMeter"

# Claude Code invokes this small helper from opt-in status hooks. The app copies
# it to a stable Application Support path before installing those hooks.
cp "$BIN_DIR/AgentMeterHook" "$APP/Contents/Helpers/agentmeter-hook"
chmod 0755 "$APP/Contents/Helpers/agentmeter-hook"

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

# An rc build is a test build: no feed, no automatic checks, and a marker the
# app reads (UpdatePolicy) so it does not start Sparkle or offer "Check Now".
if [[ "$UPDATE_CHANNEL" == "rc" ]]; then
    /usr/libexec/PlistBuddy \
        -c "Delete :SUFeedURL" \
        -c "Set :SUEnableAutomaticChecks false" \
        -c "Add :AgentMeterUpdateChannel string rc" \
        "$APP/Contents/Info.plist"
fi

# Ensure the binary can find the framework in Contents/Frameworks
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/AgentMeter" 2>/dev/null || true

# Signing identity. Revoked or expired entries are skipped: `find-identity -v`
# still lists them, tagged CSSMERR_*.
IDENTITIES="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null | grep -v 'CSSMERR_' || true)"

# Name of the first identity whose label starts with "$1:".
first_identity() {
    printf '%s\n' "$IDENTITIES" | sed -n "/\"$1:/{s/.*\"\\($1:[^\"]*\\)\".*/\\1/;p;q;}"
}

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="$CODESIGN_IDENTITY"
else
    SIGN_IDENTITY="$(first_identity 'Developer ID Application')"
    [[ -n "$SIGN_IDENTITY" ]] || SIGN_IDENTITY="$(first_identity 'Apple Development')"
    [[ -n "$SIGN_IDENTITY" ]] || SIGN_IDENTITY="-"
fi

# Flags shared by every item. A real identity gets the hardened runtime; only a
# Developer ID identity gets a secure timestamp (notarization needs it, and it
# needs the network). Ad-hoc keeps NO hardened runtime on purpose: it enforces
# library validation, and an ad-hoc signature has no Team ID, so the app could
# not load its own ad-hoc-signed Sparkle.framework.
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    sign_flags=(--timestamp=none)
    echo "==> Codesigning ad-hoc (no hardened runtime, no timestamp)"
else
    identity_line="$(grep -F -- "$SIGN_IDENTITY" <<<"$IDENTITIES" || true)"
    if [[ "$SIGN_IDENTITY" == "Developer ID Application:"* || "$identity_line" == *"Developer ID Application:"* ]]; then
        sign_flags=(--options runtime --timestamp)
        echo "==> Codesigning with $SIGN_IDENTITY (hardened runtime, secure timestamp)"
    else
        sign_flags=(--options runtime --timestamp=none)
        echo "==> Codesigning with $SIGN_IDENTITY (hardened runtime, no timestamp)"
    fi
fi

# sign [extra codesign arguments...] <path>
sign() {
    codesign --force --sign "$SIGN_IDENTITY" "${sign_flags[@]}" "$@"
}

# Inside-out, never --deep: Sparkle's XPC services, Autoupdate and Updater.app
# first, then the framework, the hook helper, and the app last. A failure
# stops the build.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
sign --identifier com.shu.agentmeter.hook "$APP/Contents/Helpers/agentmeter-hook"
# The app drives Terminal, iTerm2 and Ghostty with NSAppleScript; the hardened
# runtime denies Apple Events without this entitlement.
sign --entitlements "$ROOT/Scripts/AgentMeter.entitlements" "$APP"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Done: $APP"
echo "    open \"$APP\""
