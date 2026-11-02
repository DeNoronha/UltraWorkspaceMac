# SmallTV-Max (GeekMagic) — competitive research for Deckhand

Researched 2026-11-02. The Kickstarter campaign page itself (body, rewards, FAQ, comments, updates) returned HTTP 403 to every fetch, so campaign details come from Kicktraq/BackerKit snapshots, GeekMagic's own site and GitHub, and third-party write-ups. No YouTube video about the Max was found via search (only videos about the older SmallTV Ultra/Pro). Everything below marked *uncertain* is inferred or unverified.

## 1. What it is

- **Maker:** GeekMagic, a brand of Shenzhen Fumantu Technology Co., Ltd. (Kickstarter creator "FUMANTU", listed as Salt Lake City, UT). Known for the cheap AliExpress "SmallTV" desk clocks (Ultra = ESP8266, Pro = ESP32, both 1.54" 240×240, configured via a built-in web page; no app).
- **Hardware:** ESP32-S3-N16R8 (16 MB flash, 8 MB PSRAM), 4.3" IPS LCD, **480×272 landscape**, built-in **rotary encoder knob on top** ("turn-to-browse"), buzzer, CNC anodized aluminium case, 2.4 GHz Wi-Fi, USB-C power. Comes with a printed guide and power cable. (Specs from GeekMagic's own GitHub issue on geekmagic-hacs; buzzer/aluminium from Gadgetify.)
- **Positioning:** "Create a Desktop Screen That Feels Like Yours." A desk dashboard for time, weather (incl. radar), global markets (stocks, crypto, gold, FX), live flights / nearby air traffic, timers (Pomodoro), alarms, and animated scenes; the knob rotates between "focused views". A companion computer client can show "supported AI service usage" (Claude/Codex-style quota meters) as a view.
- **Kickstarter:** live Oct 22 – Nov 21 2026, goal $5,000. Snapshots: $42.6k / 784 backers (BackerTracker, ~24 days left) → $59.7k / 1,068 backers (BackerKit) → **$64,074 / 1,135 backers, 1281 % funded, avg pledge $56** (Kicktraq, ~18 days left, i.e. around Nov 2). A $100k stretch goal (Oct 30 update) promises a free "mini pixel keychain" for every backer.
- **Price:** reward tiers not retrievable. Average pledge of $56 suggests a main tier around $49–69 (*uncertain*). The 240×240 Ultra/Pro retail roughly $15–35 on AliExpress for context.

## 2. Companion software & UX

What is documented for the Max specifically is thin; the following combines the Max marketing copy with the well-documented stock UX of the Ultra/Pro, which the Max almost certainly inherits (*uncertain*).

- **No mobile app, no desktop app required.** "Browser-based setup." The device serves its own web UI over the LAN.
- **Step-by-step (Ultra/Pro, presumably Max):** 1) Plug in; device boots into AP mode and shows its own SSID. 2) Join the AP, open the captive page, enter home Wi-Fi credentials, device reboots. 3) Open `http://<device-ip>/` in any browser. 4) Tabs/pages: Settings (theme picker 1–7, brightness slider, night mode schedule, auto-rotate themes with interval), Network, Weather (city, API key, units, refresh interval), Time (NTP, 12/24 h, date format, digit colours, countdown), Image (album: upload JPEG/GIF, in-browser crop with Cropper.js, slideshow interval), Update (upload firmware zip). 5) On the device the top control/touch button cycles screens.
- **Max additions (from marketing):** knob = primary navigation between views, "Play" for animated scenes, personalisation of which markets/cities/flights are followed, and an optional **computer client** (platform unknown, *uncertain*) that pushes local-only data such as AI tool usage.
- **Visual impression:** the Ultra/Pro web UI is a plain jQuery/Bootstrap-style form page: dropdowns, sliders, text fields, an image grid with delete buttons, a crop modal. No live preview of the device screen in the stock UI. The device screens themselves are the design asset: full-bleed pixel-art/animated backgrounds with large clock digits, weather icons and ticker rows.

## 3. Widget/theme catalogue + community/sharing model

- **Stock catalogue (Max, per marketing):** clocks (multiple styles), weather + radar, markets (single asset, asset with price chart, multi-asset board), flights/air traffic, timer/Pomodoro, alarm, animated scenes/wallpapers, AI-usage view. Ultra/Pro also ship a "Photo Album" theme (user JPEG/GIF, 240×240) and an 80×80 weather GIF slot.
- **Sharing model (stock):** essentially **"upload a picture/GIF"**. There is no official gallery; the community shares 240×240 GIFs on GitHub (GeekMagicClock/gif repo, 68 stars / 64 forks) and in Home Assistant forums. The company's stated plan for the Max: "Open source will be available, any one could build your own screen with the help of AI" (GitHub issue #277, Oct 22). Nothing shipped yet (*uncertain* what "open source" will cover).
- **Where the real theme ecosystem lives — the community firmware, which is the thing worth studying:**
  - **giovi321/smalltv-mod** (and many forks): replacement firmware with modes for stock/crypto ticker (Yahoo Finance or custom webhook, sparkline, P/L from quantity + cost basis), Claude usage meter (fed by a PC daemon), ADS-B plane radar, Home Assistant draw-list screens over MQTT, and **theme clocks packaged as `.stheme` files** (declarative: background image, animated sprites, clock/date text, scrolling text, shapes, data-bound fields like `{weather.temp}`). Web UI tabs: WiFi, Ticker, Display (install .stheme), Mode/carousel, Time (nightly dim), Button (tap/long-press actions), System (OTA, backup/restore config, optional digest auth). Push **notifications overlay** via HTTP that a button press dismisses.
  - **giovi321/smalltv-studio**: browser-based, install-free **visual theme editor**: layer text/image/animation/shape on a 240×240 canvas, preview at a simulated time, bind fields to JSON data sources, export `.stheme` or send to the device over Wi-Fi. Ships example themes ("Pixel Room", "Terminal Ops", "Live Status").
  - **adrienbrault/geekmagic-hacs** (Home Assistant): server-side rendering, no flashing. Sidebar panel with a **Views tab + live-preview view editor**; layout templates (fullscreen, 2×2…3×3 grids, splits, hero, sidebar); each slot gets a widget (gauge bar/ring/arc, entity, date/time, HTML+Jinja, climate, clock, text, progress, weather, status, chart, candlestick, camera, media, multi-progress). Views are global and assigned per device with drag-to-order rotation and a cycle interval; `geekmagic.notify` service interrupts rotation with a temporary alert; "Active" switch sleeps the display via presence automations. ~15 built-in stylesheets ("themes") incl. CRT scanlines. GeekMagic opened issue #222 asking this project to support the Max at 480×272 and offered free samples and firmware changes.
  - Others: bairachnyi/geektv (MIT, web config + GitHub CI status + Codex usage), irsin78/geekmagictv (AI-quota display), Times-Z/GeekMagic-Open-Firmware, SelfScreen, ESPHome/Tasmota ports, a Python wrapper (geekmagicweatherclockapi) and a Rust crate (geekmagic-stats) for the stock HTTP API.

## 4. Openness (API, firmware, GitHub, docs)

- **Stock HTTP API (Ultra/Pro, reverse-engineered, no auth, no CORS):** `POST /doUpload?dir=/image/` (multipart JPEG/GIF), `GET /set?img=/image//<file>`, `GET /set?theme=N`, `GET /set?brt=N`, `GET /set?theme_list=…&sw_en=1&sw_i=secs`, night mode `GET /set?t1&t2&b2&en`, `GET /filelist?dir=/image/`, status JSON (`/v.json`, `/app.json`, `/space.json`, `/config.json`). Several JSON endpoints 404 on current Ultra firmware. Firmware upgrade via web console upload; GeekMagic's GitHub repos (smalltv-ultra 662★, smalltv-pro 348★) host **binaries and PDF manuals, not source**; no licence visible.
- **Max:** GeekMagic says "firmware/API details" will be shared with integrators and that "open source will be available", but as of today nothing for the Max is public. Whether that means source, an API spec, or a theme SDK is *uncertain*.
- **Docs:** geekmagic.cc/support links only to the GitHub repos; Max docs do not exist yet.

## 5. Ideas worth stealing for Deckhand (prioritised)

1. **Knob = view browser (S).** Map KnobKey rotation to cycle VivoCube cards and bar pages; this is the Max's headline interaction and it is why people prefer it to a phone.
2. **Views are global, assigned per device, with drag-to-order rotation + cycle interval (M).** geekmagic-hacs's model: define a card once, assign to CoreBar and/or VivoCube, reorder in a list; "0 = manual only".
3. **Live preview in the editor at native resolution (M).** Render the card at 240×240 / 1424×280 in-app, with a "simulate time/date/values" toggle like smalltv-studio.
4. **Layout templates with widget slots (M).** Fullscreen, 2×2, hero+sidebar etc.; a slot takes a widget (gauge ring/bar/arc, text, chart, sparkline). Cheaper than a free-form canvas and covers 90 % of dashboards.
5. **Notification overlay that interrupts rotation and is dismissed by a key/knob press (S).** smalltv-mod and HACS both have it; DotKey is the natural dismiss button.
6. **Market/crypto ticker with sparkline and optional holdings P/L (S).** Clearly the top-selling use case (Bitcoin is in every Max headline).
7. **"AI usage meter" card (S).** Claude/Codex 5 h / 7 day quota bars fed from local config; already a meme on the SmallTV scene and trivial for a Mac app to read.
8. **Flights/ADS-B radar card (M).** Nearby aircraft from adsb.lol/adsb.fi, location-centred; distinctive and demo-friendly.
9. **Declarative theme package format + import/export (M).** A `.deckhandtheme` (JSON + assets: background, sprites, text layers, data bindings `{weather.temp}`) so themes can be shared as files and later a gallery.
10. **Pixel-art/GIF background library with upload + crop (S).** Users love the "animated scene" look; an in-app crop to 240×240 (Cropper.js equivalent) and GIF support goes a long way.
11. **Presence-aware sleep (S).** "Active" toggle driven by Mac idle/screen-lock to dim the bar/cube at night or when away; night-mode schedule with per-period brightness.
12. **Config backup/restore and export-as-file (S).** Stock and community firmware both expose it; makes support and theme sharing easier.
13. **Local HTTP endpoint on the Mac for third parties (M).** The whole GeekMagic ecosystem exists because of a dumb unauthenticated "upload a picture / notify" API; offer a localhost `POST /notify` and `POST /image` for scripts, HA, Shortcuts.
14. **Per-widget data source choice incl. custom webhook (M).** smalltv-mod lets each ticker pick Yahoo/other/webhook; generalise: every card can be fed by a URL returning JSON.
15. **Open theme SDK with AI prompt recipe (L).** GeekMagic's promise "build your own screen with the help of AI": publish the theme schema + a prompt template so users can generate cards with an LLM.

## 6. Things NOT to copy

- Stock web UI served from the device: forms without preview, 404-ing JSON endpoints, inconsistent docs; we already have a native app, keep the preview-first UX.
- Unauthenticated, CORS-less LAN API as the only interface — fine for hobbyists, but Deckhand's local endpoint should at least be loopback-only or token-gated.
- "Open source" as a marketing promise with binaries-only repos; if we publish a theme format, publish the spec and examples the same day.
- Dependence on external market/weather APIs without clear status; reviewers' main worry about the Max is long-term service reliability. Show data freshness and failure state on every card.
- Visual clutter: constant animation on every screen. Keep a calm default theme and make animation opt-in per card.
- Phone-free is good, but no desktop client for config means no system data (CPU, music, calendar) — exactly where Deckhand wins; don't dilute that.

## 7. Sources

- Kickstarter project (403 on fetch): https://www.kickstarter.com/projects/2030358954/customizable-smart-desktop-display-for-global-markets-etc
- Kicktraq snapshot and dates: http://www.kicktraq.com/projects/2030358954/customizable-smart-desktop-display-for-global-markets-etc/
- BackerKit trending (earlier snapshot): https://www.backerkit.com/projects/trending/technology
- GeekMagic product page: https://geekmagic.cc/ and compare page https://geekmagic.cc/compare/ and support https://geekmagic.cc/support/
- GeekMagic announcement, "open source will be available": https://github.com/GeekMagicClock/smalltv-ultra/issues/277
- GeekMagic feature request with Max specs: https://github.com/adrienbrault/geekmagic-hacs/issues/222
- GeekMagic GitHub org: https://github.com/geekmagicclock
- KickstartNew review: https://www.kickstartnew.com/smalltv-max-create-a-desktop-screen-that-feels-like-yours-kickstarter-review/
- Gadgetify: https://www.gadgetify.com/smalltv-max/
- Stock HTTP API doc (geekmagic-stats crate): https://docs.rs/crate/geekmagic-stats/latest/source/device-protocol.md
- smalltv-mod firmware: https://github.com/giovi321/smalltv-mod and theme editor https://github.com/giovi321/smalltv-studio
- geekmagic-hacs Home Assistant integration: https://github.com/adrienbrault/geekmagic-hacs
- Hackaday, Oct 2026: https://hackaday.com/2026/10/06/smalltv-hacking-with-surprisingly-little-fuss/
- Hackaday, Jul 2026: https://hackaday.com/2026/07/10/a-super-cheap-desk-toy-becomes-a-hackable-desktop-notifier/
- Other open firmware: https://github.com/bairachnyi/geektv, https://github.com/Times-Z/GeekMagic-Open-Firmware, https://github.com/irsin78/geekmagictv
