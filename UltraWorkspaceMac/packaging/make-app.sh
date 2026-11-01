#!/bin/bash
# Build UltraWorkspace.app (a double-clickable macOS app) from the Swift package.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/dist/UltraWorkspace.app"
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

echo "==> ad-hoc codesign (so Keychain + local network work)"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "   (codesign skipped)"

echo "==> done: $APP"
echo "   open it with:  open \"$APP\""
