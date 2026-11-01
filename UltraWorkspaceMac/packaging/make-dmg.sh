#!/bin/bash
# Build UltraWorkspace.app and package it into a distributable DMG
# (app + Applications shortcut + manual).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

./packaging/make-app.sh release

STAGE="$ROOT/dist/dmg-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$ROOT/dist/UltraWorkspace.app" "$STAGE/UltraWorkspace.app"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/MANUAL.md" "$STAGE/Manual.md"

# Best-effort readable PDF of the manual.
if command -v cupsfilter >/dev/null 2>&1; then
    cupsfilter -i text/plain "$ROOT/MANUAL.md" > "$STAGE/Manual.pdf" 2>/dev/null || rm -f "$STAGE/Manual.pdf"
fi

cat > "$STAGE/Read Me First.txt" <<'TXT'
UltraWorkspace for Mac
======================

1. Drag UltraWorkspace onto the Applications folder.
2. First launch: right-click UltraWorkspace in Applications -> Open -> Open.
   (It's an unsigned community app; you only approve it once.)
3. Press Scan, then Pair with your CoreBar and tap Approve on the device.

See Manual.pdf / Manual.md for full instructions, including which USB port to use.
Community software. Not affiliated with Sanytron.
TXT

DMG="$ROOT/dist/UltraWorkspace.dmg"
rm -f "$DMG"
hdiutil create -volname "UltraWorkspace" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "done: $DMG ($(du -h "$DMG" | cut -f1))"
