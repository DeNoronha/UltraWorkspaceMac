# Deckhand — roadmap, ideas & strategy

Deckhand is an independent, native client for the UltraBar X (CoreBar + QuantumLink modules). The vendor's own software is thin, especially on macOS, so Deckhand aims to be the client people actually use. This doc captures the plan and the open questions; it is a living document.

## Status today (works)

- Discovery (UDP :5319), pairing (TLS :7431, tap-Approve, trust-on-first-use cert pinning), token stored in a protected file (no Keychain prompt).
- Live bus scan + provisioning (SET_GATEWAY_CONFIG 30300) with an on-disk module cache that keeps asleep modules (e.g. the DotKey) from being dropped.
- Push widgets to a VivoCube (RGB565 + tar/gzip over HTTP :8080). 13 widgets: weather, music, Claude usage, CPU, network, battery, storage, world clock, crypto, calendar, disk I/O, top CPU, uptime.
- Per-device rotation screens (VivoCube now; CoreBar placeholder), live on-screen widget preview, wire-log, About, MIT license.
- CoreBar big-screen: non-destructive preview implemented (upload zip + PREVIEW_SCREENSAVER). See PROTOCOL.md.

## Near-term (next)

- **CoreBar big screen as a real device**: persistent wallpaper + multiple pages/scenes (Stream-Deck-style), via BATCH_SAVE_PROFILE (1108) — needs careful read-modify-write of the full profile list (destructive otherwise). Validate the preview path first.
- **Wide (1424×280) widget layouts** so any widget can go on the big bar, not just weather. The big bar as an iStat-Menus-style status strip (a row of mini-widgets) is the headline feature.
- **SenseCube** (DONE for the readable sensors): temperature, humidity and ambient light are polled over the protocol (deviceId 11/12/10, propertyId 1; app scales temp/hum ÷10) and shown live on the SenseCube page. Presence (mmWave), sound level and vibration are **event-only on the device and not exposed over :7431** — they drive on-device widgets/scenes only. Possible future path: the Home Assistant entity bridge.
- **DotKey / KnobKey input** (understood; needs profile writes): the device does NOT push raw key/knob events. Instead you bind a control to a "PC" target in the active Profile — KnobKey rotation → `PC_VOLUME`/`PC_BRIGHT` (device pushes `act 1000000 / SET_VOLUME`), DotKey key → a `PC_CONTROL` scene action (pushes `PC_CONTROL`) or HID keycodes. The Mac then applies volume / runs a shortcut. Requires the `BATCH_SAVE_PROFILE` (1108) profile-write path (held until the preview is confirmed, because it replaces the whole profile list).
- **Device settings — reality check**: the :7431 channel is **not** a general settings API. Only **screensaver** (BASE_SET), **screensaver preview**, **gateway config**, **reboot**, **Wi-Fi scan/list** (no connect), and **screen on/off** (per endpoint) are controllable. Volume, brightness, Bluetooth, Wi-Fi connect, timezone/24h, locale and wallpaper are **on-device only** — moving them into the app would need new vendor firmware. So "only the bare minimum on the device" isn't fully achievable today; we expose what the protocol allows (screensaver, wallpaper-via-profile, Wi-Fi list, reboot, screen on/off) and surface the rest as device-only.

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

## Open questions (need your call)

1. **Widget format for cross-platform** — the big fork. See WIDGETS.md: compiled-native (fast, per-platform) vs. HTML/JS-rendered-to-image (write once, runs on Mac+Windows, sandboxed) vs. a declarative JSON spec. My lean: HTML/JS rendered headlessly to an image for community widgets, keeping the current native cards as the built-ins.
2. **Business model** — which of the four above do you want to aim for? (My lean: free core now, freemium Pro later, free marketplace to start.)
3. **Windows** — build it in parallel, or only after macOS Pro proves demand?
4. **Settings migration scope** — move everything we can into the app, or keep a few safety-critical ones (Wi-Fi onboarding) on the device?
5. **Distribution** — direct download (needs a paid Apple Developer ID for notarization) vs. Mac App Store (sandboxing may block local-network/Process use)?
