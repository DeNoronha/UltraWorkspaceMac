import Foundation
import AppKit
import CoreGraphics

/// "Date" card: weekday, day, month, year in the Mac's language; long / short / numeric.
@MainActor
enum DateCard {
    static func render(size: Int, style: AppSettings.DateStyle, showWeekday: Bool, showYear: Bool, now: Date = Date()) -> [UInt8]? {
        CardKit.draw(size: size, accent: (CardKit.c(0.30, 0.12, 0.16), CardKit.c(0.10, 0.04, 0.06)), title: nil, icon: nil) { g, W, H in
            let loc = Locale.current
            func fmt(_ pattern: String) -> String {
                let f = DateFormatter(); f.locale = loc
                f.setLocalizedDateFormatFromTemplate(pattern)
                return f.string(from: now)
            }
            switch style {
            case .numeric:
                let f = DateFormatter(); f.locale = loc; f.dateStyle = .short; f.timeStyle = .none
                var s = f.string(from: now)
                if !showYear { s = fmt("ddMM") }
                if showWeekday { CardKit.centered(fmt("EEEE").capitalized, W * 0.10, .medium, NSColor.white.withAlphaComponent(0.8), W: W, centerY: H * 0.72) }
                CardKit.centered(s, W * 0.135, .bold, .white, W: W, centerY: H * 0.48, monospacedDigits: true)
            case .long, .short:
                let short = style == .short
                let weekday = fmt(short ? "EEE" : "EEEE").capitalized
                let month = fmt(short ? "MMM" : "MMMM").capitalized
                let day = fmt("d")
                let year = fmt("y")
                var y = H * 0.80
                if showWeekday { CardKit.centered(weekday, W * 0.10, .medium, NSColor.white.withAlphaComponent(0.8), W: W, centerY: y); y -= H * 0.08 }
                CardKit.centered(day, W * 0.36, .bold, .white, W: W, centerY: y - H * 0.18, monospacedDigits: true)
                CardKit.centered(month, W * 0.11, .semibold, .white, W: W, centerY: y - H * 0.42)
                if showYear { CardKit.centered(year, W * 0.08, .regular, NSColor.white.withAlphaComponent(0.6), W: W, centerY: y - H * 0.54) }
            }
        }
    }
}
