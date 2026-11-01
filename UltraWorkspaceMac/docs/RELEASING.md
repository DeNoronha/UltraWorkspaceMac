# Releasing Deckhand

Distribution is via **GitHub Releases** (a DMG + the source). Until a Developer ID is in place, builds are ad-hoc-signed and users must right-click → Open once; after notarization that warning goes away.

## Release ONLY to origin — never to upstream

> **Rule:** releases, tags and branches go to **`origin` = `DeNoronha/UltraWorkspaceMac`** and nowhere else. The `upstream` remote (`Qinkunex/UltraWorkspace`) is the **vendor's** repository, cloned for reference. **Never** push tags or branches there and **never** create releases on it. Always pass `--repo DeNoronha/UltraWorkspaceMac` to `gh` so it cannot pick the wrong remote. As a safeguard the push URL of `upstream` has been set to `DISABLED` (`git remote set-url --push upstream DISABLED`); check with `git remote -v` before you push.

## Build the artifacts

```sh
bash packaging/make-app.sh          # runs `swift build -c release` itself -> dist/Deckhand.app
bash packaging/make-dmg.sh          # calls make-app.sh release, then -> dist/Deckhand.dmg
```

`make-dmg.sh` already rebuilds the app, so for a release the single `bash packaging/make-dmg.sh` is enough.

## Cut a GitHub release

```sh
git remote -v                        # upstream must show "DISABLED (push)"
VER=0.1.0
git tag -a "v$VER" -m "Deckhand v$VER"
git push origin "v$VER"              # origin only
gh release create "v$VER" dist/Deckhand.dmg \
  --repo DeNoronha/UltraWorkspaceMac \
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

Privacy usage descriptions to keep in mind for a signed build: local network (CoreBar discovery/control), Apple Events / Automation (Music), Calendar, Location (weather). These are the `NS…UsageDescription` strings declared in `packaging/Info.plist`; a Developer-ID (non-sandboxed) build needs no extra entitlements beyond the hardened runtime, but a future Mac App Store build would need sandbox entitlements (outgoing network, Apple Events, Calendar), and sandboxing may restrict local-network + Process use.

## Versioning

Bump `CFBundleShortVersionString` / `CFBundleVersion` in `packaging/Info.plist` before tagging. The About panel reads these at runtime.
