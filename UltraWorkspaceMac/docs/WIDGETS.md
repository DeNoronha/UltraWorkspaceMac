# Deckhand widgets — how they work, and how to build one

A widget renders a small card that Deckhand pushes to a display: a VivoCube (240×240, round) or the CoreBar screen (1424×280, wide). Widgets can be shown statically or rotated.

## How built-in widgets work today

Each built-in widget is a tiny, self-contained Swift renderer in `Sources/UltraWorkspaceApp/Widgets/`:

- A renderer `enum XxxCard` with `@MainActor static func render(... size: Int) -> [UInt8]?` that returns row-major RGBA8888 (premultiplied, drawn with CoreGraphics/AppKit).
- An optional data source `XxxStats` / `XxxSource` (a small `Sendable` type that samples system/network/API data).
- Registration: a case in `Theme` (title + SF Symbol), a branch in `AppModel.renderTheme`, and a one-line description in the Widgets pane.

Deckhand converts the RGBA to the device format: RGB565(+alpha) + tar/gzip for a VivoCube module, or an ordinary PNG in a zip for the CoreBar screen.

This is great for built-ins but is **macOS-only and requires recompiling the app** — not suitable for a community marketplace. That's the open decision below.

## The cross-platform decision (OPEN)

To "build a widget once, run on macOS and Windows", a widget can't be compiled Swift. Candidate formats:

1. **HTML/CSS/JS rendered headlessly to an image** (recommended lean). A widget is a folder with `manifest.json` + `index.html` + assets. Deckhand loads it in an offscreen web view (WKWebView on macOS, WebView2 on Windows), passes it data (weather, stats, device info) via a small JS bridge, and snapshots the result to the target resolution. Pros: truly write-once, huge author pool, easy styling/animation, sandboxable. Cons: a web runtime per render.
2. **Declarative JSON spec** (layout + bindings, no code). Safest/sandboxed, but limited expressiveness; we'd build the renderer on each platform.
3. **Compiled-native per platform**. Fastest, but authors must ship two binaries — poor marketplace fit.

Proposed manifest sketch (format 1):

```json
{
  "id": "com.author.weather-pro",
  "name": "Weather Pro",
  "version": "1.0.0",
  "author": "name <email>",
  "sizes": ["240x240", "1424x280"],
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

Built-ins stay native Swift (fast, no runtime). The community format (likely format 1) is the next architecture step — pending your call in ROADMAP.md open question #1. This file will carry the full authoring guide once the format is chosen.
