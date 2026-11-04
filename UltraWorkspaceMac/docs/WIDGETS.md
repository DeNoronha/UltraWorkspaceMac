# Deckhand widgets — how they work, and how to build one

A widget renders a small card that Deckhand pushes to a display: a VivoCube (240×240 — confirmed on hardware: the square panel is exactly 240 × 240, which is also the vendor's 100 % icon size) or the CoreBar screen. On a VivoCube, widgets are shown statically or rotated: Deckhand renders every ticked widget into its own layer of one package (max 6), uploads it once and then switches layers with property 9, exactly like the vendor client's `VIVO_CUBE_TOGGLE`. Since 2026-11-03 only cards that stay valid for five minutes are offered for the cube (`Theme.library`: Weather, Music, Claude Code monitor, Crypto, Calendar, Date, Picture); live readings and clocks were removed because a picture re-sent every 5 minutes at most cannot be a live meter. On the CoreBar screen there is **no** full-screen image (the one-shot `PREVIEW_SCREENSAVER` is broken in the firmware and was removed): a page is a strip of the bar's own cards, which it draws and updates itself, and Deckhand's rendered image can only be the clock (TIME) card's cover (≈540×240 card, rounded cover plus a blurred copy behind it). So the "wide" widget target is really a small cover image plus vendor cards configured from the Mac; see ROADMAP.md and PROTOCOL.md.

## How built-in widgets work today

Each built-in widget is a tiny, self-contained Swift renderer in `Sources/UltraWorkspaceApp/Widgets/`:

- A renderer `enum XxxCard` with a `static func render(... size: Int) -> [UInt8]?` (the weather card takes `width:height:` because it also draws the 480 × 480 clock cover) that returns row-major RGBA8888 (premultiplied, drawn with CoreGraphics/AppKit) through `CardKit.draw(width:height:)` — the one bitmap contract, with the shared text/symbol/gradient helpers.
- An optional data source `XxxStats` / `XxxSource` (a small `Sendable` type that samples system/network/API data).
- Registration: a case in `Theme` (title + SF Symbol), a branch in `AppModel.renderTheme` (`AppModel+Themes.swift`), a blurb in `WidgetsView`, and a settings panel in `AddonSettingsPanel` (`WidgetsView.swift`; the Apps page shows the same panel for a bar app that mirrors the card, such as Weather or Crypto).

Deckhand converts the RGBA to the device format: an LVGL v8 image (RGB565, **opaque by default** — `DeviceImage.encode(allowAlpha:)` is opt-in because the vendor encoder expects straight, not premultiplied, alpha) inside a tar/gzip layer package for a VivoCube module, or an ordinary PNG for the CoreBar screen (uploaded as `deckhand/cover.png` in a zip under `subDir=deckhand` and referenced as the TIME card's cover).

This is great for built-ins but is **macOS-only and requires recompiling the app** — not suitable for a community marketplace. That's the open decision below.

## The cross-platform decision (DECIDED: web/TypeScript)

To "build a widget once, run on macOS and Windows", a widget can't be compiled Swift. Full option set:

1. **HTML/CSS/JS, authored in TypeScript, rendered headlessly to an image** — CHOSEN. A widget is a folder with `manifest.json` + a built `index.html`/`bundle.js` (authored in TypeScript, compiled to JS) + assets. Deckhand loads it in an offscreen web view (WKWebView on macOS, WebView2 on Windows), hands it data via a typed JS bridge, and snapshots to the target size (the VivoCube canvas — 240×240 — or the CoreBar clock-cover size; there is no full-screen 1424×280 target). Pros: truly write-once, the largest author pool, TypeScript gives authors types + tooling, easy styling/animation/Canvas/SVG, sandboxable (no filesystem/native access — only the data we inject). Cons: a web runtime per render (fine at a 10–60 s cadence). We publish an official `@deckhand/widget-sdk` TypeScript package with the typed data API and a local preview harness.
2. **Declarative JSON/YAML spec** (layout + data bindings, no code). Safest and tiny, renders natively on each platform, but limited expressiveness (no custom charts/animation); good as a *simple* widget tier layered on top of option 1 later.
3. **WASM module** (write in Rust/AssemblyScript/TinyGo, run anywhere). Very sandboxable and fast, but a much smaller author pool and more toolchain friction than TS — overkill for drawing a card.
4. **Lua / QuickJS embedded script** (a small scripting runtime drawing to a canvas). Lighter than a full web view, but a bespoke API few people know; weaker ecosystem than TS.
5. **Compiled-native per platform** (Swift + C#/Win). Fastest, but authors ship two binaries and we can't sandbox them — poor marketplace fit. This stays only for our built-ins.

Decision: **option 1 (web, TypeScript-first)** for community/marketplace widgets, with option 2 as a possible later "no-code" tier. Built-ins stay native Swift for now but will be mirrored as web widgets so the SDK is dogfooded.

Proposed manifest sketch (format 1):

```json
{
  "id": "com.author.weather-pro",
  "name": "Weather Pro",
  "version": "1.0.0",
  "author": "name <email>",
  "sizes": ["240x240", "cover"],
  "refreshSeconds": 600,
  "permissions": ["weather", "clock"],
  "entry": "index.html"
}
```

Data/permissions a widget can request (so authors don't each re-implement): clock/timezone, weather, system stats (cpu/mem/net/disk/uptime), battery, now-playing, calendar, custom HTTP (declared hosts only). Deckhand provides these to the widget; the widget never gets raw system access.

## Marketplace (start on GitHub)

- A public repo with `widgets/<id>/` folders and a top-level `registry.json` (id, name, author, version, sizes, download URL, checksum).
- Deckhand fetches `registry.json`, lists widgets, installs by downloading the bundle into the user's widgets dir, and renders it like a built-in.
- Curation via PRs; later add signing + an in-app store (see ROADMAP.md).

## For now

Built-ins stay native Swift (fast, no runtime). The community format is decided (web / TypeScript, option 1 above) and is the next architecture step. This file will carry the full authoring guide once the SDK and runtime exist.
