#!/usr/bin/swift
// Renders the launcher icons for every Deckhand bar-app flavor.
//
//   swift tools/make-icons.swift            (run from android/DeckhandMonitor)
//
// Per flavor it writes, under app/src/<flavor>/res/ (or the flavor's own resDir, e.g. home/src/main/res for Deckhand Home):
//   mipmap-<density>/ic_launcher_background.png   adaptive-icon background, 108 dp canvas: vertical two-tone
//                                                 gradient with a soft radial highlight top-left
//   mipmap-<density>/ic_launcher_foreground.png   adaptive-icon foreground, 108 dp canvas: the glyph with a soft
//                                                 drop shadow, inside the 72 dp safe zone
//   mipmap-<density>/ic_launcher.png              legacy 48 dp icon: rounded square (20 % radius) composed
//   values/ic_launcher_background.xml             the flavor's base colour (kept for anything that reads it)
// and previews of the composed icon to ../../dist/bar-apps/icons/<flavor>.png (216 px) and <flavor>-240.png.
//
// The glyph of every flavor except claude is a 3D render from Microsoft's Fluent Emoji set (MIT licence; files and
// attribution in tools/fluent/, see SOURCES.md there), trimmed to its opaque bounds and fitted into about 62 % of
// the icon. Claude keeps its hand-drawn starburst. The bar shows the icons at about 240 px on a card.

import AppKit
import Foundation

struct Flavor {
    let name: String
    /// Where the icons go; nil = app/src/<name>/res (a product flavor of the kiosk app).
    var resDir: String? = nil
    let top: String             // gradient top colour, hex rrggbb (lighter)
    let bottom: String          // gradient bottom colour, hex rrggbb (darker)
    let glyphColor: String      // hex rrggbb (only the hand-drawn claude glyph uses it)
    let glyph: Glyph
}

enum Glyph {
    case claude                 // hand-drawn starburst
    case house                  // hand-drawn house (Deckhand Home)
    case fluent(String)         // file name in tools/fluent/
}

let flavors: [Flavor] = [
    Flavor(name: "monitor",  top: "3b63d6", bottom: "1b3380", glyphColor: "ffffff", glyph: .fluent("chart_increasing_3d.png")),
    Flavor(name: "crypto",   top: "f2a21a", bottom: "a84a07", glyphColor: "ffffff", glyph: .fluent("coin_3d.png")),
    Flavor(name: "weather",  top: "26a9c9", bottom: "0b667f", glyphColor: "ffffff", glyph: .fluent("sun_behind_cloud_3d.png")),
    Flavor(name: "music",    top: "f04a6a", bottom: "a50f35", glyphColor: "ffffff", glyph: .fluent("musical_note_3d.png")),
    Flavor(name: "calendar", top: "2cc06a", bottom: "116b33", glyphColor: "ffffff", glyph: .fluent("spiral_calendar_3d.png")),
    Flavor(name: "claude",   top: "3e3531", bottom: "1e1917", glyphColor: "d97757", glyph: .claude),
    Flavor(name: "flights",  top: "1fb5a3", bottom: "0c6660", glyphColor: "ffffff", glyph: .fluent("airplane_3d.png")),
    Flavor(name: "sky",      top: "5a53d4", bottom: "272468", glyphColor: "ffffff", glyph: .fluent("crescent_moon_3d.png")),
    Flavor(name: "news",     top: "b8552f", bottom: "6e2710", glyphColor: "ffffff", glyph: .fluent("rolled-up_newspaper_3d.png")),
    Flavor(name: "verse",    top: "9b4fd6", bottom: "5b1a92", glyphColor: "ffffff", glyph: .fluent("open_book_3d.png")),
    Flavor(name: "tasks",    top: "7d87ea", bottom: "4a52b8", glyphColor: "ffffff", glyph: .fluent("check_mark_button_3d.png")),
    Flavor(name: "haven",    top: "2b7fc4", bottom: "123f73", glyphColor: "ffffff", glyph: .fluent("ship_3d.png")),
    Flavor(name: "tide",     top: "1f6f86", bottom: "0a2a3f", glyphColor: "ffffff", glyph: .fluent("water_wave_3d.png")),
    Flavor(name: "teletekst", top: "1d4ed8", bottom: "0b1020", glyphColor: "ffffff", glyph: .fluent("television_3d.png")),
    // Deckhand Home is its own Gradle module (home/), not a flavor of the kiosk app.
    Flavor(name: "home", resDir: "home/src/main/res", top: "4b5a78", bottom: "1c2436", glyphColor: "ffffff", glyph: .house),
]

// density name -> scale factor (mdpi = 1 px per dp)
let densities: [(String, CGFloat)] = [("mdpi", 1), ("hdpi", 1.5), ("xhdpi", 2), ("xxhdpi", 3), ("xxxhdpi", 4)]

let adaptiveDp: CGFloat = 108   // adaptive icon canvas
let safeDp: CGFloat = 72        // content must stay inside the central 72 dp (66 dp circle is the official mask)
let glyphFraction: CGFloat = 0.62   // glyph box as a fraction of a composed (square) icon, and of the safe zone
let glyphDp: CGFloat = (safeDp * glyphFraction).rounded()   // bounding box of the glyph inside the safe zone (45 dp)
let legacyDp: CGFloat = 48      // classic launcher icon size

let projectDir = FileManager.default.currentDirectoryPath
let resRoot = projectDir + "/app/src"
let previewDir = projectDir + "/../../dist/bar-apps/icons"
let fluentDir = projectDir + "/tools/fluent"

func color(_ hex: String, alpha: CGFloat = 1) -> CGColor {
    var v: UInt64 = 0
    Scanner(string: hex).scanHexInt64(&v)
    return CGColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                   green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: alpha)
}

func whiteAlpha(_ a: CGFloat) -> CGColor { CGColor(srgbRed: 1, green: 1, blue: 1, alpha: a) }
func blackAlpha(_ a: CGFloat) -> CGColor { CGColor(srgbRed: 0, green: 0, blue: 0, alpha: a) }
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

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

// MARK: - Fluent Emoji artwork

/// A Fluent 3D PNG cropped to its opaque bounds (the originals carry a transparent margin that differs per emoji).
struct Artwork {
    let image: CGImage
    var width: CGFloat { CGFloat(image.width) }
    var height: CGFloat { CGFloat(image.height) }
}

var artworkCache: [String: Artwork] = [:]

func loadArtwork(_ file: String) -> Artwork {
    if let cached = artworkCache[file] { return cached }
    let path = "\(fluentDir)/\(file)"
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let raw = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("cannot read \(path)")
    }
    // Draw into a known RGBA8 layout, then scan the alpha channel for the opaque bounding box.
    let w = raw.width, h = raw.height
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(raw, in: CGRect(x: 0, y: 0, width: w, height: h))
    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in 0..<h { for x in 0..<w where pixels[(y * w + x) * 4 + 3] > 8 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    } }
    precondition(maxX >= minX && maxY >= minY, "\(file) is fully transparent")
    let crop = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    let art = Artwork(image: raw.cropping(to: crop)!)
    artworkCache[file] = art
    return art
}

// MARK: - Background

/// Vertical two-tone gradient (lighter top) plus a soft radial highlight near the top-left, clipped to `clip`.
/// `span` is the vertical range the gradient runs over (the visible part of the icon); outside it the colours clamp.
func drawBackground(_ flavor: Flavor, clip: CGPath, span: CGRect, _ cg: CGContext) {
    cg.saveGState()
    cg.addPath(clip)
    cg.clip()
    let gradient = CGGradient(colorsSpace: srgb, colors: [color(flavor.top), color(flavor.bottom)] as CFArray,
                              locations: [0, 1])!
    cg.drawLinearGradient(gradient, start: CGPoint(x: span.midX, y: span.maxY), end: CGPoint(x: span.midX, y: span.minY),
                          options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // soft highlight, top-left
    let hl = CGGradient(colorsSpace: srgb, colors: [whiteAlpha(0.30), whiteAlpha(0.10), whiteAlpha(0)] as CFArray,
                        locations: [0, 0.45, 1])!
    let c = CGPoint(x: span.minX + span.width * 0.28, y: span.minY + span.height * 0.78)
    cg.drawRadialGradient(hl, startCenter: c, startRadius: 0, endCenter: c, endRadius: span.width * 0.75,
                          options: [])
    // a touch darker along the bottom so the base feels grounded
    let shade = CGGradient(colorsSpace: srgb, colors: [blackAlpha(0.14), blackAlpha(0)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(shade, start: CGPoint(x: span.midX, y: span.minY), end: CGPoint(x: span.midX, y: span.minY + span.height * 0.45),
                          options: [.drawsBeforeStartLocation])
    cg.restoreGState()
}

// MARK: - Glyphs

func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)
}
func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Claude's mark: 12 rounded rays of alternating length radiating from the centre. Unit space 0...1.
func drawClaude(_ cg: CGContext, color tint: CGColor) {
    let c = P(0.5, 0.5)
    let lineWidth: CGFloat = 0.092
    let longLen: CGFloat = 0.50 - lineWidth / 2
    let shortLen: CGFloat = 0.36 - lineWidth / 2
    cg.saveGState()
    cg.setStrokeColor(tint); cg.setFillColor(tint)
    cg.setLineWidth(lineWidth); cg.setLineCap(.round)
    for i in 0..<12 {
        let a = CGFloat(i) * .pi / 6 + .pi / 12          // 30° steps, rotated so no ray is dead vertical
        let len = i % 2 == 0 ? longLen : shortLen
        cg.move(to: c); cg.addLine(to: P(c.x + cos(a) * len, c.y + sin(a) * len)); cg.strokePath()
    }
    cg.addPath(circle(c, lineWidth * 0.7)); cg.fillPath()
    cg.restoreGState()
}

/// A house: pitched roof with a chimney, body with a door. Unit space 0...1, (0,0) top-left.
func drawHouse(_ cg: CGContext, color tint: CGColor) {
    cg.saveGState()
    cg.setFillColor(tint); cg.setStrokeColor(tint)
    cg.setLineWidth(0.11); cg.setLineJoin(.round); cg.setLineCap(.round)
    // roof: stroked chevron
    cg.move(to: P(0.08, 0.50)); cg.addLine(to: P(0.50, 0.12)); cg.addLine(to: P(0.92, 0.50)); cg.strokePath()
    // chimney
    cg.fill(CGRect(x: 0.66, y: 0.14, width: 0.12, height: 0.22))
    // body
    cg.addPath(rounded(CGRect(x: 0.20, y: 0.46, width: 0.60, height: 0.44), 0.04)); cg.fillPath()
    // door, cut out of the body
    cg.setBlendMode(.clear)
    cg.addPath(rounded(CGRect(x: 0.42, y: 0.62, width: 0.16, height: 0.28), 0.03)); cg.fillPath()
    cg.restoreGState()
}

/// Draws the Fluent artwork centred in `box` with high-quality scaling. It is sized by area (a square emoji fills the
/// box; a wide one such as the airplane grows a little so it carries the same visual weight), with its long side
/// capped at 112 % of the box so nothing leaves the adaptive-icon safe zone.
func drawFluent(_ art: Artwork, in box: CGRect, _ cg: CGContext) {
    let k = min(box.width / sqrt(art.width * art.height), box.width * 1.12 / max(art.width, art.height))
    let w = art.width * k, h = art.height * k
    cg.saveGState()
    cg.interpolationQuality = .high
    cg.draw(art.image, in: CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h))
    cg.restoreGState()
}

/// Draws the flavor's glyph filling `box` (a square, in the context's current points) with a soft drop shadow.
func drawGlyph(_ flavor: Flavor, in box: CGRect, _ cg: CGContext) {
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -box.width * 0.05), blur: box.width * 0.12, color: blackAlpha(0.42))
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    switch flavor.glyph {
    case .fluent(let file):
        drawFluent(loadArtwork(file), in: box, cg)
    case .claude:
        // unit space: (0,0) top-left, (1,1) bottom-right
        cg.translateBy(x: box.minX, y: box.maxY)
        cg.scaleBy(x: box.width, y: -box.height)
        drawClaude(cg, color: color(flavor.glyphColor))
    case .house:
        cg.translateBy(x: box.minX, y: box.maxY)
        cg.scaleBy(x: box.width, y: -box.height)
        drawHouse(cg, color: color(flavor.glyphColor))
    }
    cg.endTransparencyLayer()
    cg.restoreGState()
}

// MARK: - Compositions

/// Composed icon (rounded square with 20 % corner radius: gradient, highlight, 1-px inner edge, glyph) at `px` pixels.
func composed(_ flavor: Flavor, px: Int) -> NSBitmapImageRep {
    render(px: px) { cg in
        let size = CGFloat(px)
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let shape = rounded(rect, size * 0.2)
        drawBackground(flavor, clip: shape, span: rect, cg)
        // 1-px inner edge
        cg.saveGState()
        cg.addPath(shape); cg.clip()
        cg.setStrokeColor(whiteAlpha(0.22)); cg.setLineWidth(2)
        cg.addPath(rounded(rect.insetBy(dx: 0.5, dy: 0.5), size * 0.2 - 0.5)); cg.strokePath()
        cg.restoreGState()
        let g = size * glyphFraction
        drawGlyph(flavor, in: CGRect(x: (size - g) / 2, y: (size - g) / 2, width: g, height: g), cg)
    }
}

for flavor in flavors {
    let flavorRes = flavor.resDir.map { "\(projectDir)/\($0)" } ?? "\(resRoot)/\(flavor.name)/res"
    for (density, scale) in densities {
        let px = Int(adaptiveDp * scale)
        let canvas = CGRect(x: 0, y: 0, width: CGFloat(px), height: CGFloat(px))
        let safeInset = (adaptiveDp - safeDp) / 2 * scale
        let safe = canvas.insetBy(dx: safeInset, dy: safeInset)
        // adaptive background: full 108 dp canvas, gradient spanning the visible (safe) part
        let bg = render(px: px) { cg in
            drawBackground(flavor, clip: CGPath(rect: canvas, transform: nil), span: safe, cg)
        }
        writePNG(bg, to: "\(flavorRes)/mipmap-\(density)/ic_launcher_background.png")
        // adaptive foreground: transparent 108 dp canvas, glyph centred in the safe zone
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
        <color name="ic_launcher_background">#\(flavor.bottom)</color>
    </resources>

    """
    try! FileManager.default.createDirectory(atPath: "\(flavorRes)/values", withIntermediateDirectories: true)
    try! colorsXml.write(toFile: "\(flavorRes)/values/ic_launcher_background.xml", atomically: true, encoding: .utf8)
    writePNG(composed(flavor, px: 216), to: "\(previewDir)/\(flavor.name).png")
    writePNG(composed(flavor, px: 240), to: "\(previewDir)/\(flavor.name)-240.png")
    print("\(flavor.name): icons written")
}
