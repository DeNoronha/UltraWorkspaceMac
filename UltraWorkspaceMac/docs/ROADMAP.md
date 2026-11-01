# Deckhand — roadmap, ideas & strategy

Deckhand is an independent, native client for the UltraBar X (CoreBar + QuantumLink modules). The vendor's own software is thin, especially on macOS, so Deckhand aims to be the client people actually use. This doc captures the plan and the open questions; it is a living document.

## Status today (works)

- Discovery (UDP :5319), pairing (TLS :7431, tap-Approve, trust-on-first-use cert pinning), token stored in a protected file (no Keychain prompt).
- Live bus scan + provisioning (SET_GATEWAY_CONFIG 30300) with an on-disk module cache that keeps asleep modules (e.g. the DotKey) from being dropped.
- Push widgets to a VivoCube (RGB565 + tar/gzip over HTTP :8080). 13 widgets: weather, music, Claude usage, CPU, network, battery, storage, world clock, crypto, calendar, disk I/O, top CPU, uptime.
- **VivoCube rotation = the vendor's own model (DONE)**: all ticked widgets (max 6) are rendered into one multi-layer package (layer n → widget 100+n), uploaded once, given 10 s to be applied by the module, and then switched every interval by writing property 9 = `(layer<<16)|widget` — no flash rewrite per step; contents are re-uploaded only every few minutes. Images are opaque RGB565 by default (alpha is opt-in; the vendor encoder uses straight alpha, ours is premultiplied). A **Recover display** button (screen on + layer 1/widget 101, after reading the cached properties 4 and 9) handles the "black cube" case the CoreBar's property cache can produce.
- Per-device rotation screens (VivoCube now; CoreBar placeholder), live on-screen widget preview, wire-log, About, MIT license.
- CoreBar big-screen: non-destructive preview implemented and confirmed on hardware (Mac-hosted http image via `PreviewServer` + PREVIEW_SCREENSAVER 30742, which needs an http URL and sends no ack). See PROTOCOL.md.
- The mock CoreBar answers the vendor's `discovery.ultrabar` probe, emulates the property 4/9 cache (including the black-screen case) and captures every upload to `mock-corebar/captures/`, so the official app can be run against it.

## Near-term (next)

- **CoreBar big screen — design pivot after the vendor-client analysis**: there is **no wallpaper and no full-screen image page**. A profile is a strip of fixed-size vendor cards (clock, weather, world time, timer, PC-control buttons, scenes, module cards, system stats…), and the only place for our own image is the **TIME card's cover** (`icon`, ≈540×240 card with a blurred copy behind it). So the plan becomes: Deckhand pages = vendor widgets configured from the Mac (schemas are fully known, see PROTOCOL.md) + our rendered image as the clock cover, written with BATCH_SAVE_PROFILE (1108) and switched with 1103. Policy still to build: keep a local authoritative `profiles.json`, compare the `SCENE_DEPENDS_PROFILE` (30710) id list before every write, always re-send the device's `"default"` profile with an empty TIME icon so the user's on-device choice survives, upload assets only under `subDir=deckhand`, and **warn that running the vendor app's Deploy wipes Deckhand's assets and profiles**. Full-screen output stays one-shot (30742).
- **Wide widget layouts** are therefore clock-cover sized (roughly square to 5:1, small), not 1424×280 strips; the "iStat-style status strip" idea maps onto the vendor's CPU/MEMORY/STORAGE/NETWORK cards, which are fed by PUSH_MESSAGE queries the Mac must answer (see inputs below).
- **VivoCube panel size (open)**: the physical resolution is not in the vendor client or the launcher; 240 px is only the vendor's 100 % icon size and the panel looks larger (HYPOTHESIS ≥320). The **Panel size test…** menu on the VivoCube page pushes 240…480 px test patterns; once measured, raise the canvas. Also open: alpha images (straight-alpha rendering + a small test icon first) and writing the VivoCube `dataConfig` into the 30300 endpoint so button presses are dispatched for our widget ids.
- **SenseCube** (DONE for the readable sensors): temperature, humidity and ambient light are polled over the protocol (deviceId 11/12/10, propertyId 1; app scales temp/hum ÷10) and shown live on the SenseCube page. Presence (mmWave), sound level and vibration are **event-only on the device and not exposed over :7431** — they drive on-device widgets/scenes only. Possible future path: the Home Assistant entity bridge.
- **DotKey / KnobKey input** (understood; needs profile writes + a reply loop): the device does NOT push raw key/knob events. You bind a control to a "PC" target in the active profile's module config — KnobKey rotation → a `PC_VOLUME`/`PC_BRIGHT` device from the 1617 tree, DotKey key → a `PC_CONTROL` action (hot-keys are typed by the CoreBar itself over USB-HID and never reach the Mac). The device then sends `PUSH_MESSAGE` (1000000) **requests** (`SET_VOLUME`, `GET_VOLUME` every 5 s, `PC_CONTROL {action, params}`, `CPU/MEMORY/STORAGE/NETWORK` stat queries) that the Mac **must answer** with the same id. That needs two things Deckhand lacks today: the 1108 write path, and a **persistent connection with a heartbeat (act 20 every 3 s) and a PUSH_MESSAGE reply loop** instead of one connection per operation.
- **Presence → wake the displays** (HaloBar-style): use the SenseCube's mmWave presence to wake the CoreBar screen + VivoCube on motion (and sleep when away). Presence is event-only on the device and is NOT sent to the Mac, so this must be an **on-device automation** (scene: presence → screen-on / dismiss screensaver), like a HaloBar reacting by itself. Findings: the **presence trigger IS settable over the protocol** (an AUTO scene via `BATCH_CREATE_SCENE` 30500, trigger `DEVICE_STATE state UNOCCUPIED→OCCUPIED`), but there is **no clean "screen-on" action** — `START_SCREEN` is dead; only `BRIGHT` (brightness) and `ACTIVITY` (launch an app, which likely dismisses the screensaver) are available, so "wake" must be approximated and tested on hardware. Scene writes full-replace the list (client owns it), so this waits on the safe profile/scene-write infrastructure.
- **Device settings — reality check**: the :7431 channel is **not** a general settings API. Only **screensaver** (BASE_SET: enable/disable + idle time; the screensaver itself is a separate APK, discoverable with `GET_APP_LIST "SCREENSAVER"`, and a custom slideshow is unlikely without analysing that APK), **screensaver preview**, **gateway config**, **reboot**, **Wi-Fi scan/list** (no connect), **module OTA** (30400/30401, fully specified) and **screen on/off + layer** (per VivoCube) are controllable. Volume, brightness, Bluetooth, Wi-Fi connect, timezone/24h, locale and wallpaper are **on-device only** — moving them into the app would need new vendor firmware. So "only the bare minimum on the device" isn't fully achievable today; we will expose what the protocol allows and surface the rest as device-only. Today the app offers VivoCube screen on/off, reboot, Recover display and the panel size test; the Settings panel lists time/timezone, Wi-Fi and Bluetooth as device-side.
- **Co-existence with the vendor app**: the vendor client never reads anything back and rewrites the whole device on every Deploy (30300 → 1108 → 1010 → 30500 → `/upload/zip` without `subDir` → 1103). Whichever client deploys last wins; Deckhand must detect it (30710 id set changed, assets gone) and re-apply rather than try to merge.

## Widget marketplace

Goal: let anyone build and share widgets; start as a simple GitHub-based registry, grow into a curated marketplace.

- Phase 1 (GitHub): a public repo (or a folder here) holding community widgets as self-contained bundles + a `registry.json` index. Deckhand fetches the index and lets users install a widget. Curation via PRs.
- Phase 2: an in-app browser (install/update/rate), signing/verification of bundles, and a hosted index.
- See WIDGETS.md for the widget format and the key open decision (how to make a widget run on both macOS and Windows).

## Cross-platform (macOS + Windows)

If there's a business case, a Windows client should follow — ideally "build a widget once, runs on both". That pushes the widget format toward something platform-neutral (see WIDGETS.md). The UltraBar protocol itself is already platform-neutral (TCP/TLS + HTTP), so the device layer ports cleanly; the UI and the widget runtime are the platform-specific parts.

## Business model (first assessment)

Many UltraBar X buyers — macOS users especially — can't do much with the device today, so there is a real, underserved audience and goodwill to capture. Options, roughly in order of friction:

1. **Free / open-source core, donations** — fastest trust, lowest revenue. Good for adoption and to become "the" client.
2. **Freemium app** — core free; a one-time "Pro" unlock or small subscription for advanced widgets (Claude/crypto/calendar/multi-page bar), automations, and the settings suite. Precedent: iStat Menus, Bartender are paid and successful.
3. **Marketplace revenue share** — paid community widgets with a cut, like the Stream Deck store. Needs volume + the Phase-2 marketplace.
4. **Cross-platform Pro** — one license covering macOS + Windows.

Risks/unknowns: the vendor ("Sanytron") could ship or object; trademark (hence the Deckhand rename); the install base size; App Store vs. direct (ad-hoc signing today → needs a Developer ID / notarization for a paid release). Recommendation: ship a great free client now to win the users, add a low-friction Pro tier once the feature set (bar pages + settings + input bindings) lands, and keep the marketplace free at first to seed content.

## Decisions (2026-11-01)

1. **Widget format** — web, **TypeScript-first** (HTML/CSS/JS authored in TS, rendered headlessly to an image). Cross-platform by design. See WIDGETS.md for the full option comparison.
2. **Business model** — agreed: free, strong core now → freemium Pro later → marketplace free to start.
3. **Windows** — design for it **from day 1** (shared, platform-neutral core: protocol + widget runtime), even though macOS is the only target we can test here. A second engineer may help on Windows (see COLLAB.md).
4. **Settings in the app** — move everything the protocol allows into the app; keep **Wi-Fi / network onboarding on the device** (and note the protocol can't set most system settings anyway — see the settings reality-check above). Also: make the **physical connection + which USB port to use** unmistakable in-app (the vendor's port design is dangerous — wrong port can fry the mainboard).
5. **Distribution** — **GitHub Releases** with a DMG + full download. The user is obtaining an **Apple Developer ID (for DNC)** so releases can be signed + notarized (no Gatekeeper warnings). Until then, releases are ad-hoc-signed (users must right-click → Open once). See RELEASING.md.

## Connection model (for reference)

Deckhand talks to the CoreBar **over the network** (UDP/TLS/HTTP on the LAN) — there is no USB data transport in the protocol. USB-C is for **power** (and the vendor's HID path). So the "how do I connect" choice is really Wi-Fi vs. wired LAN (most reliable if the device is reachable that way); the USB cable just keeps it powered. Port safety (from the device manual): the CoreBar's **PC-LINK** port is **5 V-only** → connect it to the Mac/computer USB (safe, correct); the **USB-OTG** port is for charging (PD/QC/12 V). **Never** put a PD fast-charger into PC-LINK — it can permanently damage the board. Deckhand surfaces this prominently in-app.
