# Releasing Deckhand

Distribution is via **GitHub Releases** (a DMG + the source). Until a Developer ID is in place, builds are ad-hoc-signed and users must right-click → Open once; after notarization that warning goes away.

## Build the artifacts

```sh
swift build -c release
bash packaging/make-app.sh          # -> dist/Deckhand.app
bash packaging/make-dmg.sh          # -> dist/Deckhand.dmg
```

## Cut a GitHub release

```sh
VER=0.1.0
git tag -a "v$VER" -m "Deckhand v$VER"
git push origin "v$VER"
gh release create "v$VER" dist/Deckhand.dmg \
  --title "Deckhand v$VER" \
  --notes "First public build. Ad-hoc signed: right-click → Open on first launch."
```

## Signing & notarization (once the Apple Developer ID for DNC is active)

1. In `packaging/make-app.sh`, replace the ad-hoc `codesign --sign -` with the Developer ID Application identity, with hardened runtime:
   `codesign --force --deep --options runtime --sign "Developer ID Application: <DNC name> (<TEAMID>)" "$APP"`
2. Notarize the DMG and staple:
   `xcrun notarytool submit dist/Deckhand.dmg --keychain-profile <profile> --wait`
   `xcrun stapler staple dist/Deckhand.dmg`
3. Then releases install with no Gatekeeper warning.

Entitlements to keep in mind for a signed build: outgoing network (weather/crypto/geolocation), local network (CoreBar discovery/control), Apple Events (Music), Calendar. These are declared in `packaging/Info.plist`; a Developer-ID (non-sandboxed) build needs no extra entitlements, but a future Mac App Store build would (and sandboxing may restrict local-network + Process use).

## Versioning

Bump `CFBundleShortVersionString` / `CFBundleVersion` in `packaging/Info.plist` before tagging. The About panel reads these at runtime.
