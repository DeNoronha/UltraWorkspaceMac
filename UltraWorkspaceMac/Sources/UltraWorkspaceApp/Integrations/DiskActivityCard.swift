import Foundation
import AppKit
import CoreGraphics

/// Renders a compact "Disk I/O" metric card (read/write per second) into
/// RGBA8888, in the same style as StatCard. Square-first (VivoCube 240).
@MainActor
enum DiskActivityCard {
    static func render(_ s: DiskActivityStats.Sample, size: Int) -> [UInt8]? {
        draw(size: size, accent: (c(0.18, 0.26, 0.44), c(0.07, 0.09, 0.16)),
             title: "Disk I/O", icon: "internaldrive.fill") { g, W, H in
            row(g, icon: "arrow.down", color: .systemTeal, value: byteRate(s.readBytesPerSec), W: W, y: H*0.52)
            row(g, icon: "arrow.up", color: .systemOrange, value: byteRate(s.writeBytesPerSec), W: W, y: H*0.24)
        }
    }

    /// Human disk throughput, e.g. "12.4 MB/s", "840 KB/s", "2.1 GB/s".
    private static func byteRate(_ bytes: Double) -> String {
        let b = max(0, bytes)
        if b >= 1_073_741_824 { return String(format: "%.1f GB/s", b / 1_073_741_824) }
        if b >= 1_048_576 { return String(format: "%.1f MB/s", b / 1_048_576) }
        if b >= 1_024 { return String(format: "%.0f KB/s", b / 1_024) }
        return String(format: "%.0f B/s", b)
    }

    // MARK: shared drawing (mirrors StatCard's scaffold)

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

    private static func row(_ g: GC, icon: String, color: NSColor, value: String, W: CGFloat, y: CGFloat) {
        drawSymbol(icon, color: color, rect: CGRect(x: W*0.10, y: y, width: W*0.16, height: W*0.16))
        drawText(value, W*0.15, .bold, .white, CGRect(x: W*0.28, y: y - W*0.01, width: W*0.64, height: W*0.18))
    }

    // primitives
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
