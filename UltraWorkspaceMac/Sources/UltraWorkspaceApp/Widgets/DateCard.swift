import Foundation
import AppKit
import CoreGraphics

/// "Date" card: weekday, day, month, year in Deckhand's own language with this Mac's region (date order); long / short /
/// numeric. It followed the Mac's language before 2026-11-15, so an English Deckhand drew a Dutch card (review S8).
@MainActor
enum DateCard {
    /// The app's language (the first of its localizations, English today) with the Mac's region, e.g. en_NL.
    static var locale: Locale {
        let lang = Bundle.main.preferredLocalizations.first ?? "en"
        guard let region = Locale.current.region?.identifier else { return Locale(identifier: lang) }
        return Locale(identifier: "\(lang)_\(region)")
    }

    static func render(size: Int, style: AppSettings.DateStyle, showWeekday: Bool, showYear: Bool, now: Date = Date()) -> [UInt8]? {
        CardKit.draw(size: size, accent: (CardKit.c(0.30, 0.12, 0.16), CardKit.c(0.10, 0.04, 0.06)), title: nil, icon: nil) { g, W, H in
            let loc = Self.locale
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
