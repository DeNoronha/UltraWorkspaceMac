import Foundation
import AppKit
import CoreGraphics

/// Renders a Disk / Storage widget into RGBA8888 for a 240×240 square AMOLED,
/// in a consistent style with StatCard. Reads the startup volume itself —
/// `render` takes NO data argument. Square-first (bottom-left origin, NOT flipped).
@MainActor
enum DiskCard {
    static func render(size: Int) -> [UInt8]? {
        let W = CGFloat(size), H = CGFloat(size)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size*4, space: cs, bitmapInfo: info) else { return nil }

        let cap = Self.capacity()

        // Accent depends on used fraction (teal/blue → amber >80% → red >92%).
        let usedFrac = cap.map { $0.total > 0 ? Double($0.used) / Double($0.total) : 0 } ?? 0
        let accent: (CGColor, CGColor)
        let ring: NSColor
        if usedFrac > 0.92 {
            accent = (c(0.34, 0.10, 0.12), c(0.12, 0.05, 0.06)); ring = .systemRed
        } else if usedFrac > 0.80 {
            accent = (c(0.34, 0.24, 0.07), c(0.13, 0.09, 0.03)); ring = .systemOrange
        } else {
            accent = (c(0.10, 0.30, 0.38), c(0.05, 0.11, 0.16)); ring = .systemTeal
        }

        if let g = CGGradient(colorsSpace: cs, colors: [accent.0, accent.1] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])
        }

        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns

        // Header: title top-left, SF Symbol top-right (same metrics as StatCard).
        drawText("Storage", W*0.085, .semibold, NSColor.white.withAlphaComponent(0.9),
                 CGRect(x: W*0.07, y: H*0.86, width: W*0.7, height: H*0.12))
        drawSymbol("internaldrive", color: .white, rect: CGRect(x: W*0.78, y: H*0.84, width: W*0.14, height: W*0.14))

        if let cap {
            // Circular ring gauge of the USED fraction, centered.
            let cx = W*0.5, cy = H*0.48
            let radius = W*0.30
            let lw = W*0.065
            // Track.
            ctx.setLineWidth(lw)
            ctx.setLineCap(.round)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.15))
            ctx.addArc(center: CGPoint(x: cx, y: cy), radius: radius,
                       startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            ctx.strokePath()
            // Used arc: start at top (12 o'clock), sweep clockwise.
            let f = max(0, min(1, usedFrac))
            if f > 0.001 {
                let start = CGFloat.pi / 2
                let end = start - CGFloat(f) * 2 * .pi
                ctx.setStrokeColor(ring.cgColor)
                ctx.addArc(center: CGPoint(x: cx, y: cy), radius: radius,
                           startAngle: start, endAngle: end, clockwise: true)
                ctx.strokePath()
            }

            // Big centered "NN%".
            let pct = Int((usedFrac * 100).rounded())
            drawText("\(pct)%", W*0.24, .bold, .white,
                     CGRect(x: 0, y: cy - W*0.135, width: W, height: W*0.26), align: .center)

            // Bottom line: "XXX GB free of YYY GB".
            let line = "\(fmt(cap.free)) free of \(fmt(cap.total))"
            drawText(line, W*0.062, .regular, NSColor.white.withAlphaComponent(0.72),
                     CGRect(x: W*0.07, y: H*0.075, width: W*0.86, height: H*0.08), align: .center)
        } else {
            drawText("Disk unavailable", W*0.10, .medium, NSColor.white.withAlphaComponent(0.8),
                     CGRect(x: 0, y: H*0.45, width: W, height: W*0.14), align: .center)
        }

        NSGraphicsContext.restoreGraphicsState()
        guard let data = ctx.data else { return nil }
        let count = size*size*4
        return Array(UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: count), count: count))
    }

    // MARK: - Capacity

    private struct Capacity { let free: Int64; let total: Int64; var used: Int64 { max(0, total - free) } }

    /// Reads the startup volume ("/") capacity. Returns nil if unavailable.
    private static func capacity() -> Capacity? {
        let url = URL(fileURLWithPath: "/")
        guard let vals = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                           .volumeTotalCapacityKey]),
              let free = vals.volumeAvailableCapacityForImportantUsage,
              let total = vals.volumeTotalCapacity, total > 0 else { return nil }
        return Capacity(free: Int64(free), total: Int64(total))
    }

    /// Bytes → "XXX GB", or "X.X TB" with one decimal once ≥ 1000 GB.
    private static func fmt(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1000 {
            return String(format: "%.1f TB", gb / 1000)
        }
        return "\(Int(gb.rounded())) GB"
    }

    // MARK: - Primitives (mirrors StatCard)

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
