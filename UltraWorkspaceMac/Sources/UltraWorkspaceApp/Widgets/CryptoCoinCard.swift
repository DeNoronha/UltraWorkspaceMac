import Foundation
import AppKit
import CoreGraphics

/// One coin per card: current price, today's low/high, change since midnight and a sparkline of today.
@MainActor
enum CryptoCoinCard {
    static func render(_ day: CryptoStats.CoinDay?, coinId: String, currency: String, size: Int) -> [UInt8]? {
        let sym = CryptoStats.symbol(for: coinId)
        let cur = currency.uppercased()
        let unit = CryptoStats.suffix(for: currency)
        return CardKit.draw(size: size, accent: (CardKit.c(0.18, 0.15, 0.05), CardKit.c(0.05, 0.05, 0.06)),
                            title: coinId.isEmpty ? "Crypto" : "\(sym) / \(cur)", icon: "bitcoinsign.circle") { g, W, H in
            guard !coinId.isEmpty else {
                CardKit.centered("Choose a coin", W * 0.10, .medium, NSColor.white.withAlphaComponent(0.8), W: W, centerY: H * 0.50)
                CardKit.centered("in Widgets → Crypto", W * 0.06, .regular, NSColor.white.withAlphaComponent(0.6), W: W, centerY: H * 0.40)
                return
            }
            guard let day, !day.points.isEmpty else {
                CardKit.centered("No data", W * 0.11, .medium, NSColor.white.withAlphaComponent(0.8), W: W, centerY: H * 0.48)
                return
            }
            // Current price, big.
            CardKit.centered(format(day.current, unit: unit), W * 0.16, .bold, .white, W: W, centerY: H * 0.66, monospacedDigits: true)
            // Change since midnight (pill) and low/high.
            let change = day.open > 0 ? (day.current - day.open) / day.open * 100 : 0
            let up = change >= 0
            let color: NSColor = up ? .systemGreen : .systemRed
            let label = String(format: "%@%+.1f%% today", up ? "\u{25B2}" : "\u{25BC}", change)
            CardKit.pill(g, label, color: color, rect: CGRect(x: W * 0.25, y: H * 0.50, width: W * 0.50, height: H * 0.085), fontSize: W * 0.05)
            CardKit.text("low " + format(day.low, unit: unit), W * 0.055, .regular, NSColor.white.withAlphaComponent(0.7),
                         CGRect(x: W * 0.07, y: H * 0.405, width: W * 0.45, height: H * 0.07), monospacedDigits: true)
            CardKit.text("high " + format(day.high, unit: unit), W * 0.055, .regular, NSColor.white.withAlphaComponent(0.7),
                         CGRect(x: W * 0.48, y: H * 0.405, width: W * 0.45, height: H * 0.07), align: .right, monospacedDigits: true)
            // Sparkline of today in the bottom band.
            sparkline(g, day.points, rect: CGRect(x: W * 0.08, y: H * 0.08, width: W * 0.84, height: H * 0.28), color: color)
        }
    }

    private static func sparkline(_ g: CardKit.GC, _ pts: [Double], rect: CGRect, color: NSColor) {
        guard pts.count >= 2, let lo = pts.min(), let hi = pts.max() else { return }
        let span = max(hi - lo, max(abs(hi), 1) * 0.0005)   // flat day → thin band, not a div-by-zero
        let ctx = g.ctx
        let path = CGMutablePath()
        for (i, p) in pts.enumerated() {
            let x = rect.minX + rect.width * CGFloat(i) / CGFloat(pts.count - 1)
            let y = rect.minY + rect.height * CGFloat((p - lo) / span)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        // Fill under the line.
        let fill = path.mutableCopy()!
        fill.addLine(to: CGPoint(x: rect.maxX, y: rect.minY)); fill.addLine(to: CGPoint(x: rect.minX, y: rect.minY)); fill.closeSubpath()
        ctx.addPath(fill); ctx.setFillColor(color.withAlphaComponent(0.18).cgColor); ctx.fillPath()
        ctx.addPath(path); ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(max(1.5, rect.width * 0.012)); ctx.setLineJoin(.round); ctx.strokePath()
        // Baseline at the opening price.
        if let first = pts.first {
            let y = rect.minY + rect.height * CGFloat((first - lo) / span)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.25)); ctx.setLineWidth(1); ctx.setLineDash(phase: 0, lengths: [3, 3])
            ctx.move(to: CGPoint(x: rect.minX, y: y)); ctx.addLine(to: CGPoint(x: rect.maxX, y: y)); ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }
    }

    private static func format(_ price: Double, unit: String) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.usesGroupingSeparator = true
        let decimals = price >= 1000 ? 0 : (price >= 10 ? 2 : 4)
        f.minimumFractionDigits = decimals; f.maximumFractionDigits = decimals
        return unit + (f.string(from: NSNumber(value: price)) ?? String(format: "%.\(decimals)f", price))
    }
}
