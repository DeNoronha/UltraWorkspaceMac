import Foundation
import AppKit
import CoreGraphics

/// Renders a crypto ticker card into RGBA8888, matching StatCard's style
/// (dark vertical-gradient card, title top-left, SF Symbol top-right, rows).
/// Square-first for the 240x240 round AMOLED.
@MainActor
enum CryptoCard {
    static func render(_ coins: [CryptoStats.Coin], size: Int, currencySymbol: String = "€") -> [UInt8]? {
        draw(size: size,
             accent: (c(0.18, 0.15, 0.05), c(0.05, 0.05, 0.06)),
             title: "Crypto", icon: "bitcoinsign.circle") { g, W, H in
            if coins.isEmpty {
                center(g, "No data", size: W*0.11, color: NSColor.white.withAlphaComponent(0.8), W: W, y: H*0.44)
                return
            }
            // Up to 3 rows laid out top→bottom in the body area below the title.
            let rows = Array(coins.prefix(3))
            let top: CGFloat = H*0.66        // y of the first (top) row baseline area
            let step: CGFloat = H*0.20       // vertical spacing between rows
            for (i, coin) in rows.enumerated() {
                let y = top - step * CGFloat(i)
                row(g, coin, currencySymbol: currencySymbol, W: W, H: H, y: y)
            }
        }
    }

    // MARK: row

    private static func row(_ g: GC, _ coin: CryptoStats.Coin, currencySymbol: String,
                            W: CGFloat, H: CGFloat, y: CGFloat) {
        let rh = H*0.14
        // left: symbol (bold)
        drawText(coin.symbol, W*0.09, .bold, .white,
                 CGRect(x: W*0.08, y: y, width: W*0.22, height: rh))
        // middle: price (thousands separators, currency, sensible decimals)
        drawText(formatPrice(coin.price, currencySymbol: currencySymbol), W*0.078, .semibold, .white,
                 CGRect(x: W*0.30, y: y, width: W*0.40, height: rh), align: .right)
        // right: colored 24h-change pill with arrow
        changePill(g, coin.change24h, W: W, y: y, rowHeight: rh)
    }

    private static func changePill(_ g: GC, _ change: Double, W: CGFloat, y: CGFloat, rowHeight: CGFloat) {
        let up = change >= 0
        let color: NSColor = up ? .systemGreen : .systemRed
        let arrow = up ? "\u{25B2}" : "\u{25BC}"   // ▲ / ▼
        let text = String(format: "%@%+.1f%%", arrow, change)
        let pw = W*0.24, ph = rowHeight*0.84
        let px = W*0.92 - pw
        let py = y + (rowHeight - ph) / 2
        let pill = CGPath(roundedRect: CGRect(x: px, y: py, width: pw, height: ph),
                          cornerWidth: ph/2, cornerHeight: ph/2, transform: nil)
        g.ctx.addPath(pill)
        g.ctx.setFillColor(color.withAlphaComponent(0.22).cgColor)
        g.ctx.fillPath()
        drawText(text, W*0.055, .bold, color,
                 CGRect(x: px, y: py + ph*0.16, width: pw, height: ph*0.72), align: .center)
    }

    private static func formatPrice(_ price: Double, currencySymbol: String) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.usesGroupingSeparator = true
        let decimals = price >= 100 ? 0 : 2
        fmt.minimumFractionDigits = decimals
        fmt.maximumFractionDigits = decimals
        let num = fmt.string(from: NSNumber(value: price)) ?? String(format: "%.\(decimals)f", price)
        return currencySymbol + num
    }

    // MARK: shared drawing (mirrors StatCard's CGContext scaffold exactly)

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
        drawSymbol(icon, color: .systemOrange, rect: CGRect(x: W*0.78, y: H*0.84, width: W*0.14, height: W*0.14))
        body((ctx, cs), W, H)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = ctx.data else { return nil }
        let count = size*size*4
        return Array(UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: count), count: count))
    }

    private static func center(_ g: GC, _ text: String, size: CGFloat, color: NSColor, W: CGFloat, y: CGFloat) {
        drawText(text, size, .medium, color, CGRect(x: 0, y: y, width: W, height: size*1.4), align: .center)
    }

    // primitives (identical to StatCard)
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
