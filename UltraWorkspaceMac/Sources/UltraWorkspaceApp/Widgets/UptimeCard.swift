import Foundation
import AppKit
import CoreGraphics
import Darwin

/// Renders an "Uptime & load" card into RGBA8888, matching StatCard's style
/// (dark gradient, title top-left, SF Symbol top-right). Square-first (240).
/// Reads uptime from `kern.boottime` and load averages from `getloadavg`.
@MainActor
enum UptimeCard {
    static func render(size: Int) -> [UInt8]? {
        let up = uptimeSeconds()
        let loads = loadAverages()

        let W = CGFloat(size), H = CGFloat(size)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size*4, space: cs, bitmapInfo: info) else { return nil }

        // Teal -> indigo gradient (top to bottom).
        let top = CGColor(red: 0.08, green: 0.34, blue: 0.40, alpha: 1)
        let bottom = CGColor(red: 0.12, green: 0.10, blue: 0.28, alpha: 1)
        if let g = CGGradient(colorsSpace: cs, colors: [top, bottom] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])
        }

        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns

        // Header: title top-left, symbol top-right (same metrics as StatCard).
        drawText("Uptime", W*0.085, .semibold, NSColor.white.withAlphaComponent(0.9),
                 CGRect(x: W*0.07, y: H*0.86, width: W*0.7, height: H*0.12))
        drawSymbol("clock.arrow.circlepath", color: .white,
                   rect: CGRect(x: W*0.78, y: H*0.84, width: W*0.14, height: W*0.14))

        // Big centered uptime value + "since ..." sublabel.
        let value = compactUptime(up)
        drawText(value, W*0.22, .bold, .white,
                 CGRect(x: 0, y: W*0.52, width: W, height: W*0.24), align: .center)
        let since = up != nil ? "since \(sinceLabel(bootDate: Date().addingTimeInterval(-up!)))" : "unavailable"
        drawText(since, W*0.075, .regular, NSColor.white.withAlphaComponent(0.75),
                 CGRect(x: 0, y: W*0.435, width: W, height: W*0.08), align: .center)

        // Bottom row: load averages.
        let loadText: String = {
            guard let l = loads else { return "load unavailable" }
            return String(format: "load %.2f \u{00B7} %.2f \u{00B7} %.2f", l.0, l.1, l.2)
        }()
        drawText(loadText, W*0.075, .medium, NSColor.white.withAlphaComponent(0.9),
                 CGRect(x: W*0.06, y: H*0.11, width: W*0.88, height: W*0.1), align: .center)

        NSGraphicsContext.restoreGraphicsState()

        guard let data = ctx.data else { return nil }
        let count = size*size*4
        return Array(UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: count), count: count))
    }

    // MARK: metrics

    private static func uptimeSeconds() -> TimeInterval? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0, tv.tv_sec != 0 else { return nil }
        let boot = TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000
        let delta = Date().timeIntervalSince1970 - boot
        return delta > 0 ? delta : nil
    }

    private static func loadAverages() -> (Double, Double, Double)? {
        var l = [Double](repeating: 0, count: 3)
        guard getloadavg(&l, 3) == 3 else { return nil }
        return (l[0], l[1], l[2])
    }

    // MARK: formatting

    private static func compactUptime(_ seconds: TimeInterval?) -> String {
        guard let s = seconds else { return "--" }
        let total = Int(s)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private static func sinceLabel(bootDate: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        // Show weekday + time if recent-ish; always compact.
        f.dateFormat = "EEE d MMM, HH:mm"
        return f.string(from: bootDate)
    }

    // MARK: primitives (mirrors StatCard)

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
}
