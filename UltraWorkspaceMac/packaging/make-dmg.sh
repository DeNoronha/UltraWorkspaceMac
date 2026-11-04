#!/bin/bash
# Build Deckhand.app and package it into a distributable DMG
# (app + Applications shortcut + manual).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

./packaging/make-app.sh release

STAGE="$ROOT/dist/dmg-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$ROOT/dist/Deckhand.app" "$STAGE/Deckhand.app"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/MANUAL.md" "$STAGE/Manual.md"

# Best-effort readable PDF of the manual.
if command -v cupsfilter >/dev/null 2>&1; then
    cupsfilter -i text/plain "$ROOT/MANUAL.md" > "$STAGE/Manual.pdf" 2>/dev/null || rm -f "$STAGE/Manual.pdf"
fi

# Is the app signed with a Developer ID (→ we can notarize) or ad-hoc?
# (No grep -q in a pipeline here: with `pipefail`, grep closing the pipe early
# makes codesign exit 141 and the test silently fails.)
SIGNED_DEVID=0
SIGINFO="$(codesign -dvv "$ROOT/dist/Deckhand.app" 2>&1 || true)"
case "$SIGINFO" in *"Authority=Developer ID Application"*) SIGNED_DEVID=1 ;; esac

# Notarize + staple when a Developer ID signature and notary credentials exist.
# One-time setup (interactive, needs an app-specific password from appleid.apple.com):
#   xcrun notarytool store-credentials "deckhand-notary" --apple-id <apple-id> --team-id <TEAMID> --password <app-specific-password>
# Decided here, before the Read Me is written, so the text never claims a notarization that did not happen.
NOTARY_PROFILE="${DECKHAND_NOTARY_PROFILE:-deckhand-notary}"
CAN_NOTARIZE=0
if [ "$SIGNED_DEVID" = 1 ] && xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    CAN_NOTARIZE=1
fi

if [ "$CAN_NOTARIZE" = 1 ]; then
cat > "$STAGE/Read Me First.txt" <<'TXT'
Deckhand for UltraBar X
======================

1. Drag Deckhand onto the Applications folder.
2. Open it from Applications (signed with a Developer ID and notarized by Apple).
3. BEFORE plugging in: power the CoreBar via the USB-OTG port; connect your
   computer only to the PC-LINK port (5 V). The wrong port can destroy the unit.
4. Scan for CoreBars, Pair, and tap Approve on the device.

See Manual.pdf / Manual.md for full instructions.
Community software. Not affiliated with Sanytron.
TXT
else
cat > "$STAGE/Read Me First.txt" <<'TXT'
Deckhand for UltraBar X
======================

1. Drag Deckhand onto the Applications folder.
2. First launch: right-click Deckhand in Applications -> Open -> Open.
   (This build is not notarized; you only approve it once.)
3. BEFORE plugging in: power the CoreBar via the USB-OTG port; connect your
   computer only to the PC-LINK port (5 V). The wrong port can destroy the unit.
4. Scan for CoreBars, Pair, and tap Approve on the device.

See Manual.pdf / Manual.md for full instructions.
Community software. Not affiliated with Sanytron.
TXT
fi

DMG="$ROOT/dist/Deckhand.dmg"
rm -f "$DMG"
hdiutil create -volname "Deckhand" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

if [ "$SIGNED_DEVID" = 1 ]; then
    IDENTITY="$(printf '%s\n' "$SIGINFO" | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' | sed -n 1p)"
    echo "==> signing DMG with $IDENTITY"
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
    if [ "$CAN_NOTARIZE" = 1 ]; then
        echo "==> notarizing (profile: $NOTARY_PROFILE) — this takes a few minutes…"
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        echo "==> stapling ticket"
        xcrun stapler staple "$DMG"
        if spctl -a -t open --context context:primary-signature -v "$DMG"; then
            echo "   Gatekeeper: accepted"
        else
            echo "   Gatekeeper REJECTED the DMG — do not ship it" >&2
            exit 1
        fi
    else
        echo "==> NOT notarized: no notary credentials under keychain profile '$NOTARY_PROFILE'."
        echo "    Run once:  xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id <apple-id> --team-id <TEAMID> --password <app-specific-password>"
    fi
fi

echo "done: $DMG ($(du -h "$DMG" | cut -f1))"
