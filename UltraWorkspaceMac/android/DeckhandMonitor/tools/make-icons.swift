#!/usr/bin/swift
// Renders the launcher icons for every Deckhand bar-app flavor.
//
//   swift tools/make-icons.swift            (run from android/DeckhandMonitor)
//
// Per flavor it writes, under app/src/<flavor>/res/:
//   mipmap-<density>/ic_launcher_foreground.png   adaptive-icon foreground, 108 dp canvas, white glyph
//   mipmap-<density>/ic_launcher.png              legacy 48 dp icon: rounded square (20 % radius) + glyph
//   values/ic_launcher_background.xml             the flavor's background colour (used by the adaptive icon)
// and a 216 px preview of the composed icon to ../../dist/bar-apps/icons/<flavor>.png.
//
// Glyphs are SF Symbols (bold, .large) drawn white; the Claude flavor draws a starburst mark by hand.

import AppKit
import Foundation

struct Flavor {
    let name: String
    let background: String      // hex rrggbb
    let symbol: String?         // SF Symbol name, nil = custom drawing
    let glyphColor: String      // hex rrggbb
}

let flavors: [Flavor] = [
    Flavor(name: "monitor",  background: "1f3a8a", symbol: "waveform.path.ecg",      glyphColor: "ffffff"),
    Flavor(name: "crypto",   background: "b45309", symbol: "bitcoinsign.circle.fill", glyphColor: "ffffff"),
    Flavor(name: "weather",  background: "0e7490", symbol: "cloud.sun.fill",          glyphColor: "ffffff"),
    Flavor(name: "music",    background: "be123c", symbol: "music.note",              glyphColor: "ffffff"),
    Flavor(name: "calendar", background: "15803d", symbol: "calendar",                glyphColor: "ffffff"),
    Flavor(name: "claude",   background: "2b2522", symbol: nil,                       glyphColor: "d97757"),
]

// density name -> scale factor (mdpi = 1 px per dp)
let densities: [(String, CGFloat)] = [("mdpi", 1), ("hdpi", 1.5), ("xhdpi", 2), ("xxhdpi", 3), ("xxxhdpi", 4)]

let adaptiveDp: CGFloat = 108   // adaptive icon canvas
let safeDp: CGFloat = 72        // content must stay inside the central 72 dp (66 dp circle is the official mask)
let glyphDp: CGFloat = 54       // bounding box of the glyph inside the safe zone
let legacyDp: CGFloat = 48      // classic launcher icon size

func color(_ hex: String) -> NSColor {
    var v: UInt64 = 0
    Scanner(string: hex).scanHexInt64(&v)
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                   green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

/// Runs `draw` inside a fresh transparent sRGB bitmap of `px` × `px` and returns the bitmap.
func render(px: Int, _ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.cgContext.setShouldAntialias(true)
    ctx.cgContext.interpolationQuality = .high
    draw(ctx.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to path: String) {
    let data = rep.representation(using: .png, properties: [:])!
    try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                             withIntermediateDirectories: true)
    try! data.write(to: URL(fileURLWithPath: path))
}

/// Draws the flavor's glyph, filling `box` (a square in the current context's points), in its glyph colour.
func drawGlyph(_ flavor: Flavor, in box: CGRect, _ cg: CGContext) {
    let tint = color(flavor.glyphColor)
    let box = flavor.symbol == nil ? box.insetBy(dx: -box.width * 0.08, dy: -box.width * 0.08) : box
    if let symbolName = flavor.symbol {
        let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)!
        let config = NSImage.SymbolConfiguration(pointSize: box.width, weight: .bold, scale: .large)
        let symbol = base.withSymbolConfiguration(config)!
        // fit the symbol's aspect ratio inside the box
        let s = symbol.size
        let k = min(box.width / s.width, box.height / s.height)
        let w = s.width * k, h = s.height * k
        let rect = CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
        cg.saveGState()
        // draw the template symbol, then recolour everything it painted
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        cg.setBlendMode(.sourceAtop)
        cg.setFillColor(tint.cgColor)
        cg.fill(rect.insetBy(dx: -2, dy: -2))
        cg.endTransparencyLayer()
        cg.restoreGState()
    } else {
        drawStarburst(in: box, color: tint, cg)
    }
}

/// Claude's mark: 12 rounded rays of alternating length radiating from the centre.
func drawStarburst(in box: CGRect, color: NSColor, _ cg: CGContext) {
    let c = CGPoint(x: box.midX, y: box.midY)
    let lineWidth = box.width * 0.105
    let longLen = box.width * 0.50 - lineWidth / 2     // tip of the round cap lands at the box edge
    let shortLen = box.width * 0.36 - lineWidth / 2
    let inner: CGFloat = 0
    cg.saveGState()
    cg.setStrokeColor(color.cgColor)
    cg.setLineWidth(lineWidth)
    cg.setLineCap(.round)
    for i in 0..<12 {
        let a = CGFloat(i) * .pi / 6 + .pi / 12          // 30° steps, rotated so no ray is dead vertical
        let len = i % 2 == 0 ? longLen : shortLen
        let dir = CGPoint(x: cos(a), y: sin(a))
        cg.move(to: CGPoint(x: c.x + dir.x * inner, y: c.y + dir.y * inner))
        cg.addLine(to: CGPoint(x: c.x + dir.x * len, y: c.y + dir.y * len))
        cg.strokePath()
    }
    // solid centre so the rays read as one shape
    let r = lineWidth * 0.7
    cg.setFillColor(color.cgColor)
    cg.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    cg.restoreGState()
}

/// Composed icon (background rounded square with 20 % corner radius + glyph) at `px` pixels.
func composed(_ flavor: Flavor, px: Int) -> NSBitmapImageRep {
    render(px: px) { cg in
        let size = CGFloat(px)
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let path = CGPath(roundedRect: rect, cornerWidth: size * 0.2, cornerHeight: size * 0.2, transform: nil)
        cg.addPath(path)
        cg.setFillColor(color(flavor.background).cgColor)
        cg.fillPath()
        let g = size * (glyphDp / safeDp) * 0.78   // same glyph-to-visible-area ratio as the adaptive icon
        drawGlyph(flavor, in: CGRect(x: (size - g) / 2, y: (size - g) / 2, width: g, height: g), cg)
    }
}

let projectDir = FileManager.default.currentDirectoryPath
let resRoot = projectDir + "/app/src"
let previewDir = projectDir + "/../../dist/bar-apps/icons"

for flavor in flavors {
    let flavorRes = "\(resRoot)/\(flavor.name)/res"
    for (density, scale) in densities {
        // adaptive foreground: transparent 108 dp canvas, glyph centred in the safe zone
        let px = Int(adaptiveDp * scale)
        let fg = render(px: px) { cg in
            let g = glyphDp * scale
            let o = (CGFloat(px) - g) / 2
            drawGlyph(flavor, in: CGRect(x: o, y: o, width: g, height: g), cg)
        }
        writePNG(fg, to: "\(flavorRes)/mipmap-\(density)/ic_launcher_foreground.png")
        // legacy icon
        writePNG(composed(flavor, px: Int(legacyDp * scale)), to: "\(flavorRes)/mipmap-\(density)/ic_launcher.png")
    }
    let colorsXml = """
    <?xml version="1.0" encoding="utf-8"?>
    <resources>
        <color name="ic_launcher_background">#\(flavor.background)</color>
    </resources>

    """
    try! FileManager.default.createDirectory(atPath: "\(flavorRes)/values", withIntermediateDirectories: true)
    try! colorsXml.write(toFile: "\(flavorRes)/values/ic_launcher_background.xml", atomically: true, encoding: .utf8)
    writePNG(composed(flavor, px: 216), to: "\(previewDir)/\(flavor.name).png")
    print("\(flavor.name): icons written")
}
