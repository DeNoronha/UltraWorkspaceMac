import Foundation
import AppKit
import CoreGraphics

/// Renders a Calendar / next-event card into row-major RGBA8888 for the 240×240
/// round AMOLED display, in the same visual language as `StatCard` (dark
/// vertical-gradient background, title top-left, SF Symbol top-right).
///
/// The returned bytes come from a CGContext with
/// `premultipliedLast | byteOrder32Big`, size×size, bottom-left origin (NOT
/// flipped), exactly as `StatCard` produces them.
@MainActor
enum CalendarCard {

    static func render(_ events: [CalEvent], auth: CalAuth, size: Int, clock24h: Bool) -> [UInt8]? {
        // Deep blue/teal gradient background.
        draw(size: size, accent: (c(0.10, 0.22, 0.42), c(0.04, 0.08, 0.16)),
             title: "Calendar", icon: "calendar") { g, W, H in

            if auth != .authorized {
                center(g, "Grant Calendar access", size: W*0.088, weight: .semibold,
                       color: .white, W: W, y: H*0.50)
                center(g, "in System Settings → Privacy", size: W*0.058, weight: .regular,
                       color: NSColor.white.withAlphaComponent(0.65), W: W, y: H*0.40)
                return
            }

            if events.isEmpty {
                drawSymbol("checkmark.circle", color: .systemTeal,
                           rect: CGRect(x: W*0.5 - W*0.13, y: H*0.52, width: W*0.26, height: W*0.26))
                center(g, "No events", size: W*0.13, weight: .bold, color: .white, W: W, y: H*0.34)
                center(g, "You're all clear", size: W*0.06, weight: .regular,
                       color: NSColor.white.withAlphaComponent(0.65), W: W, y: H*0.26)
                return
            }

            // Featured first event.
            let first = events[0]
            let dot = W*0.045
            let dotX = W*0.09
            // Colored dot aligned with the featured title row.
            fillDot(g, color: first.calendarColorRGBA, rect: CGRect(x: dotX, y: H*0.62, width: dot, height: dot))
            drawText(timeString(first, clock24h: clock24h), W*0.11, .bold, .white,
                     CGRect(x: dotX + dot + W*0.03, y: H*0.595, width: W*0.5, height: W*0.14))
            drawText(relativeHint(first), W*0.06, .semibold, NSColor.systemTeal,
                     CGRect(x: W*0.60, y: H*0.615, width: W*0.33, height: W*0.10), align: .right)
            drawText(first.title, W*0.088, .semibold, NSColor.white.withAlphaComponent(0.95),
                     CGRect(x: W*0.09, y: H*0.48, width: W*0.84, height: W*0.12))

            // Divider.
            g.ctx.setFillColor(CGColor(gray: 1, alpha: 0.14))
            g.ctx.fill(CGRect(x: W*0.09, y: H*0.44, width: W*0.82, height: 1))

            // Up to two more compact rows.
            let rows = Array(events.dropFirst().prefix(2))
            var y = H*0.30
            for ev in rows {
                let rdot = W*0.035
                fillDot(g, color: ev.calendarColorRGBA, rect: CGRect(x: dotX, y: y + W*0.02, width: rdot, height: rdot))
                drawText(timeString(ev, clock24h: clock24h), W*0.062, .semibold,
                         NSColor.white.withAlphaComponent(0.85),
                         CGRect(x: dotX + rdot + W*0.025, y: y, width: W*0.22, height: W*0.09))
                drawText(ev.title, W*0.062, .regular, NSColor.white.withAlphaComponent(0.80),
                         CGRect(x: W*0.40, y: y, width: W*0.53, height: W*0.09))
                y -= H*0.11
            }
        }
    }

    // MARK: formatting

    private static func timeString(_ ev: CalEvent, clock24h: Bool) -> String {
        if ev.isAllDay { return "All day" }
        let df = DateFormatter()
        df.dateFormat = clock24h ? "HH:mm" : "h:mm a"
        return df.string(from: ev.start)
    }

    /// A short relative hint: "now", "in 25 min", "in 3 hr".
    private static func relativeHint(_ ev: CalEvent) -> String {
        if ev.isAllDay { return "today" }
        let delta = ev.start.timeIntervalSinceNow
        if delta <= 0 {
            // Started; still "now" while ongoing, else empty.
            return ev.end.timeIntervalSinceNow > 0 ? "now" : ""
        }
        let mins = Int((delta / 60).rounded())
        if mins < 60 { return "in \(max(1, mins)) min" }
        let hrs = Int((delta / 3600).rounded())
        return "in \(hrs) hr"
    }

    // MARK: shared drawing (mirrors StatCard's RGBA contract)

    private typealias GC = (ctx: CGContext, cs: CGColorSpace)

    private static func draw(size: Int, accent: (CGColor, CGColor), title: String, icon: String,
                             body: (GC, CGFloat, CGFloat) -> Void) -> [UInt8]? {
        let W = CGFloat(size), H = CGFloat(size)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size*4, space: cs, bitmapInfo: info) else { return nil }
        if let g = CGGradient(colorsSpace: cs, colors: [accent.0, accent.1] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])
        }
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
        drawText(title, W*0.085, .semibold, NSColor.white.withAlphaComponent(0.9),
                 CGRect(x: W*0.07, y: H*0.86, width: W*0.7, height: H*0.12))
        drawSymbol(icon, color: .white, rect: CGRect(x: W*0.78, y: H*0.84, width: W*0.14, height: W*0.14))
        body((ctx, cs), W, H)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = ctx.data else { return nil }
        let count = size*size*4
        return Array(UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: count), count: count))
    }

    private static func center(_ g: GC, _ text: String, size: CGFloat, weight: NSFont.Weight,
                               color: NSColor, W: CGFloat, y: CGFloat) {
        drawText(text, size, weight, color, CGRect(x: W*0.06, y: y, width: W*0.88, height: size*1.5), align: .center)
    }

    private static func fillDot(_ g: GC, color: (Double, Double, Double), rect: CGRect) {
        let cg = CGColor(red: CGFloat(color.0), green: CGFloat(color.1), blue: CGFloat(color.2), alpha: 1)
        g.ctx.setFillColor(cg)
        g.ctx.fillEllipse(in: rect)
    }

    // primitives (match StatCard exactly)
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
