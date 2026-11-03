import Foundation
import AppKit
import CoreGraphics

/// The one bitmap contract for every card Deckhand draws: RGBA8888,
/// premultipliedLast | byteOrder32Big, bottom-left origin (NOT flipped), row 0 = top
/// of the buffer as `DeviceImage.encode` / `AppModel.pngData` expect it.
/// `draw` adds the shared look (vertical gradient, title top-left, SF Symbol top-right);
/// `context` / `withAppKit` / `rgba` are the pieces for cards that paint their own background.
@MainActor
enum CardKit {
    typealias GC = (ctx: CGContext, cs: CGColorSpace)

    /// A bitmap context in the card contract. `nil` only when CoreGraphics refuses the size.
    static func context(width: Int, height: Int) -> GC? {
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: cs, bitmapInfo: info) else { return nil }
        return (ctx, cs)
    }

    /// The context's pixels, `width × height × 4` bytes.
    static func rgba(_ g: GC, width: Int, height: Int) -> [UInt8]? {
        guard let data = g.ctx.data else { return nil }
        let count = width * height * 4
        return Array(UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: count), count: count))
    }

    /// Runs `body` with AppKit string/image drawing routed into `g` (not flipped).
    static func withAppKit(_ g: GC, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: g.ctx, flipped: false)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Square card (VivoCube 240×240).
    static func draw(size: Int, accent: (CGColor, CGColor), title: String?, icon: String?,
                     body: (GC, CGFloat, CGFloat) -> Void) -> [UInt8]? {
        draw(width: size, height: size, accent: accent, title: title, icon: icon, body: body)
    }

    /// Any size (the weather card also renders the 1424×280 CoreBar strip). The gradient runs
    /// top (`accent.0`) to bottom (`accent.1`); title/icon are placed relative to W and H.
    static func draw(width: Int, height: Int, accent: (CGColor, CGColor), title: String?, icon: String?,
                     body: (GC, CGFloat, CGFloat) -> Void) -> [UInt8]? {
        let W = CGFloat(width), H = CGFloat(height)
        guard let g = context(width: width, height: height) else { return nil }
        if let grad = CGGradient(colorsSpace: g.cs, colors: [accent.0, accent.1] as CFArray, locations: [0, 1]) {
            g.ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])
        }
        withAppKit(g) {
            if let title {
                text(title, W * 0.085, .semibold, NSColor.white.withAlphaComponent(0.9),
                     CGRect(x: W * 0.07, y: H * 0.86, width: W * 0.7, height: H * 0.12))
            }
            if let icon {
                symbol(icon, color: .white, rect: CGRect(x: W * 0.78, y: H * 0.84, width: W * 0.14, height: W * 0.14))
            }
            body(g, W, H)
        }
        return rgba(g, width: width, height: height)
    }

    static func text(_ s: String, _ size: CGFloat, _ w: NSFont.Weight, _ color: NSColor, _ rect: CGRect,
                     align: NSTextAlignment = .left, monospacedDigits: Bool = false) {
        let para = NSMutableParagraphStyle(); para.alignment = align; para.lineBreakMode = .byTruncatingTail
        let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.4); sh.shadowBlurRadius = 2; sh.shadowOffset = .init(width: 0, height: -1)
        let font = monospacedDigits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: w) : NSFont.systemFont(ofSize: size, weight: w)
        (s as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: para, .shadow: sh])
    }

    /// Centred text whose rect is sized from the font so glyphs never spill into the neighbour row.
    static func centered(_ s: String, _ size: CGFloat, _ w: NSFont.Weight, _ color: NSColor, W: CGFloat, centerY: CGFloat, monospacedDigits: Bool = false) {
        let h = size * 1.3
        text(s, size, w, color, CGRect(x: 0, y: centerY - h / 2, width: W, height: h), align: .center, monospacedDigits: monospacedDigits)
    }

    static func symbol(_ name: String, color: NSColor, rect: CGRect) {
        let cfg = NSImage.SymbolConfiguration(pointSize: rect.height, weight: .semibold)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
        let tinted = NSImage(size: rect.size); tinted.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: rect.size)); color.set()
        NSRect(origin: .zero, size: rect.size).fill(using: .sourceAtop); tinted.unlockFocus()
        tinted.draw(in: rect)
    }

    static func pill(_ g: GC, _ label: String, color: NSColor, rect: CGRect, fontSize: CGFloat) {
        let path = CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)
        g.ctx.addPath(path); g.ctx.setFillColor(color.withAlphaComponent(0.22).cgColor); g.ctx.fillPath()
        text(label, fontSize, .bold, color, CGRect(x: rect.minX, y: rect.minY + rect.height * 0.16, width: rect.width, height: rect.height * 0.72), align: .center)
    }

    static func c(_ r: Double, _ g: Double, _ b: Double) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: 1) }
}
