import Foundation
import AppKit
import CoreGraphics
import UltraBarKit

/// Renders a clock + date + weather card into row-major RGBA8888.
/// Adapts layout to square (VivoCube 240×240) or wide (CoreBar 1424×280).
@MainActor
enum WeatherCard {
    static func render(width: Int, height: Int, now: OpenMeteo.Now?, clock24h: Bool, date: Date = Date()) -> [UInt8]? {
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: cs, bitmapInfo: info) else { return nil }
        let W = CGFloat(width), H = CGFloat(height)
        let wide = W / H > 2.2

        // Background gradient from the sky/day.
        let (top, bottom) = backgroundColors(for: now)
        if let g = CGGradient(colorsSpace: cs, colors: [top, bottom] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])
        }

        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns

        let df = DateFormatter()
        df.dateFormat = clock24h ? "HH:mm" : "h:mm"
        let timeStr = df.string(from: date)
        let dd = DateFormatter(); dd.dateFormat = "EEE d MMM"
        let dateStr = dd.string(from: date)
        let tempStr = now.map { "\(Int($0.temperature.rounded()))\($0.unitSuffix)" } ?? "—"
        let condStr = now?.sky.label ?? "No data"
        let place = now?.place ?? ""

        let white = NSColor.white
        let dim = NSColor.white.withAlphaComponent(0.8)
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = wide ? 6 : 3; shadow.shadowOffset = .init(width: 0, height: -1)

        func draw(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, _ rect: CGRect, align: NSTextAlignment = .left) {
            let para = NSMutableParagraphStyle(); para.alignment = align; para.lineBreakMode = .byTruncatingTail
            let a: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: color, .shadow: shadow, .paragraphStyle: para,
            ]
            (s as NSString).draw(in: rect, withAttributes: a)
        }

        let iconName = symbolName(for: now)
        if wide {
            // CoreBar 1424×280: time/date left, icon center, temp/cond right.
            draw(timeStr, H*0.44, .bold, white, CGRect(x: W*0.04, y: H*0.40, width: W*0.40, height: H*0.5))
            draw(dateStr, H*0.14, .medium, dim, CGRect(x: W*0.045, y: H*0.20, width: W*0.40, height: H*0.2))
            drawIcon(iconName, in: CGRect(x: W*0.46, y: H*0.22, width: H*0.56, height: H*0.56), ctx: ctx)
            draw(tempStr, H*0.34, .bold, white, CGRect(x: W*0.63, y: H*0.38, width: W*0.35, height: H*0.45), align: .right)
            draw(condStr, H*0.13, .medium, dim, CGRect(x: W*0.63, y: H*0.24, width: W*0.35, height: H*0.2), align: .right)
            draw(place, H*0.12, .regular, dim, CGRect(x: W*0.63, y: H*0.08, width: W*0.35, height: H*0.18), align: .right)
        } else {
            // VivoCube 240×240: stacked.
            // Rects are font-height (≈1.25×) so the time's descenders never reach the date line.
            draw(timeStr, W*0.28, .bold, white, CGRect(x: 0, y: H*0.59, width: W, height: W*0.35), align: .center)
            draw(dateStr, W*0.095, .medium, dim, CGRect(x: 0, y: H*0.50, width: W, height: W*0.12), align: .center)
            drawIcon(iconName, in: CGRect(x: W*0.5 - H*0.115, y: H*0.275, width: H*0.23, height: H*0.23), ctx: ctx)
            draw(tempStr, W*0.16, .bold, white, CGRect(x: 0, y: H*0.105, width: W, height: W*0.20), align: .center)
            draw(condStr, W*0.08, .regular, dim, CGRect(x: 0, y: H*0.015, width: W, height: W*0.10), align: .center)
        }

        NSGraphicsContext.restoreGraphicsState()

        guard let data = ctx.data else { return nil }
        let count = width * height * 4
        return Array(UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: count), count: count))
    }

    private static func drawIcon(_ name: String, in rect: CGRect, ctx: CGContext) {
        let cfg = NSImage.SymbolConfiguration(pointSize: rect.height, weight: .regular)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return }
        let tint: NSColor = name.contains("sun") ? NSColor(red: 1, green: 0.85, blue: 0.3, alpha: 1)
            : name.contains("moon") ? NSColor(red: 0.95, green: 0.95, blue: 0.8, alpha: 1)
            : .white
        // Tint the (template) symbol so it is always visible on the gradient.
        let tinted = NSImage(size: rect.size)
        tinted.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: rect.size), from: .zero, operation: .sourceOver, fraction: 1)
        tint.set()
        NSRect(origin: .zero, size: rect.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }

    private static func symbolName(for now: OpenMeteo.Now?) -> String {
        guard let now else { return "cloud.fill" }
        let day = now.isDay
        switch now.sky {
        case .clear: return day ? "sun.max.fill" : "moon.stars.fill"
        case .partlyCloudy: return day ? "cloud.sun.fill" : "cloud.moon.fill"
        case .cloudy: return "cloud.fill"
        case .fog: return "cloud.fog.fill"
        case .drizzle: return "cloud.drizzle.fill"
        case .rain: return "cloud.rain.fill"
        case .showers: return "cloud.heavyrain.fill"
        case .snow: return "cloud.snow.fill"
        case .thunder: return "cloud.bolt.rain.fill"
        case .unknown: return "cloud.fill"
        }
    }

    private static func backgroundColors(for now: OpenMeteo.Now?) -> (CGColor, CGColor) {
        func c(_ r: Double, _ g: Double, _ b: Double) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: 1) }
        guard let now else { return (c(0.18, 0.20, 0.28), c(0.08, 0.09, 0.13)) }
        if !now.isDay { return (c(0.10, 0.12, 0.24), c(0.03, 0.04, 0.10)) }
        switch now.sky {
        case .clear: return (c(0.20, 0.52, 0.90), c(0.42, 0.70, 0.98))
        case .partlyCloudy: return (c(0.30, 0.50, 0.76), c(0.52, 0.68, 0.86))
        case .cloudy, .fog: return (c(0.42, 0.47, 0.55), c(0.28, 0.32, 0.40))
        case .drizzle, .rain, .showers, .thunder: return (c(0.26, 0.32, 0.42), c(0.14, 0.18, 0.26))
        case .snow: return (c(0.55, 0.62, 0.72), c(0.38, 0.45, 0.56))
        case .unknown: return (c(0.20, 0.24, 0.32), c(0.10, 0.12, 0.18))
        }
    }
}
