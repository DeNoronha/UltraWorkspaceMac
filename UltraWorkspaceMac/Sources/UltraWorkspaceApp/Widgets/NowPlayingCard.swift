import Foundation
import AppKit
import CoreGraphics

/// Renders a square "now playing" card (album art + title + artist) into
/// row-major RGBA8888, ready for `DeviceImage.encode`.
@MainActor
enum NowPlayingCard {
    static func render(size: Int, art: NSImage?, title: String, artist: String) -> [UInt8]? {
        guard let g = CardKit.context(width: size, height: size) else { return nil }
        let ctx = g.ctx, cs = g.cs

        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        ctx.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1))
        ctx.fill(rect)

        // Album art, aspect-fill.
        if let art, let cg = art.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
            let scale = max(CGFloat(size) / iw, CGFloat(size) / ih)
            let dw = iw * scale, dh = ih * scale
            let dx = (CGFloat(size) - dw) / 2, dy = (CGFloat(size) - dh) / 2
            ctx.draw(cg, in: CGRect(x: dx, y: dy, width: dw, height: dh))
        }

        // Bottom gradient for legibility (origin is bottom-left).
        if let grad = CGGradient(colorsSpace: cs,
                                 colors: [CGColor(red: 0, green: 0, blue: 0, alpha: 0),
                                          CGColor(red: 0, green: 0, blue: 0, alpha: 0.85)] as CFArray,
                                 locations: [0, 1]) {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size) * 0.5))
            ctx.drawLinearGradient(grad,
                                   start: CGPoint(x: 0, y: CGFloat(size) * 0.5),
                                   end: CGPoint(x: 0, y: 0),
                                   options: [])
            ctx.restoreGState()
        }

        // Text via AppKit (own, heavier shadow over album art — not CardKit.text).
        let margin = CGFloat(size) * 0.06
        let titleFont = NSFont.systemFont(ofSize: CGFloat(size) * 0.085, weight: .bold)
        let artistFont = NSFont.systemFont(ofSize: CGFloat(size) * 0.065, weight: .regular)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)

        func draw(_ s: String, font: NSFont, color: NSColor, y: CGFloat) {
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color, .shadow: shadow, .paragraphStyle: para,
            ]
            let maxW = CGFloat(size) - margin * 2
            (s as NSString).draw(in: CGRect(x: margin, y: y, width: maxW, height: font.pointSize * 1.4),
                                 withAttributes: attrs)
        }
        // y is from bottom; artist below title.
        CardKit.withAppKit(g) {
            draw(artist, font: artistFont, color: NSColor.white.withAlphaComponent(0.85), y: margin)
            draw(title, font: titleFont, color: .white, y: margin + artistFont.pointSize * 1.5)
        }
        return CardKit.rgba(g, width: size, height: size)
    }
}
