import Foundation
import AppKit
import CoreGraphics

/// Renders a Calendar / next-event card into row-major RGBA8888 for the 240×240
/// square AMOLED display, in the same visual language as `StatCard` (dark
/// vertical-gradient background, title top-left, SF Symbol top-right).
///
/// The returned bytes follow the `CardKit` contract (`premultipliedLast |
/// byteOrder32Big`, size×size, bottom-left origin, NOT flipped).
@MainActor
enum CalendarCard {

    static func render(_ events: [CalEvent], auth: CalAuth, size: Int, clock24h: Bool) -> [UInt8]? {
        // Deep blue/teal gradient background.
        CardKit.draw(size: size, accent: (CardKit.c(0.10, 0.22, 0.42), CardKit.c(0.04, 0.08, 0.16)),
                     title: "Calendar", icon: "calendar") { g, W, H in

            if auth != .authorized {
                center(g, "Grant Calendar access", size: W*0.088, weight: .semibold,
                       color: .white, W: W, y: H*0.50)
                center(g, "in System Settings → Privacy", size: W*0.058, weight: .regular,
                       color: NSColor.white.withAlphaComponent(0.65), W: W, y: H*0.40)
                return
            }

            if events.isEmpty {
                CardKit.symbol("checkmark.circle", color: .systemTeal,
                           rect: CGRect(x: W*0.5 - W*0.13, y: H*0.52, width: W*0.26, height: W*0.26))
                center(g, "No events", size: W*0.13, weight: .bold, color: .white, W: W, y: H*0.34)
                center(g, "You're all clear", size: W*0.06, weight: .regular,
                       color: NSColor.white.withAlphaComponent(0.65), W: W, y: H*0.26)
                return
            }

            // Featured first event.
            let first = events[0]
            let dot = W*0.045
            let dotX = W*0.09
            // Colored dot aligned with the featured title row.
            fillDot(g, color: first.calendarColorRGBA, rect: CGRect(x: dotX, y: H*0.62, width: dot, height: dot))
            CardKit.text(timeString(first, clock24h: clock24h), W*0.11, .bold, .white,
                     CGRect(x: dotX + dot + W*0.03, y: H*0.595, width: W*0.5, height: W*0.14))
            CardKit.text(relativeHint(first), W*0.06, .semibold, NSColor.systemTeal,
                     CGRect(x: W*0.60, y: H*0.615, width: W*0.33, height: W*0.10), align: .right)
            CardKit.text(first.title, W*0.088, .semibold, NSColor.white.withAlphaComponent(0.95),
                     CGRect(x: W*0.09, y: H*0.48, width: W*0.84, height: W*0.12))

            // Divider.
            g.ctx.setFillColor(CGColor(gray: 1, alpha: 0.14))
            g.ctx.fill(CGRect(x: W*0.09, y: H*0.44, width: W*0.82, height: 1))

            // Up to two more compact rows.
            let rows = Array(events.dropFirst().prefix(2))
            var y = H*0.30
            for ev in rows {
                let rdot = W*0.035
                fillDot(g, color: ev.calendarColorRGBA, rect: CGRect(x: dotX, y: y + W*0.02, width: rdot, height: rdot))
                CardKit.text(timeString(ev, clock24h: clock24h), W*0.062, .semibold,
                         NSColor.white.withAlphaComponent(0.85),
                         CGRect(x: dotX + rdot + W*0.025, y: y, width: W*0.22, height: W*0.09))
                CardKit.text(ev.title, W*0.062, .regular, NSColor.white.withAlphaComponent(0.80),
                         CGRect(x: W*0.40, y: y, width: W*0.53, height: W*0.09))
                y -= H*0.11
            }
        }
    }

    // MARK: formatting

    private static func timeString(_ ev: CalEvent, clock24h: Bool) -> String {
        if ev.isAllDay { return "All day" }
        let df = DateFormatter()
        df.dateFormat = clock24h ? "HH:mm" : "h:mm a"
        return df.string(from: ev.start)
    }

    /// A short relative hint: "now", "in 25 min", "in 3 hr".
    private static func relativeHint(_ ev: CalEvent) -> String {
        if ev.isAllDay { return "today" }
        let delta = ev.start.timeIntervalSinceNow
        if delta <= 0 {
            // Started; still "now" while ongoing, else empty.
            return ev.end.timeIntervalSinceNow > 0 ? "now" : ""
        }
        let mins = Int((delta / 60).rounded())
        if mins < 60 { return "in \(max(1, mins)) min" }
        let hrs = Int((delta / 3600).rounded())
        return "in \(hrs) hr"
    }

    // MARK: card-specific drawing (scaffold + primitives come from CardKit)

    private typealias GC = CardKit.GC

    private static func center(_ g: GC, _ text: String, size: CGFloat, weight: NSFont.Weight,
                               color: NSColor, W: CGFloat, y: CGFloat) {
        CardKit.text(text, size, weight, color, CGRect(x: W*0.06, y: y, width: W*0.88, height: size*1.5), align: .center)
    }

    private static func fillDot(_ g: GC, color: (Double, Double, Double), rect: CGRect) {
        let cg = CGColor(red: CGFloat(color.0), green: CGFloat(color.1), blue: CGFloat(color.2), alpha: 1)
        g.ctx.setFillColor(cg)
        g.ctx.fillEllipse(in: rect)
    }
}
