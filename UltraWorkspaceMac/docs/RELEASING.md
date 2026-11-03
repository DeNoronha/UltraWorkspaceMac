# Releasing Deckhand

Distribution is via **GitHub Releases** (a DMG + the source). `make-app.sh` signs with the Developer ID Application identity when one is in the keychain (hardened runtime, timestamp) and `make-dmg.sh` then notarizes and staples the DMG; on a machine without the identity the build is ad-hoc-signed and users must right-click → Open once.

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
  --notes "Signed with a Developer ID and notarized — opens without a Gatekeeper warning."
```

## Signing & notarization (set up 2026-11-01, automatic in the scripts)

1. `packaging/make-app.sh` picks the first `Developer ID Application: …` identity from the keychain (`security find-identity`) and signs with `--options runtime --timestamp`; override with `DECKHAND_SIGN_IDENTITY="Developer ID Application: …"`, or force ad-hoc with `DECKHAND_SIGN_IDENTITY=-`.
2. `packaging/make-dmg.sh` signs the DMG with the same identity and, when notary credentials exist under the keychain profile `deckhand-notary` (override with `DECKHAND_NOTARY_PROFILE`), runs `xcrun notarytool submit --wait`, staples the ticket and checks it with `spctl`. One-time setup: `xcrun notarytool store-credentials "deckhand-notary" --apple-id <apple-id> --team-id <TEAMID> --password <app-specific-password>`.
3. Releases built this way install with no Gatekeeper warning; the DMG's "Read Me First" says so. Without the identity or the credentials the script says why it did not notarize.

Gotcha in these scripts: never pipe `codesign … | grep -q` under `pipefail` — SIGPIPE makes codesign exit 141 and the test silently fails.

Privacy usage descriptions to keep in mind for a signed build: local network (CoreBar discovery/control), Apple Events / Automation (Music), Calendar, Location (weather). These are the `NS…UsageDescription` strings declared in `packaging/Info.plist`; a Developer-ID (non-sandboxed) build needs no extra entitlements beyond the hardened runtime, but a future Mac App Store build would need sandbox entitlements (outgoing network, Apple Events, Calendar), and sandboxing may restrict local-network + Process use.

## Versioning

Bump `CFBundleShortVersionString` / `CFBundleVersion` in `packaging/Info.plist` before tagging. The About panel reads these at runtime.
