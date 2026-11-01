# UltraWorkspace for Mac

A native, open macOS client for Sanytron **UltraBar X** hardware (CoreBar + QuantumLink modules: VivoCube, SenseCube, KnobKey, DotKey, PC-Boot card). Built in Swift/SwiftUI, with no .NET or Qt runtime. The long-term goal is a full replacement for the official UltraWorkSpace desktop app on macOS.

This is independent, community software. Not affiliated with Sanytron.

## Hardware it talks to

- **CoreBar** — the hub: a 5:1 ultrawide touch display (1424 × 280), running LineOS (an Android variant), with a built-in speaker and PC-monitoring. Everything this app does goes through the CoreBar, which relays to its attached modules.
- **QuantumLink modules** — magnetic snap-on units on the CoreBar's bus: **VivoCube** (2.0" round AMOLED, 240 × 240), **SenseCube** (sensors), **KnobKey** (rotary encoder), **DotKey** (key array), and the **PC-Boot card**.

## Status — what works today

**Device connection**
- **Discovery** — finds CoreBars on the LAN over UDP broadcast (port 5319, probe `{"act":"discover"}`).
- **Pairing** — pairs with a CoreBar (`REQ_AUTH_TOKEN` / act 101); the user taps *Approve* on the CoreBar within ~30 s and a token comes back. The token is stored in a `0600` file in Application Support (not the Keychain — see Limitations). The CoreBar's self-signed certificate is pinned on first use (trust-on-first-use); a later certificate mismatch aborts *before* the token is ever sent.
- **Control channel** — one TLS connection per operation (line-delimited JSON, port 7431, SNI `ultrabar.local`).

**Module enumeration & provisioning**
- **Live bus scan** — enumerating modules is a real scan, not a config read: the app fires `MODULE_START_DISCOVERY` (act 30100) on both buses (`"can"` for the magnetic QuantumLink bus, `"mesh"` for wireless) and collects the `MODULE_START_DISCOVERY_REPLAY` (act 30102) messages the CoreBar pushes back, one per found module. On this firmware the static config reads (`GET_DEVICE` 1300, `QUERY_MODULE_STATE` 30730, `GET_COREBAR_CONFIG` 30740) come back empty, so the scan is the source of truth.
- **Provisioning** — to make modules controllable the app writes the discovered endpoints into the gateway config with `SET_GATEWAY_CONFIG` (act 30300; the message body *is* the CoreBar configuration). The older `SET_COREBAR_CONFIG` (30741) is not used — it fails server-side with a `ClassCastException`.
- **Asleep-module merge** — each provision merges freshly-discovered modules with the set last written to that CoreBar (cached per CoreBar in Application Support), so a module that happens to be asleep during a scan (often the DotKey) is not dropped from the config.
- **Auto-provision on upload** — if an image push is rejected with "module not found", the app provisions once and retries automatically.

**VivoCube widgets (cards)**
Each card renders a 240 × 240 image on the Mac, which is encoded to the module pixel format and pushed over HTTP. Cards can be shown one at a time or rotated on a carousel at a configurable interval. Shipping cards:
- **Weather & time** — Open-Meteo (free, no API key), with an IP-geolocation fallback when macOS Location access is unavailable.
- **Music / now-playing** — album art plus title/artist from Music.app.
- **Claude Code usage monitor**.
- **CPU & memory**.
- **Network up/down**.

New / experimental cards (rendering in place, being wired into the rotation):
- **Battery**.
- **Storage / Disk**.
- **World Clock**.
- **Calendar / next event**.
- **Crypto ticker** (planned).

**Image push**
Pick any image (or let a card render one); it is encoded to RGB565 (plus an alpha byte per pixel when the image isn't fully opaque) with an 8-byte header, wrapped in a ustar tar + gzip "deploy package", and POSTed to `http://<corebar>:8080/upload?serialNo=<serial>` as multipart form data. A successful push returns `{"state":200,"msg":"ok"}`.

**Music tab — Apple Music remote (runs on the Mac)**
- Transport: play/pause, next, previous, volume ±.
- Live now-playing (title / artist / album), polled from Music.app.
- Push the now-playing card to a VivoCube; optional auto-update when the track changes.

**People tab — per-person quick actions**
- Save contacts; each gets one-tap **Teams chat**, **Teams call**, **FaceTime**, and **Mail** (via deep links). Stored locally.

The byte-level formats (image encoding, tar + gzip packaging) are verified against known-answer tests — run `swift run kitcheck` (all pass).

> First use of the Music tab triggers a macOS **Automation** permission prompt (to control Music.app) — allow it. First scan triggers a **Local Network** prompt — allow it, or the Mac can't see the CoreBar.

## Build & run

Requirements: macOS 13+, a Swift 6 toolchain. This project is built with **Swift + the Command-Line Tools only** (no Xcode.app required).

```bash
cd UltraWorkspaceMac
swift build                               # compile everything
swift run UltraWorkspaceApp               # run from the build tree (development)

bash packaging/make-app.sh release        # produces dist/UltraWorkspace.app
open dist/UltraWorkspace.app

bash packaging/make-dmg.sh                # produces dist/UltraWorkspace.dmg (app + Applications shortcut + manual)
```

First launch: press **Scan**, then **Pair** next to your CoreBar and tap *Approve* on the CoreBar within 30 seconds. macOS may ask once for **Local Network** permission — allow it.

If a pushed image looks wrong on the cube, try a different **Canvas** size in the app — the VivoCube renders at 240 × 240, but on some firmware a slightly different source size composites better.

## Limitations

- **Ad-hoc code signing only.** Because the build uses the Command-Line Tools and not a full Xcode.app with a paid Apple Developer certificate, the app is ad-hoc signed. There is no Developer ID signature and no notarization yet, so the first launch needs the right-click → Open gesture (see the manual). A notarized release is on the roadmap.
- **Token stored in a file, not the Keychain.** An ad-hoc-signed app gets a new code signature on every rebuild, which makes the Keychain re-prompt for the login password on every launch. Storing the token in a `0600` file in the user's Application Support directory avoids that friction. For a notarized / Developer-ID release this can move back to the Keychain.

## Project layout

- `Sources/UltraBarKit` — the reusable, UI-free protocol layer:
  - `Models` — protocol constants (`Proto`): ports, act codes, property ids, QuantumLink product ids, and the `CoreBar` / `AttachedModule` types.
  - `Discovery` — UDP LAN discovery.
  - `CoreBarClient` — one TLS control connection; line-delimited JSON; pairing, auth, request/reply correlation; TOFU certificate pinning.
  - `CoreBarSession` — high-level operations over fresh connections: module scan, provisioning (`SET_GATEWAY_CONFIG`), property read/write, screen/reboot, and the HTTP upload.
  - `DeviceImage` — image → RGB565(+alpha) encoder.
  - `DeployPackager` — ustar + gzip deploy-package builder.
  - `Store` — file-based token store plus per-CoreBar metadata (cert pin, last IP) and the gateway-endpoint cache, all in Application Support.
  - `OpenMeteo`, `SystemStats`, `NetworkStats`, `ClaudeUsage` — data sources for the cards.
  - `WireLog` — captures all Mac↔CoreBar protocol traffic for diagnostics.
- `Sources/UltraWorkspaceApp` — the SwiftUI app (`AppModel` and its extensions, `ContentView`, settings, logs view). `Theme` and `AppModel+Themes` are the card/carousel system; `Integrations/` holds the per-card renderers (weather, now-playing, stat cards, battery, disk, world clock, calendar) and the Apple Music / Location / People helpers.
- `Sources/kitcheck` — known-answer checks for the encoders.

The local CoreBar protocol was recovered by decompiling the independent ClickOnce "VivoCube Weather Tool" (a clean .NET reimplementation of the same local protocol), cross-checking the official macOS binary, and reading the LineOS APK. See `PROTOCOL.md`.

## Roadmap

**Device / protocol**
- **The CoreBar's own big screen.** Setting the ultrawide display's wallpaper / screensaver — this appears to be profile-bound (likely `BATCH_SAVE_PROFILE`, act 1108) rather than a direct image push, and is not yet mapped.
- **KnobKey → volume** and **DotKey button actions.** These need inbound button/rotation events from the CoreBar over the control channel; the inbound `act` codes still have to be mined from the LineOS APK.
- **SenseCube sensors** (humidity, light, radar, sound) and automations.
- **Module OTA firmware flashing** (`.bin`, `MODULE_OAT_*`).

**App**
- **A Stream-Deck-style widget marketplace** — a registry of installable card/action providers so the VivoCube carousel can be extended without rebuilding the app.
- Finalize the new cards (battery, storage, world clock, calendar, crypto) and the layer/slot designer (the VivoCube supports multiple layers × widget slots).
- A notarized / Developer-ID signed release.

## Ecosystem features (reference / backlog)

What the UltraBar X ecosystem advertises across its sources — the target surface for a full macOS replacement. Compiled from the Kickstarter campaign, the Sanytron support hub, the GitHub release notes, press coverage, and the bundled docs. Treat vendor marketing claims as claims, not verified behaviour.

**Hardware**
- **CoreBar** — main hub, 5:1 ultra-wide high-res touch display, 45° tilt, built-in speaker, real-time PC monitoring (CPU/memory), macro engine. 199 × 50.4 × 59.6 mm, 250 g. Runs **LineOS** and works independently of the PC.
- **QuantumLink™** magnetic bus — instant attach + auto-detect, up to **15 mixed modules**.
- **VivoCube** — 2.0" programmable AMOLED, mechanical switch, gestures, own power, daisy-chains up to 3, mini-controller or secondary display.
- **SenseCube** — mmWave radar presence + ambient light, temperature, humidity, vibration; drives scene automation and desk-tap triggers.
- **KnobKey** — metal rotary encoder, tactile steps, per-app/scene actions (volume, brush size, scrub, zoom).
- **DotKey** — Cherry MX key array; single/double/long press, macro chains with ms delays.
- Ports/power: USB-C (power+data) + 12 V DC on CoreBar; **PC-LINK** (5 V only — never a PD charger) and **USB-OTG** (fast charge); optional **Wireless Boot Module** (Bluetooth-Mesh / PCIe card) for BIOS-level PC wake.

**Software (official UltraWorkSpace + LineOS)**
- Positioned as "**Stream Deck + macro keyboard + secondary display**, combined" — a highly customizable macro/shortcut engine plus real-time PC monitoring (CPU/memory).
- Profiles, multi-layer VivoCube canvas (up to 6 layers × 3 widget slots), widgets (clock, gauges, image/GIF, humidity/light/radar/sound, WebUI).
- **SceneShift™ AI** — context-aware engine that adapts layouts/controls to the active app/workflow.
- **Voice Assistant** (added during the campaign) — voice commands to adjust lighting, trigger scenes, switch work modes, check system performance, launch apps.
- Mesh device search/pair/replace incl. boot cards; automations with third-party app actions; app marketplace (install/update/uninstall).
- **Nexus Store** — 90+ platform integrations, 300+ ready templates (icons, animations, interaction logic).
- OTA firmware flashing for modules (`.bin`); open **SDK** for plugins/scenes/integrations (developer program).
- Macro editing from phone or PC: Windows, iOS, Android; **macOS "already in the lab"** (official Mac install page: `ultrabarx.sanytron.com/mac/mac.htm`). This project aims to go further than a config app.

**Four transport "protocol bridges" (CoreBar)** — important for a Mac client:
- **USB / HID** — USB-C plug & play, no drivers, "compatible with Windows, macOS, Linux." The CoreBar presents as a standard HID device, so button macros can arrive as keystrokes, and the host app feeds it PC stats. (USB identity seen in the weather tool: `VID_1F3A&PID_2000`, via a USB serial/PC-LINK channel.)
- **IP Network** — the TLS JSON channel this app uses (see `PROTOCOL.md`).
- **Bluetooth Mesh** — wireless device management + one-tap PC wake (boot module / PCIe card).
- **QuantumLink™** — the magnetic module bus between CoreBar and modules.

Physical, device-level facts: ABS+PC shell, N52 magnetic cores, 0.3 s magnetic reconfigure, 45° tilt, colours Green/Gold/Black. Campaign: 810 backers, HK$2.73M pledged, ships Apr 2026; shown at Eletrolar Show Brazil and IFA Berlin; team based in Shenzhen.

**Integrations named across sources**
- Smart home: Home Assistant, Apple HomeKit (via HA), Philips Hue.
- Media: SONOS, Spotify (album art, volume, transport), Apple Music (this app).
- Work/creator/gaming: Microsoft Teams, Discord, OBS, Photoshop, VS Code, PS5.
- PC wake: Wake-on-LAN (Ethernet) or simulated USB key-press (Wi-Fi-only); remote power-on via Home Assistant or the boot module.

**The independent "VivoCube Weather Tool"** (`ultrabar-weather.pages.dev`) — a community ClickOnce app that pushes a live weather display to VivoCubes; its clean .NET reimplementation is the main source for the local protocol in `PROTOCOL.md`. Uses Open-Meteo, OpenStreetMap/Nominatim, RainViewer, and Aviation Weather for data.

## Links & sources

**Official / vendor**
- Support hub: https://hub.sanytron.com/support/ultrabarx
  - Getting started: https://hub.sanytron.com/support/ultrabarx/getting-started
  - Troubleshooting: https://hub.sanytron.com/support/ultrabarx/troubleshooting
  - Release notes: https://hub.sanytron.com/support/ultrabarx/release-notes
  - Downloads: https://hub.sanytron.com/support/ultrabarx/downloads
  - Power safety notice: https://hub.sanytron.com/news/corebar-power-safety-notice
- Mac support page: https://ultrabarx.sanytron.com/mac/mac.htm
- Boot module: https://ultrabarx.sanytron.com/bootmodule/
- Forum: https://forum.sanytron.com
- Email: support@sanytron.com · bz@sanytron.com
- GitHub repo: https://github.com/Qinkunex/UltraWorkspace
- Release v1.0.1.0: https://github.com/Qinkunex/UltraWorkspace/releases/tag/v1.0.1.0
- Example firmware: https://github.com/Qinkunex/UltraWorkspace/releases/download/v1.0.0/VivoCube_V2_20260728_ota.bin

**Kickstarter campaign**
- https://www.kickstarter.com/projects/ultrabarx/ultrabar-x-future-desktop-revolution-aesthetics-function/description
- Short link: https://ultrabarx-modular-smart-your.kckb.me/cnxsoft

**Community / social**
- Reddit: https://reddit.com/r/Sanytron
- Discord: https://discord.gg/z629RRgHBJ (a second invite, `discord.gg/dh2sQrWTH`, is also listed on the hub)
- YouTube: https://youtube.com/@SanytronHub
- Facebook: https://facebook.com/sanytron.control
- Instagram: https://instagram.com/sanytrontech
- WhatsApp: https://wa.me/+8613823379099

**Independent weather tool**
- https://ultrabar-weather.pages.dev/
- Deployment manifest: https://ultrabar-weather.pages.dev/UltraBarWeather.application
- Author: TheDeveloperIncognito@gmail.com

**Cloud backend used by the official app** (from binary strings — not a developer API)
- API gateway: https://gatewayssl.dev.aiks360.com
  (paths seen: `/api/v1/base-service/pub/apps/100/fetchListV2`, `/icon/tags/locales/allGrouped`, `/icon/v2/page`, `/plugin/page`)
- `sys.widget.io`

**Third-party APIs used by the tooling**
- Open-Meteo: https://api.open-meteo.com/v1/forecast · https://geocoding-api.open-meteo.com/v1/search · https://air-quality-api.open-meteo.com/v1/air-quality
- OpenStreetMap: https://nominatim.openstreetmap.org/ · tiles `https://tile.openstreetmap.org/{z}/{x}/{y}.png`
- RainViewer: https://api.rainviewer.com/public/weather-maps.json
- Aviation Weather (METAR): https://aviationweather.gov/api/data/
- Connectivity check: http://www.msftconnecttest.com/connecttest.txt
- Microsoft Teams deep links (used by this app): https://teams.microsoft.com/l/chat/0/0 · https://teams.microsoft.com/l/call/0/0

**Press coverage**
- New Atlas: https://newatlas.com/electronics/ultrabar-x-modular-command-center/
- CNX-Software: https://www.cnx-software.com/2025/11/27/ultrabar-x-a-high-end-modular-desktop-smart-hub-with-a-51-ultra-wide-touch-display-magnetic-snap-on-modules/
- Notebookcheck: https://www.notebookcheck.com/UltraBar-X-Modulare-Kontrollcenter-mit-Display-Sensorik-und-Smart-Home-Funktionen.1160641.0.html
- appgefahren.de: https://www.appgefahren.de/ultrabar-x-modulare-touch-bar-nicht-nur-fuer-den-schreibtisch-390119.html

## License

See the repository `LICENSE`.
