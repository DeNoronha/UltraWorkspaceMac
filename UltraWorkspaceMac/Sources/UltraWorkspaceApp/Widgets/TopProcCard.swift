import Foundation
import AppKit
import CoreGraphics

/// Renders a "Top CPU" card (biggest CPU consumers) into RGBA8888,
/// in the same style as StatCard. Square-first (VivoCube 240).
@MainActor
enum TopProcCard {
    static func render(_ procs: [TopProcStats.Proc], size: Int) -> [UInt8]? {
        let W = CGFloat(size), H = CGFloat(size)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size*4, space: cs, bitmapInfo: info) else { return nil }
        // Purple/graphite gradient.
        let top = c(0.40, 0.24, 0.56), bottom = c(0.10, 0.09, 0.15)
        if let g = CGGradient(colorsSpace: cs, colors: [top, bottom] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])
        }
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns

        drawText("Top CPU", W*0.085, .semibold, NSColor.white.withAlphaComponent(0.9),
                 CGRect(x: W*0.07, y: H*0.86, width: W*0.7, height: H*0.12))
        drawSymbol(symbolName("gauge.with.dots.needle.67percent", fallback: "speedometer"),
                   color: .white, rect: CGRect(x: W*0.78, y: H*0.84, width: W*0.14, height: W*0.14))

        if procs.isEmpty {
            drawText("No data", W*0.10, .medium, NSColor.white.withAlphaComponent(0.8),
                     CGRect(x: 0, y: H*0.45, width: W, height: W*0.14), align: .center)
        } else {
            let shown = Array(procs.prefix(3))
            let maxCpu = max(1.0, shown.map(\.cpu).max() ?? 1.0)
            // Up to 3 rows stacked from top to bottom.
            let rowTops: [CGFloat] = [H*0.62, H*0.42, H*0.22]
            for (i, p) in shown.enumerated() {
                row(ctx, name: p.name, cpu: p.cpu, maxCpu: maxCpu, W: W, y: rowTops[i])
            }
        }

        NSGraphicsContext.restoreGraphicsState()
        guard let data = ctx.data else { return nil }
        let count = size*size*4
        return Array(UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: count), count: count))
    }

    // MARK: rows

    private static func row(_ ctx: CGContext, name: String, cpu: Double, maxCpu: Double, W: CGFloat, y: CGFloat) {
        // Name (left, truncating) and %CPU (right, bold) on the top line of the row.
        drawText(name, W*0.075, .medium, .white,
                 CGRect(x: W*0.07, y: y, width: W*0.62, height: W*0.09))
        drawText(String(format: "%.0f%%", cpu), W*0.085, .bold, .white,
                 CGRect(x: W*0.55, y: y, width: W*0.38, height: W*0.10), align: .right)
        // Thin horizontal bar below; fill relative to the busiest process.
        bar(ctx, frac: cpu / maxCpu, W: W, y: y - W*0.03)
    }

    private static func bar(_ ctx: CGContext, frac: Double, W: CGFloat, y: CGFloat) {
        let f = max(0, min(1, frac))
        let x = W*0.07, w = W*0.86, h = W*0.035
        let track = CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: h/2, cornerHeight: h/2, transform: nil)
        ctx.addPath(track); ctx.setFillColor(CGColor(gray: 1, alpha: 0.18)); ctx.fillPath()
        if f > 0.01 {
            let fill = CGPath(roundedRect: CGRect(x: x, y: y, width: w*f, height: h), cornerWidth: h/2, cornerHeight: h/2, transform: nil)
            ctx.addPath(fill); ctx.setFillColor(NSColor.systemPurple.cgColor); ctx.fillPath()
        }
    }

    // MARK: primitives

    private static func symbolName(_ preferred: String, fallback: String) -> String {
        if NSImage(systemSymbolName: preferred, accessibilityDescription: nil) != nil { return preferred }
        return fallback
    }

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
