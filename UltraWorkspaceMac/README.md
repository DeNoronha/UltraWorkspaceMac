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

- **Physical button → Mac action.** Two routes, from the campaign's "four protocol bridges":
  - *HID bridge (works without new protocol knowledge):* when the CoreBar is USB-connected it acts as a standard HID device. Bind a module button to an otherwise-unused keystroke (e.g. F13–F24) in the official config, and have this app register a global hotkey that runs the action (mute Teams, skip track, etc.). This is how most Stream Deck alternatives bridge hardware — a near-term, reliable path.
  - *Networked events:* subscribe to the CoreBar's button-press event over the TLS channel. This needs the inbound `act` code (to be mined from the LineOS APK). Once mapped: click/double-click/long-press and KnobKey rotation bind directly.
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
