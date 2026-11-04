#!/usr/bin/swift
// Renders the launcher icons for every Deckhand bar-app flavor.
//
//   swift tools/make-icons.swift            (run from android/DeckhandMonitor)
//
// Per flavor it writes, under app/src/<flavor>/res/:
//   mipmap-<density>/ic_launcher_background.png   adaptive-icon background, 108 dp canvas: vertical two-tone
//                                                 gradient with a soft radial highlight top-left
//   mipmap-<density>/ic_launcher_foreground.png   adaptive-icon foreground, 108 dp canvas: white illustrated
//                                                 glyph with a soft drop shadow, inside the 72 dp safe zone
//   mipmap-<density>/ic_launcher.png              legacy 48 dp icon: rounded square (20 % radius) composed
//   values/ic_launcher_background.xml             the flavor's base colour (kept for anything that reads it)
// and previews of the composed icon to ../../dist/bar-apps/icons/<flavor>.png (216 px) and <flavor>-240.png.
//
// Everything is drawn with Core Graphics; no external assets. The bar shows the icons at about 240 px on a
// card, so every glyph is a small illustration rather than a bare symbol; they still read at 48 px.

import AppKit
import CoreText
import Foundation

struct Flavor {
    let name: String
    let top: String             // gradient top colour, hex rrggbb (lighter)
    let bottom: String          // gradient bottom colour, hex rrggbb (darker)
    let glyphColor: String      // hex rrggbb
    let glyph: Glyph
}

enum Glyph {
    case monitor, crypto, weather, music, calendar, claude, flights, sky, news, verse, tasks
}

let flavors: [Flavor] = [
    Flavor(name: "monitor",  top: "3b63d6", bottom: "1b3380", glyphColor: "ffffff", glyph: .monitor),
    Flavor(name: "crypto",   top: "f2a21a", bottom: "a84a07", glyphColor: "ffffff", glyph: .crypto),
    Flavor(name: "weather",  top: "26a9c9", bottom: "0b667f", glyphColor: "ffffff", glyph: .weather),
    Flavor(name: "music",    top: "f04a6a", bottom: "a50f35", glyphColor: "ffffff", glyph: .music),
    Flavor(name: "calendar", top: "2cc06a", bottom: "116b33", glyphColor: "ffffff", glyph: .calendar),
    Flavor(name: "claude",   top: "3e3531", bottom: "1e1917", glyphColor: "d97757", glyph: .claude),
    Flavor(name: "flights",  top: "1fb5a3", bottom: "0c6660", glyphColor: "ffffff", glyph: .flights),
    Flavor(name: "sky",      top: "5a53d4", bottom: "272468", glyphColor: "ffffff", glyph: .sky),
    Flavor(name: "news",     top: "b8552f", bottom: "6e2710", glyphColor: "ffffff", glyph: .news),
    Flavor(name: "verse",    top: "9b4fd6", bottom: "5b1a92", glyphColor: "ffffff", glyph: .verse),
    Flavor(name: "tasks",    top: "7d87ea", bottom: "4a52b8", glyphColor: "ffffff", glyph: .tasks),
]

// density name -> scale factor (mdpi = 1 px per dp)
let densities: [(String, CGFloat)] = [("mdpi", 1), ("hdpi", 1.5), ("xhdpi", 2), ("xxhdpi", 3), ("xxxhdpi", 4)]

let adaptiveDp: CGFloat = 108   // adaptive icon canvas
let safeDp: CGFloat = 72        // content must stay inside the central 72 dp (66 dp circle is the official mask)
let glyphDp: CGFloat = 42       // bounding box of the glyph inside the safe zone (58 % of it)
let legacyDp: CGFloat = 48      // classic launcher icon size
let glyphFraction: CGFloat = 0.58   // glyph box as a fraction of a composed (square) icon

func color(_ hex: String, alpha: CGFloat = 1) -> CGColor {
    var v: UInt64 = 0
    Scanner(string: hex).scanHexInt64(&v)
    return CGColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                   green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: alpha)
}

let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
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

// MARK: - Glyph drawing helpers (unit space: 0...1, y down)

struct Pen {
    let cg: CGContext

    func fill(_ path: CGPath, _ c: CGColor = white) {
        cg.saveGState(); cg.setFillColor(c); cg.addPath(path); cg.fillPath(); cg.restoreGState()
    }
    /// Punches the path out of what has been drawn so far (the background shows through).
    func clear(_ path: CGPath) {
        cg.saveGState(); cg.setBlendMode(.clear); cg.addPath(path); cg.fillPath(); cg.restoreGState()
    }
    func stroke(_ path: CGPath, width: CGFloat, _ c: CGColor = white, cap: CGLineCap = .round, join: CGLineJoin = .round) {
        cg.saveGState(); cg.setStrokeColor(c); cg.setLineWidth(width); cg.setLineCap(cap); cg.setLineJoin(join)
        cg.addPath(path); cg.strokePath(); cg.restoreGState()
    }
    func clearStroke(_ path: CGPath, width: CGFloat, cap: CGLineCap = .round, join: CGLineJoin = .round) {
        cg.saveGState(); cg.setBlendMode(.clear); cg.setLineWidth(width); cg.setLineCap(cap); cg.setLineJoin(join)
        cg.addPath(path); cg.strokePath(); cg.restoreGState()
    }
    func line(_ a: CGPoint, _ b: CGPoint, width: CGFloat, _ c: CGColor = white) {
        let p = CGMutablePath(); p.move(to: a); p.addLine(to: b); stroke(p, width: width, c)
    }
    func clearLine(_ a: CGPoint, _ b: CGPoint, width: CGFloat) {
        let p = CGMutablePath(); p.move(to: a); p.addLine(to: b); clearStroke(p, width: width)
    }
}

func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)
}
func ellipse(_ c: CGPoint, rx: CGFloat, ry: CGFloat, rotation: CGFloat = 0) -> CGPath {
    var t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: rotation)
    return CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: 2 * rx, height: 2 * ry), transform: &t)
}
func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}
func polygon(_ pts: [CGPoint]) -> CGPath {
    let p = CGMutablePath(); p.addLines(between: pts); p.closeSubpath(); return p
}
func star4(_ c: CGPoint, _ r: CGFloat, inner: CGFloat = 0.38) -> CGPath {
    var pts: [CGPoint] = []
    for i in 0..<8 {
        let a = CGFloat(i) * .pi / 4 - .pi / 2
        let rr = i % 2 == 0 ? r : r * inner
        pts.append(P(c.x + cos(a) * rr, c.y + sin(a) * rr))
    }
    return polygon(pts)
}

/// Outline path of a character in the bold system font, scaled so its cap height fits `height`, centred on `c`.
func textPath(_ s: String, height: CGFloat, at c: CGPoint) -> CGPath? {
    let base = NSFont.systemFont(ofSize: 1, weight: .heavy) as CTFont
    let font = CTFontCreateForString(base, s as CFString, CFRange(location: 0, length: s.utf16.count))
    var chars = Array(s.utf16)
    var glyphs = [CGGlyph](repeating: 0, count: chars.count)
    guard CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count), let g = glyphs.first, g != 0,
          let raw = CTFontCreatePathForGlyph(font, g, nil) else { return nil }
    let b = raw.boundingBoxOfPath
    let k = height / b.height
    // text space is y-up; our unit space is y-down
    var t = CGAffineTransform(translationX: c.x, y: c.y).scaledBy(x: k, y: -k).translatedBy(x: -b.midX, y: -b.midY)
    return raw.copy(using: &t)
}

// MARK: - Glyphs

func drawMonitor(_ pen: Pen) {
    let pts = [P(0.04, 0.66), P(0.24, 0.44), P(0.40, 0.56), P(0.60, 0.24), P(0.76, 0.38), P(0.96, 0.14)]
    let base: CGFloat = 0.86
    let area = CGMutablePath()
    area.move(to: P(pts[0].x, base))
    for p in pts { area.addLine(to: p) }
    area.addLine(to: P(pts.last!.x, base))
    area.closeSubpath()
    pen.fill(area, whiteAlpha(0.30))
    let line = CGMutablePath()
    line.move(to: pts[0])
    for p in pts.dropFirst() { line.addLine(to: p) }
    pen.stroke(line, width: 0.10)
    pen.line(P(0.04, base + 0.07), P(0.96, base + 0.07), width: 0.055, whiteAlpha(0.75))
    pen.fill(circle(pts.last!, 0.085))
}

func drawCrypto(_ pen: Pen) {
    let c = P(0.5, 0.5)
    pen.fill(circle(c, 0.47))
    pen.clearStroke(circle(c, 0.395), width: 0.028)
    if let b = textPath("₿", height: 0.50, at: P(0.505, 0.50)) {
        pen.clear(b)
    } else if let b = textPath("B", height: 0.46, at: c) {
        pen.clear(b)
    }
}

func drawWeather(_ pen: Pen) {
    let sun = P(0.64, 0.36), r: CGFloat = 0.16
    let sunColor = color("ffe27a")
    for i in 0..<8 {
        let a = CGFloat(i) * .pi / 4
        pen.line(P(sun.x + cos(a) * 0.235, sun.y + sin(a) * 0.235), P(sun.x + cos(a) * 0.31, sun.y + sin(a) * 0.31),
                 width: 0.07, sunColor)
    }
    pen.fill(circle(sun, r), sunColor)
    // cloud: three lobes on a rounded base
    let cloud = CGMutablePath()
    cloud.addPath(circle(P(0.30, 0.63), 0.16))
    cloud.addPath(circle(P(0.47, 0.54), 0.20))
    cloud.addPath(circle(P(0.64, 0.65), 0.14))
    cloud.addPath(rounded(CGRect(x: 0.14, y: 0.63, width: 0.64, height: 0.20), 0.10))
    pen.clearStroke(cloud, width: 0.07)   // breathing room between cloud and sun
    pen.fill(cloud)
}

func drawMusic(_ pen: Pen) {
    let w: CGFloat = 0.085
    let h1 = P(0.25, 0.78), h2 = P(0.69, 0.70)
    let s1x = h1.x + 0.125, s2x = h2.x + 0.125
    let top1: CGFloat = 0.24, top2: CGFloat = 0.16
    pen.fill(ellipse(h1, rx: 0.165, ry: 0.115, rotation: -0.35))
    pen.fill(ellipse(h2, rx: 0.165, ry: 0.115, rotation: -0.35))
    pen.line(P(s1x, h1.y - 0.04), P(s1x, top1), width: w)
    pen.line(P(s2x, h2.y - 0.04), P(s2x, top2), width: w)
    // beam
    let beam = polygon([P(s1x - w / 2, top1 - 0.08), P(s2x + w / 2, top2 - 0.08),
                        P(s2x + w / 2, top2 + 0.10), P(s1x - w / 2, top1 + 0.10)])
    pen.fill(beam)
    pen.stroke(beam, width: 0.04)
}

func drawCalendar(_ pen: Pen) {
    let page = CGRect(x: 0.06, y: 0.14, width: 0.88, height: 0.80)
    pen.fill(rounded(page, 0.11))
    pen.clearLine(P(page.minX, 0.40), P(page.maxX, 0.40), width: 0.045)
    for x in [0.30, 0.70] as [CGFloat] {
        pen.clearLine(P(x, 0.07), P(x, 0.25), width: 0.17)
        pen.line(P(x, 0.07), P(x, 0.25), width: 0.085)
    }
    let xs: [CGFloat] = [0.29, 0.50, 0.71], ys: [CGFloat] = [0.56, 0.76]
    for y in ys { for x in xs {
        if x == 0.71 && y == 0.76 {
            pen.clear(circle(P(x, y), 0.095))
            pen.fill(circle(P(x, y), 0.05))
        } else {
            pen.clear(circle(P(x, y), 0.05))
        }
    } }
}

/// Claude's mark: 12 rounded rays of alternating length radiating from the centre.
func drawClaude(_ pen: Pen, color tint: CGColor) {
    let c = P(0.5, 0.5)
    let lineWidth: CGFloat = 0.092
    let longLen: CGFloat = 0.50 - lineWidth / 2
    let shortLen: CGFloat = 0.36 - lineWidth / 2
    for i in 0..<12 {
        let a = CGFloat(i) * .pi / 6 + .pi / 12          // 30° steps, rotated so no ray is dead vertical
        let len = i % 2 == 0 ? longLen : shortLen
        pen.line(c, P(c.x + cos(a) * len, c.y + sin(a) * len), width: lineWidth, tint)
    }
    pen.fill(circle(c, lineWidth * 0.7), tint)
}

func drawFlights(_ pen: Pen) {
    let c = P(0.5, 0.5)
    pen.stroke(circle(c, 0.47), width: 0.03, whiteAlpha(0.35))
    pen.stroke(circle(c, 0.30), width: 0.025, whiteAlpha(0.18))
    pen.cg.saveGState()
    pen.cg.translateBy(x: c.x, y: c.y)
    pen.cg.rotate(by: .pi / 4)          // nose to the top-right
    pen.cg.scaleBy(x: 0.86, y: 0.86)
    pen.cg.translateBy(x: -c.x, y: -c.y)
    let wings = polygon([P(0.50, 0.30), P(0.04, 0.59), P(0.04, 0.71), P(0.50, 0.60), P(0.96, 0.71), P(0.96, 0.59)])
    let tail = polygon([P(0.50, 0.68), P(0.29, 0.86), P(0.29, 0.94), P(0.50, 0.86), P(0.71, 0.94), P(0.71, 0.86)])
    pen.stroke(wings, width: 0.035); pen.fill(wings)
    pen.stroke(tail, width: 0.035); pen.fill(tail)
    pen.line(P(0.50, 0.13), P(0.50, 0.86), width: 0.15)
    pen.cg.restoreGState()
}

func drawSky(_ pen: Pen) {
    pen.fill(circle(P(0.40, 0.55), 0.34))
    pen.clear(circle(P(0.57, 0.42), 0.30))
    pen.fill(star4(P(0.74, 0.22), 0.13))
    pen.fill(star4(P(0.86, 0.52), 0.08))
}

func drawNews(_ pen: Pen) {
    let paper = CGRect(x: 0.06, y: 0.18, width: 0.88, height: 0.64)
    pen.fill(rounded(paper, 0.09))
    pen.clear(rounded(CGRect(x: 0.17, y: 0.30, width: 0.28, height: 0.24), 0.03))
    pen.clearLine(P(0.55, 0.34), P(0.83, 0.34), width: 0.055)
    pen.clearLine(P(0.55, 0.46), P(0.77, 0.46), width: 0.055)
    pen.clearLine(P(0.17, 0.63), P(0.83, 0.63), width: 0.04)
    pen.clearLine(P(0.17, 0.71), P(0.70, 0.71), width: 0.04)
}

func drawVerse(_ pen: Pen) {
    let left = CGMutablePath()
    left.move(to: P(0.50, 0.27))
    left.addCurve(to: P(0.08, 0.20), control1: P(0.40, 0.18), control2: P(0.24, 0.14))
    left.addLine(to: P(0.08, 0.80))
    left.addCurve(to: P(0.50, 0.88), control1: P(0.24, 0.76), control2: P(0.40, 0.80))
    left.closeSubpath()
    var mirror = CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -1, y: 0)
    let right = left.copy(using: &mirror)!
    let book = CGMutablePath(); book.addPath(left); book.addPath(right)
    // cover peeking out underneath
    var down = CGAffineTransform(translationX: 0, y: 0.06)
    pen.fill(book.copy(using: &down)!, whiteAlpha(0.45))
    pen.fill(book)
    pen.clearLine(P(0.50, 0.27), P(0.50, 0.88), width: 0.035)
    for (i, y) in ([0.40, 0.50, 0.60] as [CGFloat]).enumerated() {
        let len: CGFloat = i == 2 ? 0.14 : 0.20
        pen.clearLine(P(0.19, y + 0.015), P(0.19 + len, y - 0.015), width: 0.035)
        pen.clearLine(P(0.81, y + 0.015), P(0.81 - len, y - 0.015), width: 0.035)
    }
}

func drawTasks(_ pen: Pen) {
    let box: CGFloat = 0.23
    for (i, y) in ([0.19, 0.50, 0.81] as [CGFloat]).enumerated() {
        let r = CGRect(x: 0.06, y: y - box / 2, width: box, height: box)
        if i < 2 {
            pen.fill(rounded(r, 0.055))
            let check = CGMutablePath()
            check.addLines(between: [P(r.minX + 0.055, y + 0.005), P(r.minX + 0.10, y + 0.055), P(r.maxX - 0.05, y - 0.055)])
            pen.clearStroke(check, width: 0.045)
        } else {
            pen.stroke(rounded(r.insetBy(dx: 0.022, dy: 0.022), 0.04), width: 0.044)
        }
        pen.line(P(0.42, y), P(0.94, y), width: 0.10, i < 2 ? white : whiteAlpha(0.65))
    }
}

/// Draws the flavor's glyph filling `box` (a square, in the context's current points), white with a soft shadow.
func drawGlyph(_ flavor: Flavor, in box: CGRect, _ cg: CGContext) {
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -box.width * 0.045), blur: box.width * 0.10, color: blackAlpha(0.38))
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    // unit space: (0,0) top-left, (1,1) bottom-right
    cg.translateBy(x: box.minX, y: box.maxY)
    cg.scaleBy(x: box.width, y: -box.height)
    let pen = Pen(cg: cg)
    switch flavor.glyph {
    case .monitor:  drawMonitor(pen)
    case .crypto:   drawCrypto(pen)
    case .weather:  drawWeather(pen)
    case .music:    drawMusic(pen)
    case .calendar: drawCalendar(pen)
    case .claude:   drawClaude(pen, color: color(flavor.glyphColor))
    case .flights:  drawFlights(pen)
    case .sky:      drawSky(pen)
    case .news:     drawNews(pen)
    case .verse:    drawVerse(pen)
    case .tasks:    drawTasks(pen)
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

let projectDir = FileManager.default.currentDirectoryPath
let resRoot = projectDir + "/app/src"
let previewDir = projectDir + "/../../dist/bar-apps/icons"

for flavor in flavors {
    let flavorRes = "\(resRoot)/\(flavor.name)/res"
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
