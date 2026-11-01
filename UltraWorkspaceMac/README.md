# Deckhand — a native macOS client for UltraBar X

A native, open macOS client for Sanytron **UltraBar X** hardware (CoreBar + QuantumLink modules: VivoCube, SenseCube, KnobKey, DotKey, PC-Boot card). Built in Swift/SwiftUI, with no .NET or Qt runtime. The long-term goal is a full replacement for the official UltraWorkSpace desktop app on macOS.

This is independent, community software. Not affiliated with or endorsed by Sanytron. Repository: https://github.com/DeNoronha/UltraWorkspaceMac

> Naming: the user-facing app is **Deckhand** (`dist/Deckhand.app`, `dist/Deckhand.dmg`). The repository (`UltraWorkspaceMac`), the Swift targets (`UltraWorkspaceApp`, `UltraBarKit`, `kitcheck`) and the bundle id (`com.denoronha.ultraworkspacemac`) deliberately keep their original names.

## Before you plug it in — read this first

The CoreBar has **two** USB ports and they are not interchangeable. Getting this wrong can destroy the unit.

| Port | Use it for | Rule |
|------|------------|------|
| **USB-OTG** | **Power / charging** — a fast charger (PD / QC, 9–20 V) or the 12 V adapter. | Fast charging is OK here. |
| **PC-LINK** | **Connecting to your computer** (and 5 V power from the computer). | **5 V only.** A computer's USB port or a plain 5 V adapter. |

> ⚠️ **Never plug a phone/MacBook/laptop PD fast-charger into PC-LINK.** PC-LINK is 5 V-only; a 9–20 V charger will permanently damage the mainboard and can overheat. Connecting PC-LINK to a **computer USB port is safe and correct** — that's what it's for.

Deckhand talks to the CoreBar over **Wi-Fi / your LAN**, not over USB; the cable only provides power. The same guidance is shown in-app (Settings → Connecting) and in `MANUAL.md`.

## Hardware it talks to

- **CoreBar** — the hub: a 5:1 ultrawide touch display (1424 × 280), running LineOS (an Android variant), with a built-in speaker and PC-monitoring. Everything this app does goes through the CoreBar, which relays to its attached modules.
- **QuantumLink modules** — magnetic snap-on units on the CoreBar's bus: **VivoCube** (2.0" round AMOLED, 240 × 240), **SenseCube** (sensors), **KnobKey** (rotary encoder), **DotKey** (key array), and the **PC-Boot card**.

## Status — what works today

**Device connection**
- **Discovery** — finds CoreBars on the LAN over UDP broadcast (port 5319, probe `{"act":"discover"}`, 8 s scan).
- **Add CoreBar by IP** — sidebar → CoreBars → **Add by IP…** sends the same discovery probe as a unicast to one address. Use it when broadcast can't reach the device (other subnet, VPN, or the mock CoreBar running in Docker — see *Testing without hardware*).
- **Pairing** — pairs with a CoreBar (`REQ_AUTH_TOKEN` / act 101); the user taps *Approve* on the CoreBar within ~30 s and a token comes back. The token is stored in a `0600` file in Application Support (not the Keychain — see Limitations). The CoreBar's self-signed certificate is pinned on first use (trust-on-first-use); a later certificate mismatch aborts *before* the token is ever sent.
- **Control channel** — one TLS connection per operation (line-delimited JSON, port 7431, SNI `ultrabar.local`; the device negotiates TLS 1.3, the client allows ≥ 1.2).

**Module enumeration & provisioning**
- **Module listing** — the app first tries the gateway-config read (`GET_COREBAR_CONFIG` 30740 with `{type:"GATEWAY_CONFIG"}`, which returns null on the firmware tested but is kept for firmwares that answer), then runs a **live bus scan**: it fires `MODULE_START_DISCOVERY` (act 30100) on both buses (`"can"` for the magnetic QuantumLink bus, `"mesh"` for wireless) and collects the `MODULE_START_DISCOVERY_REPLAY` (act 30102) messages the CoreBar pushes back, one per found module. Only if that finds nothing does it fall back to `GET_DEVICE` (1300, logical/integration devices). On the tested firmware the scan is the source of truth.
- **Provisioning** — to make modules controllable the app writes the discovered endpoints into the gateway config with `SET_GATEWAY_CONFIG` (act 30300; the message body *is* the CoreBar configuration). The older `SET_COREBAR_CONFIG` (30741) is not used — it fails server-side with a `ClassCastException` on the tested firmware.
- **Asleep-module merge** — each provision merges freshly-discovered modules with the set last written to that CoreBar, so a module that happens to be asleep during a scan (often the DotKey) is not dropped from the config. The cache lives at `~/Library/Application Support/UltraWorkspaceMac/endpoints/<serial>.json` and is restored when the app launches, so the module list is there before the first scan.
- **Auto-provision on upload** — if an image push is rejected with "module not found", the app provisions once and retries automatically.

**VivoCube widgets**
Each widget renders a 240 × 240 image on the Mac, which is encoded to the module pixel format and pushed over HTTP. Widgets can be published one at a time or rotated at a configurable interval (15 s – 3 min). All 13 ship today (`Theme.swift`):
- **Weather & time** — Open-Meteo (free, no API key). Location fallback order: macOS Location → the manual city/coordinates you entered → IP geolocation (ipwho.is).
- **Music (album art)** — album art plus title/artist from Music.app.
- **Claude Code monitor** — tokens used today and active sessions, read from `~/.claude`.
- **CPU & memory**, **Network**, **Disk I/O**, **Top CPU**, **Uptime** (with load average).
- **Battery & power**, **Storage**.
- **World clock** (Amsterdam / New York / Tokyo), **Calendar** (next events; needs Calendar access), **Crypto ticker** (BTC/ETH via CoinGecko, no API key).

**CoreBar big screen (1424 × 280)**
- **One-shot preview works**: the CoreBar page's **"Show this on the CoreBar screen now"** uploads a 1424 × 280 PNG in a zip (`POST /upload/zip`) and shows it with `PREVIEW_SCREENSAVER` (30742). It is non-destructive — it changes no saved pages — and currently renders the weather-only wide layout.
- **Not yet**: persistent pages/wallpaper and widget rotation on the big screen (needs `BATCH_SAVE_PROFILE` 1108, which replaces the whole profile list). The CoreBar rotation controls are present but disabled.

**Image push**
Pick any image (or let a widget render one); it is encoded to RGB565 (plus an alpha byte per pixel when the image isn't fully opaque) with an 8-byte header, wrapped in a ustar tar + gzip "deploy package", and POSTed to `http://<corebar>:8080/upload?serialNo=<serial>` as multipart form data. A successful push returns `{"state":200,"msg":"ok"}`.

**SenseCube** — temperature, humidity and ambient light are read live over the protocol (`MODULE_PROPERTY_READ` 30200, polled every 5 s on the SenseCube page). Presence, sound and vibration are event-only on the device and are not readable over the protocol.

**Apple Music remote (runs on the Mac)** — in **Widgets → Music (album art)**: play/pause, next, previous, volume ±, live now-playing, and publishing the album-art widget to a VivoCube.

**People — per-person quick actions** — save contacts; each gets one-tap **Teams chat**, **Teams call**, **FaceTime**, and **Mail** (via deep links). Stored locally.

> First use of the Music controls triggers a macOS **Automation** permission prompt (to control Music.app) — allow it. First scan triggers a **Local Network** prompt — allow it, or the Mac can't see the CoreBar.

## The app at a glance

Deckhand is a single window with a sidebar:

- **CoreBars** — discovered and paired CoreBars, **Scan for CoreBars**, **Add by IP…**.
- **Device section** (the selected CoreBar) — **Overview** (big-screen preview, CoreBar rotation placeholder, module list, activity log, **Refresh / set up**) and one page per module: **VivoCube** (screen on/off, reboot, widget rotation, custom image), **SenseCube** (live readings), **KnobKey** and **DotKey** (info-only for now).
- **Configure** — **Widgets** (per-widget settings, including weather location/units and the Music transport), **People**, **Logs** (every Mac↔CoreBar message, token redacted).
- **About Deckhand** at the bottom of the sidebar; the **Settings** gear (toolbar) holds the CoreBar summary, the connection/USB-port guidance, and what has to be set on the CoreBar itself.

## Build & run

Requirements: macOS 13+ to run, a Swift 6 toolchain to build. This project is built with **Swift + the Command-Line Tools only** (no Xcode.app required). On macOS 26 and later the app adopts Liquid Glass styling; on older macOS it falls back to the standard system materials.

```bash
cd UltraWorkspaceMac
swift build                               # compile everything
swift run UltraWorkspaceApp               # run from the build tree (development)

bash packaging/make-app.sh release        # produces dist/Deckhand.app
open dist/Deckhand.app

bash packaging/make-dmg.sh                # produces dist/Deckhand.dmg (app + Applications shortcut + manual)
```

First launch: press **Scan**, then **Pair** next to your CoreBar and tap *Approve* on the CoreBar within 30 seconds. macOS may ask once for **Local Network** permission — allow it.

Widgets and custom images are rendered at 240 × 240 for the VivoCube (`AppModel.canvasSize`); there is no user-facing canvas setting at the moment.

## Testing without hardware

`mock-corebar/` is a Node/TypeScript emulator of the CoreBar (UDP discovery, TLS control, HTTP upload, plus a web viewer that shows what you uploaded). See [`mock-corebar/README.md`](mock-corebar/README.md).

```bash
cd mock-corebar && npm install && npm run dev     # or: docker compose up --build
# ports: 5319/udp discovery, 7431 TLS control, 8080 upload, 8081 viewer (http://127.0.0.1:8081)
```

- With Docker on macOS, UDP broadcast doesn't cross Docker's NAT, so in Deckhand use **CoreBars → Add by IP… → 127.0.0.1**. Running natively (`npm run dev`) supports broadcast discovery.
- The mock auto-approves pairing after about 1 s (a real device waits for you to tap Approve within 30 s).
- `kitcheck e2e` drives the whole UltraBarKit protocol path against the mock and exits non-zero on any failure (see *Project layout*).

## Limitations

- **Ad-hoc code signing only.** Because the build uses the Command-Line Tools and not a full Xcode.app with a paid Apple Developer certificate, the app is ad-hoc signed. There is no Developer ID signature and no notarization yet, so the first launch needs the right-click → Open gesture (see the manual). A notarized release is on the roadmap.
- **Token stored in a file, not the Keychain.** An ad-hoc-signed app gets a new code signature on every rebuild, which makes the Keychain re-prompt for the login password on every launch. Storing the token in a `0600` file under `~/Library/Application Support/UltraWorkspaceMac/tokens/` avoids that friction. For a notarized / Developer-ID release this can move back to the Keychain.

## Network endpoints this app contacts

Deckhand talks to the following hosts and nothing else (no telemetry, no account):

- **Your CoreBar on the LAN** — UDP 5319 (discovery), TCP 7431 (TLS control), TCP 8080 (HTTP upload).
- `api.open-meteo.com` and `geocoding-api.open-meteo.com` — weather and city lookup (Weather widget).
- `ipwho.is` — approximate location from your public IP, only when macOS Location is unavailable and no manual city is set.
- `api.coingecko.com` — BTC/ETH prices (Crypto widget).

Teams / FaceTime / Mail actions on the People page open deep links in the respective apps; Deckhand itself makes no request to those services.

## Project layout

- `Sources/UltraBarKit` — the reusable, UI-free protocol layer:
  - `Models` — protocol constants (`Proto`): ports, act codes, property ids, QuantumLink product ids, and the `CoreBar` / `AttachedModule` types.
  - `Discovery` — UDP LAN discovery (broadcast `listen` and unicast `probe(ip:)` for Add-by-IP).
  - `CoreBarClient` — one TLS control connection; line-delimited JSON; pairing, auth, request/reply correlation; TOFU certificate pinning.
  - `CoreBarSession` — high-level operations over fresh connections: module listing, provisioning (`SET_GATEWAY_CONFIG`), property read/write, screen/reboot, SenseCube reads, the module HTTP upload, and the big-screen zip upload + preview.
  - `DeviceImage` — image → RGB565(+alpha) encoder.
  - `DeployPackager` — ustar + gzip deploy-package builder.
  - `ZipWriter` — minimal zip writer for the big-screen `/upload/zip` route.
  - `Store` — file-based token store plus per-CoreBar metadata (cert pin, last IP) and the gateway-endpoint cache, all in Application Support.
  - `OpenMeteo`, `SystemStats`, `NetworkStats`, `ClaudeUsage` — data sources for the widgets.
  - `WireLog` — captures all Mac↔CoreBar protocol traffic for diagnostics (token redacted).
- `Sources/UltraWorkspaceApp` — the SwiftUI app: `AppModel` and its extensions (`+Music`, `+Themes`, `+Weather`), `ContentView` (sidebar + all pages), `Nav`, `SettingsView`, `AboutView`, `LogsView`, `WeatherPreview`. `Theme` is the widget registry (the 13 widgets, titles, icons).
  - `Widgets/` — the per-widget renderers (`*Card`) and their data sources (`*Stats` / `*Source`): weather, now-playing, stat cards, battery, disk, disk I/O, top CPU, uptime, world clock, calendar, crypto.
  - `Integrations/` — `AppleMusic` (Music.app transport + now-playing), `MacLocation` (CoreLocation), `People` (contacts + deep links).
- `Sources/kitcheck` — a command-line test tool built from the same `UltraBarKit`:
  - `swift build --product kitcheck` then `.build/debug/kitcheck` — known-answer checks for the encoders (CRC32, RGB565 headers, tar/gzip).
  - `.build/debug/kitcheck discover` — an 8 s UDP scan from the terminal.
  - `.build/debug/kitcheck weather <city>` — geocode + current weather via Open-Meteo.
  - `.build/debug/kitcheck e2e [ip]` — end-to-end test against a CoreBar, the mock at `127.0.0.1` by default: unicast probe, pairing, TOFU pin plus mismatch rejection, module scan (4 modules), provision merge, SenseCube readings (23.5 °C / 54 % / 473 lux), 240 × 240 image decode and orientation, big-screen zip + preview, and an unknown act. Takes about 25 s; exits non-zero on failure.
- `mock-corebar/` — the Node/TypeScript CoreBar emulator (see above).
- `packaging/` — `make-app.sh`, `make-dmg.sh`, `Info.plist`, app icon.
- `api/` — machine-readable protocol specs (OpenAPI for `:8080`, AsyncAPI for `:7431`).

The local CoreBar protocol was recovered by decompiling the independent ClickOnce "VivoCube Weather Tool" (a clean .NET reimplementation of the same local protocol), cross-checking the official macOS binary, and reading the LineOS APK. See `PROTOCOL.md`.

## Documentation

- [`MANUAL.md`](MANUAL.md) — the user manual (also shipped inside the DMG).
- [`PROTOCOL.md`](PROTOCOL.md) — the CoreBar local protocol as implemented here, plus what is understood but not yet built.
- [`api/`](api/README.md) — `openapi.yaml` (HTTP `:8080`) and `asyncapi.yaml` (TLS `:7431`) mirroring `PROTOCOL.md`.
- [`docs/ROADMAP.md`](docs/ROADMAP.md) — status, plans, decisions.
- [`docs/WIDGETS.md`](docs/WIDGETS.md) — how widgets work and the community widget format.
- [`docs/SECURITY.md`](docs/SECURITY.md) — security notes about the device and what Deckhand does about them.
- [`docs/RELEASING.md`](docs/RELEASING.md) — building the DMG and cutting a GitHub release.
- [`docs/COLLAB.md`](docs/COLLAB.md) — collaboration notes.
- [`mock-corebar/README.md`](mock-corebar/README.md) — the hardware-free test setup.

## Roadmap

Mirrors [`docs/ROADMAP.md`](docs/ROADMAP.md); that file is authoritative.

**Done**
- Discovery, pairing, TOFU pinning, live bus scan + provisioning with the asleep-module cache, 13 VivoCube widgets with per-device rotation.
- **SenseCube** temperature / humidity / light, live on the SenseCube page.
- **CoreBar big-screen preview** (zip upload + `PREVIEW_SCREENSAVER`), non-destructive.
- The inbound **`PUSH_MESSAGE` (1000000)** path for KnobKey/DotKey is mapped in `PROTOCOL.md` (the device pushes semantic `SET_VOLUME` / `PC_CONTROL` messages once a control is bound to a PC target in the profile).

**Pending**
- **CoreBar pages / wallpaper / widget rotation** on the big screen via `BATCH_SAVE_PROFILE` (1108) — needs a safe read-modify-write of the full profile list; wide layouts for widgets other than weather.
- **KnobKey → volume** and **DotKey → Mac actions** — understood, not implemented; both need the profile-write path above and a listener for act 1000000.
- **Presence → wake** via an on-device scene (`BATCH_CREATE_SCENE`) — understood, not implemented.
- **Module OTA firmware flashing** (`.bin`, `MODULE_OAT_*`).
- A Stream-Deck-style **widget marketplace** (web/TypeScript widget format, see `docs/WIDGETS.md`), and a notarized / Developer-ID signed release.

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
