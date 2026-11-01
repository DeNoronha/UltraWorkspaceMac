# UltraWorkspace for Mac

A native, open macOS client for Sanytron **UltraBar X** hardware (CoreBar + QuantumLink modules: VivoCube, SenseCube, KnobKey, DotKey). Built in Swift/SwiftUI, with no .NET or Qt runtime. The long-term goal is a full replacement for the official UltraWorkSpace desktop app on macOS.

This is independent, community software. Not affiliated with Sanytron.

## Status — v0.2

What works today:

**Device**
- **Discovery** — finds CoreBars on the LAN (UDP broadcast, port 5319).
- **Pairing** — pairs with a CoreBar (tap *Approve* on the device) and stores the token in the macOS **Keychain**. The CoreBar's self-signed certificate is pinned on first use (trust-on-first-use); a later certificate mismatch aborts *before* the token is sent.
- **Module list** — lists attached VivoCubes with their uptime.
- **Display control** — screen on/off, reboot.
- **Image push** — pick any image, it is rendered to the module's pixel format (RGB565, +alpha when needed) and uploaded as the device's `tgz` layer package.

**Music tab — Apple Music remote (runs on the Mac)**
- Transport: play/pause, next, previous, volume ±.
- Live now-playing (title / artist / album), polled from Music.app.
- **Push now-playing to a VivoCube**: album art + track are composed into a card on the Mac and pushed to the selected module; optional auto-update when the track changes.

**People tab — per-person quick actions**
- Save contacts; each gets one-tap **Teams chat**, **Teams call**, **FaceTime**, and **Mail** (via deep links). Stored locally.

The byte-level formats (image encoding, tar+gzip packaging) are verified against known-answer tests — run `swift run kitcheck` (all pass).

> First use of the Music tab triggers a macOS **Automation** permission prompt (to control Music.app) — allow it.

## Build & run

Requirements: macOS 13+, Swift 6 toolchain (Xcode or Command-Line Tools).

```bash
cd UltraWorkspaceMac
./packaging/make-app.sh release     # produces dist/UltraWorkspace.app
open dist/UltraWorkspace.app
```

Or for development: `swift run UltraWorkspaceApp`.

First launch: press **Scan**, then **Pair** next to your CoreBar and tap *Approve* on the device within 30 seconds. macOS may ask once for **Local Network** permission — allow it, or the Mac can't see the CoreBar.

If a pushed image looks wrong on the cube, try a different **Canvas** size — the VivoCube's native resolution isn't published, so the correct value is found by trying (240–480 px).

## Architecture

- `Sources/UltraBarKit` — the reusable, UI-free protocol layer:
  - `Discovery` — UDP LAN discovery.
  - `CoreBarClient` — one TLS control connection; line-delimited JSON; pairing, auth, request/response correlation; TOFU certificate pinning.
  - `CoreBarSession` — high-level operations (list modules, read/write properties, reboot, upload) over fresh connections.
  - `DeviceImage` — image → RGB565(+A) encoder.
  - `DeployPackager` — ustar + gzip layer-package builder.
  - `Store` — Keychain tokens + per-CoreBar metadata (cert pin, last IP).
- `Sources/UltraWorkspaceApp` — the SwiftUI app (`AppModel`, `ContentView`).
- `Sources/kitcheck` — known-answer checks for the encoders.

The local CoreBar protocol was recovered by decompiling the independent ClickOnce "VivoCube Weather Tool" (a clean .NET reimplementation of the same local protocol) and cross-checking the official macOS binary. See `PROTOCOL.md`.

## Roadmap toward a full replacement

**Stream Deck-style action model (in progress).** A button on a VivoCube (or a
row in the app) triggers an *action* that runs on the Mac. Apple Music and the
per-person Teams/FaceTime/Mail actions are the first providers. Next:

- **Inbound button events** — the one missing protocol piece for true
  interactivity: the `act` code the CoreBar sends when a VivoCube/DotKey is
  pressed. Until it's mapped (from the LineOS APK), actions fire from the Mac UI,
  not yet from a physical press. Once mapped: click/double-click/long-press and
  KnobKey rotation bind to actions.
- **Microsoft Teams mute/unmute** — via Teams' local *Third-party app API*
  (`ws://localhost:8124`, user enables it in Teams settings and approves a
  pairing token). Also toggle camera, raise hand, leave.
- **Action catalog / marketplace** — a registry of installable action providers
  (media, app shortcuts, hotkeys, smart-home, web), so actions that also exist on
  a Stream Deck can run here.
- **Hotkey + app-shortcut actions** — post key combos / launch apps / open URLs.

**Device & UI**
- Widget/layer designer (up to 6 layers × 3 slots per VivoCube).
- KnobKey / DotKey binding (rotation, press/double/long, macros).
- SenseCube sensors (humidity, light, radar, sound) + automations.
- Module OTA firmware flashing (`.bin`).
- Smart-home: Home Assistant, Sonos/Spotify (CoreBar runs these locally via LineOS).
- App marketplace / icon browser (cloud backend `aiks360.com`).
- Project persistence (the official app stores projects in a local SQLite DB).

## License

See the repository `LICENSE`.
