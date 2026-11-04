#!/bin/bash
# Build Deckhand.app (a double-clickable macOS app) from the Swift package.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/dist/Deckhand.app"
CONF="${1:-release}"

echo "==> swift build -c $CONF"
swift build -c "$CONF" --product UltraWorkspaceApp

BIN="$ROOT/.build/$CONF/UltraWorkspaceApp"
[ -x "$BIN" ] || { echo "build output not found: $BIN"; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/UltraWorkspaceApp"
cp "$ROOT/packaging/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/packaging/AppIcon.icns" ] && cp "$ROOT/packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns" || true
# The bar's Deckhand apps (android/DeckhandMonitor flavors), installed from Settings over ADB.
if ls "$ROOT"/dist/bar-apps/*.apk >/dev/null 2>&1; then mkdir -p "$APP/Contents/Resources/bar-apps"; cp "$ROOT"/dist/bar-apps/*.apk "$APP/Contents/Resources/bar-apps/"; fi

# Signing: use a Developer ID Application identity when one is in the keychain
# (override with DECKHAND_SIGN_IDENTITY="Developer ID Application: …" or
# DECKHAND_SIGN_IDENTITY=- to force ad-hoc). Developer ID + hardened runtime +
# timestamp is what notarization requires; ad-hoc keeps local builds working.
IDENTITY="${DECKHAND_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)"
fi
if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
    echo "==> codesign with $IDENTITY (hardened runtime, timestamp)"
    codesign --force --deep --options runtime --timestamp \
        --entitlements "$ROOT/packaging/Deckhand.entitlements" \
        --sign "$IDENTITY" "$APP"
    codesign --verify --strict --verbose=1 "$APP" && echo "   signature OK"
else
    echo "==> ad-hoc codesign (no Developer ID identity found; Local Network permission still works)"
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "   (codesign skipped)"
fi

echo "==> done: $APP"
echo "   open it with:  open \"$APP\""
