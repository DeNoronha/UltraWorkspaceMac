import Foundation
import AppKit
import CoreGraphics

/// Renders a World Clock card (2-3 cities at once) into RGBA8888, in a
/// consistent style with StatCard / the weather card. Round-first (240 AMOLED).
///
/// Returned bytes follow the same contract as StatCard: row-major
/// RGBA8888 from a CGContext with premultipliedLast | byteOrder32Big,
/// size x size, bottom-left origin (NOT flipped).
@MainActor
enum WorldClockCard {
    static let defaultZones = ["Europe/Amsterdam", "America/New_York", "Asia/Tokyo"]

    static func render(size: Int, zones: [String], clock24h: Bool, now: Date = Date()) -> [UInt8]? {
        let W = CGFloat(size), H = CGFloat(size)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size * 4, space: cs, bitmapInfo: info) else { return nil }

        // Calm indigo/blue vertical gradient (top -> bottom).
        let top = c(0.20, 0.24, 0.52), bottom = c(0.05, 0.06, 0.17)
        if let g = CGGradient(colorsSpace: cs, colors: [top, bottom] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])
        }

        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns

        // Title top-left, SF Symbol top-right.
        drawText("World Clock", W * 0.085, .semibold, NSColor.white.withAlphaComponent(0.9),
                 CGRect(x: W * 0.07, y: H * 0.86, width: W * 0.7, height: H * 0.12))
        drawSymbol("globe", color: .white, rect: CGRect(x: W * 0.78, y: H * 0.84, width: W * 0.14, height: W * 0.14))

        // Up to 3 rows, evenly laid out in the vertical space below the title.
        let shown = Array(zones.prefix(3))
        if shown.isEmpty {
            drawText("No zones", W * 0.10, .medium, NSColor.white.withAlphaComponent(0.8),
                     CGRect(x: 0, y: H * 0.42, width: W, height: W * 0.14), align: .center)
        } else {
            let localDay = dayIndex(for: now, zone: .current)
            // Band below the title: from ~6% to ~78% of height.
            let bandTop = H * 0.78, bandBottom = H * 0.06
            let band = bandTop - bandBottom
            let n = CGFloat(shown.count)
            let slot = band / n
            for (i, id) in shown.enumerated() {
                let isHome = (i == 0)
                // Row baseline centre (bottom-left origin => first zone highest).
                let yCentre = bandTop - slot * (CGFloat(i) + 0.5)
                let labelSize = isHome ? W * 0.105 : W * 0.085
                let timeSize = isHome ? W * 0.145 : W * 0.115
                let labelWeight: NSFont.Weight = isHome ? .bold : .medium
                let timeWeight: NSFont.Weight = isHome ? .bold : .semibold
                let alpha = isHome ? 1.0 : 0.88

                let zone = TimeZone(identifier: id) ?? .current
                let city = cityLabel(from: id)
                let time = timeString(for: now, zone: zone, clock24h: clock24h)

                // Left: city label.
                drawText(city, labelSize, labelWeight, NSColor.white.withAlphaComponent(alpha),
                         CGRect(x: W * 0.09, y: yCentre - labelSize * 0.7, width: W * 0.52, height: labelSize * 1.4))

                // Optional day-offset tag beneath the city label.
                let off = dayIndex(for: now, zone: zone) - localDay
                if off != 0 {
                    let tag = off > 0 ? "+\(off)d" : "\u{2212}\(-off)d"
                    drawText(tag, W * 0.055, .medium, NSColor.white.withAlphaComponent(0.6),
                             CGRect(x: W * 0.09, y: yCentre - labelSize * 0.7 - W * 0.055, width: W * 0.5, height: W * 0.07))
                }

                // Right: time in that zone.
                drawText(time, timeSize, timeWeight, NSColor.white.withAlphaComponent(alpha),
                         CGRect(x: W * 0.40, y: yCentre - timeSize * 0.7, width: W * 0.52, height: timeSize * 1.4),
                         align: .right)

                // Thin divider between rows.
                if i < shown.count - 1 {
                    let dy = bandTop - slot * (CGFloat(i) + 1)
                    ctx.setFillColor(CGColor(gray: 1, alpha: 0.12))
                    ctx.fill(CGRect(x: W * 0.09, y: dy, width: W * 0.82, height: max(1, W * 0.004)))
                }
            }
        }

        NSGraphicsContext.restoreGraphicsState()
        guard let data = ctx.data else { return nil }
        let count = size * size * 4
        return Array(UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: count), count: count))
    }

    // MARK: helpers

    /// Short city label from the identifier's last path component ("_" -> " ").
    private static func cityLabel(from identifier: String) -> String {
        let last = identifier.split(separator: "/").last.map(String.init) ?? identifier
        return last.replacingOccurrences(of: "_", with: " ")
    }

    private static func timeString(for date: Date, zone: TimeZone, clock24h: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = clock24h ? "HH:mm" : "h:mm a"
        return f.string(from: date)
    }

    /// Absolute day number in a given time zone, for day-offset comparison.
    private static func dayIndex(for date: Date, zone: TimeZone) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        let y = c.year ?? 0, m = c.month ?? 0, d = c.day ?? 0
        return y * 372 + m * 31 + d
    }

    // MARK: primitives (match StatCard exactly)

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
