# UltraBar X — vendor product page (notes, 2026-11-03)

Source: https://www.sanytron.com/products/ultrabar-x-the-modular-desktop-command-center (Sanytron, Shopify). Fetched 2026-11-03; marketing claims are quoted as claims, not verified behaviour. Photos are linked, not copied (vendor copyright).

## What the page says

- **Product**: "UltraBarX: The Modular Desktop Command Center" — "a magnetic modular desktop interface ecosystem. Snap CoreBar, SenseCube, VivoCube, DotKey and KnobKey together". €/$599 (Grey or White). "4.9/5 · 793+ Kickstarter backers", "funded at 26,695%". Free worldwide shipping, 12-month warranty, 30-day returns. Support: support@sanytron.com.
- **Modules** (vendor one-liners):
  - **CoreBar** — "5:1 ultra-wide touch display with LineOS™ built-in — the command hub". Finishes Green / Gold / Black, "ergonomic 45° angle, fits under monitor". (Deckhand: 1424×280 strip, TLS :7431, HTTP :8080, UDP 5319.)
  - **SenseCube** — "mmWave radar + environmental sensor for context-aware, presence-based automation". (Deckhand reads temperature/humidity via property reads; presence not yet used.)
  - **VivoCube** — "2.0" AMOLED smart module with gesture control and independent power". (Deckhand: 240×240 panel, LVGL RGB565 packages, ≤6 layers; "independent power" = its own battery, which is why it keeps its own Wi-Fi radio and fetches packages over Wi-Fi.)
  - **DotKey** — "Cherry MX mechanical shortcut key with fully customizable macros" (three keys: two round, one tall).
  - **KnobKey** — "Precision metal rotary encoder with satisfying tactile feedback".
  - Optional **Wireless PC Boot** PCIe module: "BIOS-level remote power control, fully integrated with Home Assistant".
- **QuantumLink™**: "N52-grade magnets recognize and connect modules instantly… up to 15 modules… reconfiguration in 0.3 seconds, no cables, no tools". The photos show the link as a **12-pin pogo connector (2 × 6)** on each module's flank. Everything Deckhand reads over this link (firmware version, uptime, screen, Wi-Fi state, Wi-Fi config, clock, layer/widget) is a few bytes; image packages do not travel over it (see MANUAL troubleshooting on cube Wi-Fi).
- **LineOS™**: "dedicated card-based OS unifying every module… cross-platform on Windows, macOS and Linux". **SceneShift™**: "AI-driven context engine detects what you are working on and switches UI layouts and macros automatically". "90+ platform integrations and 300+ ready-made templates", "open SDK… build custom plugins, scenes, and integrations".
- **Smart home**: Philips Hue, SONOS, Home Assistant "out of the box".
- **Bundles shown**: Creator (CoreBar + KnobKey + DotKey + VivoCube), Gamer (CoreBar + 2 DotKey + VivoCube), Developer (CoreBar + 2 DotKey + KnobKey), Smart home (CoreBar + SenseCube + KnobKey).
- **Nothing on the page** about Wi-Fi bands, the bar's hotspot, Bluetooth, USB data, or how modules receive images — the page is marketing only; the "specs" block repeats the lines above.

## Photos (vendor CDN)

- Bar with modules, angled: https://www.sanytron.com/cdn/shop/files/10_0e01d374-a184-450e-addf-a58e8acc932d.png — CoreBar (grey) with VivoCube (square), DotKey (two round + one tall key) and KnobKey (large dial) snapped on the right; pogo connector on the end cap.
- End caps with the QuantumLink connector: …acc9312d.png and …acc92132d.png (same path prefix) — pentagonal profile, 12-pin pogo block.
- Desk shots (renders): https://www.sanytron.com/cdn/shop/files/16129a19-1f0d-4eee-a9b6-ff2ec02da222222222fd.png (developer), …/67ab2396-7f50-4d10-9ae8-cb0f1b922222333ed40a.png (designer), …/afterdesk.png and …/beforedesk.png (before/after slider) — the bar shows a flip-clock page, a small green card and an analog clock on the VivoCube.
- VivoCube exploded view: https://www.sanytron.com/cdn/shop/files/explodedview.png — display, PCB, battery bay, pogo plate.

## Useful for Deckhand

- The pictures confirm the physical layout used in the app's DotKey/KnobKey drawings and the 2.0" square VivoCube.
- The vendor's own showcase cards (flip clock, analog clock) are a good target for the Clock / Date cards.
- Presence (mmWave) on the SenseCube is advertised but not yet read by Deckhand — a candidate for "dim the cube when nobody is at the desk" (see ROADMAP).
