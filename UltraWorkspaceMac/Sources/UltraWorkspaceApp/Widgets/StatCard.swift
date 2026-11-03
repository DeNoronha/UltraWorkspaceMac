import Foundation
import AppKit
import CoreGraphics
import UltraBarKit

/// Renders the Claude Code metric card into RGBA8888, in a consistent style
/// with the weather card. Square-first (VivoCube 240).
@MainActor
enum StatCard {
    static func claude(_ s: ClaudeUsage.Snapshot, plan: String, dailyBudget: Int, size: Int) -> [UInt8]? {
        CardKit.draw(size: size, accent: (CardKit.c(0.42, 0.26, 0.60), CardKit.c(0.14, 0.09, 0.22)),
                     title: "Claude Code", icon: "sparkles") { g, W, H in
            guard s.hasData else {
                center(g, "No Claude data", size: W*0.10, color: NSColor.white.withAlphaComponent(0.8), W: W, y: H*0.45); return
            }
            // Big number sized so "16.1M" never touches its caption (rect height = font × 1.2).
            let big = W*0.20
            CardKit.text(ClaudeUsage.shortTokens(s.todayTokens), big, .bold, .white,
                     CGRect(x: 0, y: H*0.595, width: W, height: big*1.25), align: .center)
            CardKit.text("tokens today · \(plan)", W*0.065, .regular, NSColor.white.withAlphaComponent(0.75),
                     CGRect(x: 0, y: H*0.51, width: W, height: W*0.085), align: .center)
            if dailyBudget > 0 {
                let frac = Double(s.todayTokens) / Double(dailyBudget)
                let pct = Int((frac * 100).rounded())
                bar(g, label: "\(min(pct, 999))%", frac: frac, color: frac < 0.8 ? .systemGreen : (frac < 1 ? .systemOrange : .systemRed), W: W, y: H*0.42)
            }
            center(g, "\(s.activeSessions) active session\(s.activeSessions == 1 ? "" : "s")",
                   size: W*0.075, color: s.activeSessions > 0 ? .systemGreen : NSColor.white.withAlphaComponent(0.7),
                   W: W, y: H*0.25)
            if s.waitingForInput > 0 {
                center(g, "\(s.waitingForInput) waiting for you", size: W*0.075, color: .systemOrange, W: W, y: H*0.13)
            }
        }
    }

    // MARK: card-specific drawing (scaffold + primitives come from CardKit)

    private typealias GC = CardKit.GC

    private static func center(_ g: GC, _ text: String, size: CGFloat, color: NSColor, W: CGFloat, y: CGFloat) {
        CardKit.text(text, size, .medium, color, CGRect(x: 0, y: y, width: W, height: size*1.4), align: .center)
    }

    private static func bar(_ g: GC, label: String, frac: Double, color: NSColor, W: CGFloat, y: CGFloat) {
        let f = max(0, min(1, frac))
        let x = W*0.24, w = W*0.62, h = W*0.055
        CardKit.text(label, W*0.06, .semibold, NSColor.white.withAlphaComponent(0.85),
                 CGRect(x: W*0.07, y: y - h*0.15, width: W*0.16, height: h*1.3))
        let track = CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: h/2, cornerHeight: h/2, transform: nil)
        g.ctx.addPath(track); g.ctx.setFillColor(CGColor(gray: 1, alpha: 0.18)); g.ctx.fillPath()
        if f > 0.01 {
            let fill = CGPath(roundedRect: CGRect(x: x, y: y, width: w*f, height: h), cornerWidth: h/2, cornerHeight: h/2, transform: nil)
            g.ctx.addPath(fill); g.ctx.setFillColor(color.cgColor); g.ctx.fillPath()
        }
    }
}
