import Foundation
import AppKit
import CoreGraphics

/// Renders a Battery & Power card into RGBA8888, in the same house style as
/// StatCard (dark vertical-gradient background, title top-left, SF Symbol
/// top-right). Designed for a 240×240 square AMOLED. Square-first.
@MainActor
enum BatteryCard {
    static func render(_ s: BatteryStats.Sample, size: Int) -> [UInt8]? {
        let (ring, bgTop, bgBot): (NSColor, CGColor, CGColor) = accent(for: s)
        return draw(size: size, bg: (bgTop, bgBot),
                    title: "Battery",
                    icon: s.isCharging ? "battery.100.bolt" : "battery.100") { ctx, W, H in
            if !s.hasBattery {
                drawDesktop(ctx, W: W, H: H)
            } else {
                drawGauge(ctx, s: s, ring: ring, W: W, H: H)
            }
        }
    }

    // MARK: accent

    /// Ring/glow color plus the two-stop dark background gradient (tinted).
    private static func accent(for s: BatteryStats.Sample) -> (NSColor, CGColor, CGColor) {
        if !s.hasBattery {
            // Neutral steel-blue "on AC" look.
            return (NSColor(calibratedRed: 0.30, green: 0.58, blue: 0.86, alpha: 1),
                    c(0.09, 0.14, 0.22), c(0.04, 0.06, 0.10))
        }
        if s.percent < 15 {
            return (NSColor(calibratedRed: 0.95, green: 0.27, blue: 0.24, alpha: 1), // red
                    c(0.22, 0.07, 0.07), c(0.09, 0.03, 0.03))
        } else if s.percent < 40 {
            return (NSColor(calibratedRed: 0.98, green: 0.70, blue: 0.18, alpha: 1), // amber
                    c(0.20, 0.14, 0.04), c(0.08, 0.06, 0.02))
        } else {
            return (NSColor(calibratedRed: 0.24, green: 0.80, blue: 0.40, alpha: 1), // green
                    c(0.06, 0.16, 0.10), c(0.03, 0.07, 0.05))
        }
    }

    // MARK: gauge branch

    private static func drawGauge(_ ctx: CGContext, s: BatteryStats.Sample, ring: NSColor, W: CGFloat, H: CGFloat) {
        let cx = W * 0.5, cy = H * 0.48
        let lw = W * 0.12
        let radius = W * 0.33 - lw * 0.5
        let frac = max(0, min(1, s.percent / 100))

        // Track (dim full ring).
        ctx.setLineWidth(lw)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
        ctx.addArc(center: CGPoint(x: cx, y: cy), radius: radius,
                   startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        ctx.strokePath()

        // Charge arc, from 12 o'clock going clockwise, with a soft glow.
        if frac > 0.001 {
            let start = CGFloat.pi / 2
            let end = start - 2 * .pi * frac
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: W * 0.05, color: ring.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(lw)
            ctx.setLineCap(.round)
            ctx.setStrokeColor(ring.cgColor)
            ctx.addArc(center: CGPoint(x: cx, y: cy), radius: radius,
                       startAngle: start, endAngle: end, clockwise: true)
            ctx.strokePath()
            ctx.restoreGState()
        }

        // Big centered percentage.
        let pct = "\(Int(s.percent.rounded()))%"
        drawText(pct, W * 0.22, .bold, .white,
                 CGRect(x: 0, y: cy - W * 0.11, width: W, height: W * 0.24), align: .center)

        // Bolt glyph above the number while charging.
        if s.isCharging {
            drawSymbol("bolt.fill", color: ring,
                       rect: CGRect(x: cx - W * 0.045, y: cy + W * 0.095, width: W * 0.09, height: W * 0.09))
        }

        // Bottom status line.
        let line: String
        if s.isCharging {
            if let m = s.minutesRemaining, m > 0 {
                line = "Charging · \(timeString(m)) to full"
            } else {
                line = "Charging"
            }
        } else if let m = s.minutesRemaining, m > 0 {
            line = "\(Int(s.percent.rounded()))% · \(timeString(m)) left"
        } else if s.isPluggedIn {
            line = "Plugged in"
        } else {
            line = "On battery"
        }
        drawText(line, W * 0.065, .medium, NSColor.white.withAlphaComponent(0.78),
                 CGRect(x: W * 0.06, y: H * 0.075, width: W * 0.88, height: W * 0.09), align: .center)
    }

    // MARK: desktop (no battery) branch

    private static func drawDesktop(_ ctx: CGContext, W: CGFloat, H: CGFloat) {
        let accent = NSColor(calibratedRed: 0.30, green: 0.58, blue: 0.86, alpha: 1)
        // Glowing power-plug symbol, centered.
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: W * 0.06, color: accent.withAlphaComponent(0.8).cgColor)
        drawSymbol("powerplug.fill", color: accent,
                   rect: CGRect(x: W * 0.5 - W * 0.14, y: H * 0.46, width: W * 0.28, height: W * 0.28))
        ctx.restoreGState()

        drawText("On AC power", W * 0.12, .bold, .white,
                 CGRect(x: 0, y: H * 0.30, width: W, height: W * 0.14), align: .center)
        drawText("Desktop Mac · no battery", W * 0.062, .medium,
                 NSColor.white.withAlphaComponent(0.72),
                 CGRect(x: W * 0.06, y: H * 0.22, width: W * 0.88, height: W * 0.08), align: .center)
    }

    // MARK: time helper

    private static func timeString(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    // MARK: shared drawing scaffold (mirrors StatCard exactly)

    private static func draw(size: Int, bg: (CGColor, CGColor), title: String, icon: String,
                             body: (CGContext, CGFloat, CGFloat) -> Void) -> [UInt8]? {
        let W = CGFloat(size), H = CGFloat(size)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size * 4, space: cs, bitmapInfo: info) else { return nil }
        if let g = CGGradient(colorsSpace: cs, colors: [bg.0, bg.1] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])
        }
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
        drawText(title, W * 0.085, .semibold, NSColor.white.withAlphaComponent(0.9),
                 CGRect(x: W * 0.07, y: H * 0.86, width: W * 0.7, height: H * 0.12))
        drawSymbol(icon, color: .white, rect: CGRect(x: W * 0.78, y: H * 0.84, width: W * 0.14, height: W * 0.14))
        body(ctx, W, H)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = ctx.data else { return nil }
        let count = size * size * 4
        return Array(UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: count), count: count))
    }

    // MARK: primitives (mirror StatCard)

    private static func drawText(_ s: String, _ size: CGFloat, _ w: NSFont.Weight, _ color: NSColor, _ rect: CGRect, align: NSTextAlignment = .left) {
        let para = NSMutableParagraphStyle(); para.alignment = align; para.lineBreakMode = .byTruncatingTail
        let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.4); sh.shadowBlurRadius = 2; sh.shadowOffset = .init(width: 0, height: -1)
        (s as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: w), .foregroundColor: color, .paragraphStyle: para, .shadow: sh])
    }

    private static func drawSymbol(_ name: String, color: NSColor, rect: CGRect) {
        let cfg = NSImage.SymbolConfiguration(pointSize: rect.height, weight: .semibold)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
        let tinted = NSImage(size: rect.size); tinted.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: rect.size)); color.set()
        NSRect(origin: .zero, size: rect.size).fill(using: .sourceAtop); tinted.unlockFocus()
        tinted.draw(in: rect)
    }

    private static func c(_ r: Double, _ g: Double, _ b: Double) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: 1) }
}
