import Foundation
import AppKit
import CoreGraphics

/// "Clock" card: an analog face or a large digital time. 12/24-hour and optional seconds.
/// Note for the UI: the cube's picture only changes when Deckhand re-sends the package
/// (every few minutes), so a seconds display is a snapshot, not a running clock.
@MainActor
enum ClockCard {
    static func render(size: Int, style: AppSettings.ClockStyle, clock24h: Bool, seconds: Bool, now: Date = Date()) -> [UInt8]? {
        CardKit.draw(size: size, accent: (CardKit.c(0.12, 0.14, 0.30), CardKit.c(0.03, 0.04, 0.10)), title: nil, icon: nil) { g, W, H in
            switch style {
            case .analog: analog(g, W: W, H: H, now: now, seconds: seconds)
            case .digital: digital(W: W, H: H, now: now, clock24h: clock24h, seconds: seconds)
            }
        }
    }

    private static func analog(_ g: CardKit.GC, W: CGFloat, H: CGFloat, now: Date, seconds: Bool) {
        let ctx = g.ctx
        let cx = W / 2, cy = H / 2, r = W * 0.44
        // Face
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.06))
        ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.25)); ctx.setLineWidth(max(1, W * 0.008))
        ctx.strokeEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
        // Ticks: 12 major, 60 minor
        for i in 0..<60 {
            let a = CGFloat(i) / 60 * 2 * .pi
            let major = i % 5 == 0
            let len = major ? r * 0.12 : r * 0.05
            let p1 = CGPoint(x: cx + sin(a) * (r - len), y: cy + cos(a) * (r - len))
            let p2 = CGPoint(x: cx + sin(a) * r * 0.97, y: cy + cos(a) * r * 0.97)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: major ? 0.9 : 0.35))
            ctx.setLineWidth(major ? max(2, W * 0.014) : max(1, W * 0.006))
            ctx.setLineCap(.round)
            ctx.move(to: p1); ctx.addLine(to: p2); ctx.strokePath()
        }
        // Numerals 12 / 3 / 6 / 9
        let numSize = W * 0.085
        for (n, a) in [(12, 0.0), (3, 0.5), (6, 1.0), (9, 1.5)] {
            let ang = CGFloat(a) * .pi
            let p = CGPoint(x: cx + sin(ang) * r * 0.74, y: cy + cos(ang) * r * 0.74)
            CardKit.text("\(n)", numSize, .semibold, NSColor.white.withAlphaComponent(0.9),
                         CGRect(x: p.x - numSize, y: p.y - numSize * 0.65, width: numSize * 2, height: numSize * 1.3), align: .center)
        }
        // Hands
        var cal = Calendar.current; cal.timeZone = .current
        let c = cal.dateComponents([.hour, .minute, .second], from: now)
        let h = Double(c.hour ?? 0), m = Double(c.minute ?? 0), s = Double(c.second ?? 0)
        func hand(angle: Double, length: CGFloat, width: CGFloat, color: CGColor, tail: CGFloat = 0) {
            let a = CGFloat(angle)
            let tip = CGPoint(x: cx + sin(a) * length, y: cy + cos(a) * length)
            let back = CGPoint(x: cx - sin(a) * tail, y: cy - cos(a) * tail)
            ctx.setStrokeColor(color); ctx.setLineWidth(width); ctx.setLineCap(.round)
            ctx.move(to: back); ctx.addLine(to: tip); ctx.strokePath()
        }
        hand(angle: (h.truncatingRemainder(dividingBy: 12) + m / 60) / 12 * 2 * .pi, length: r * 0.52, width: max(3, W * 0.03), color: CGColor(gray: 1, alpha: 0.95))
        hand(angle: (m + s / 60) / 60 * 2 * .pi, length: r * 0.80, width: max(2, W * 0.02), color: CGColor(gray: 1, alpha: 0.95))
        if seconds {
            hand(angle: s / 60 * 2 * .pi, length: r * 0.86, width: max(1, W * 0.008), color: NSColor.systemOrange.cgColor, tail: r * 0.15)
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        let dot = W * 0.03
        ctx.fillEllipse(in: CGRect(x: cx - dot / 2, y: cy - dot / 2, width: dot, height: dot))
    }

    private static func digital(W: CGFloat, H: CGFloat, now: Date, clock24h: Bool, seconds: Bool) {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = (clock24h ? "HH:mm" : "h:mm") + (seconds ? ":ss" : "")
        let timeStr = f.string(from: now)
        let size = seconds ? W * 0.21 : W * 0.30
        CardKit.centered(timeStr, size, .bold, .white, W: W, centerY: H * 0.55, monospacedDigits: true)
        if !clock24h {
            let ap = DateFormatter(); ap.locale = Locale(identifier: "en_US_POSIX"); ap.dateFormat = "a"
            CardKit.centered(ap.string(from: now), W * 0.09, .semibold, NSColor.white.withAlphaComponent(0.75), W: W, centerY: H * 0.34)
        }
        let tz = TimeZone.current.abbreviation() ?? TimeZone.current.identifier
        CardKit.centered(tz, W * 0.06, .regular, NSColor.white.withAlphaComponent(0.5), W: W, centerY: H * 0.12)
    }
}
