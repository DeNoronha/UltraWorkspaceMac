import Foundation
import AppKit
import UltraBarKit

/// Offline render check for the weather card. Invoked with
/// `UltraWorkspaceApp --render-weather <dir>` from the build; writes sample PNGs.
@MainActor
enum WeatherPreview {
    static func run(dir: String) {
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let samples: [(String, OpenMeteo.Now)] = [
            ("clear-day", .init(temperature: 21, unitSuffix: "°C", code: 0, sky: .clear, isDay: true, humidity: 40, windSpeed: 8, windSuffix: "km/h", place: "Amsterdam")),
            ("rain", .init(temperature: 9, unitSuffix: "°C", code: 63, sky: .rain, isDay: true, humidity: 92, windSpeed: 24, windSuffix: "km/h", place: "Rotterdam")),
            ("cloudy-night", .init(temperature: 4, unitSuffix: "°C", code: 3, sky: .cloudy, isDay: false, humidity: 80, windSpeed: 12, windSuffix: "km/h", place: "Utrecht")),
            ("snow", .init(temperature: -2, unitSuffix: "°C", code: 73, sky: .snow, isDay: true, humidity: 88, windSpeed: 10, windSuffix: "km/h", place: "Groningen")),
        ]
        for (name, now) in samples {
            if let rgba = WeatherCard.render(width: 240, height: 240, now: now, clock24h: true) {
                save(rgba, 240, 240, out.appendingPathComponent("cube-\(name).png"))
            }
            if let rgba = WeatherCard.render(width: 1424, height: 280, now: now, clock24h: true) {
                save(rgba, 1424, 280, out.appendingPathComponent("bar-\(name).png"))
            }
        }
        // Stat cards with real live data.
        let sys = SystemStats(); _ = sys.sample(); usleep(900_000)
        if let rgba = StatCard.system(sys.sample(), size: 240) { save(rgba, 240, 240, out.appendingPathComponent("cube-cpu.png")) }
        let net = NetworkStats(); _ = net.sample(); usleep(900_000)
        if let rgba = StatCard.network(net.sample(), size: 240) { save(rgba, 240, 240, out.appendingPathComponent("cube-network.png")) }
        if let rgba = StatCard.claude(ClaudeUsage.snapshot(), plan: "Max 5×", dailyBudget: 20_000_000, size: 240) { save(rgba, 240, 240, out.appendingPathComponent("cube-claude.png")) }
        // New cards (2026-11-03).
        if let rgba = ClockCard.render(size: 240, style: .analog, clock24h: true, seconds: true) { save(rgba, 240, 240, out.appendingPathComponent("cube-clock-analog.png")) }
        if let rgba = ClockCard.render(size: 240, style: .digital, clock24h: false, seconds: true) { save(rgba, 240, 240, out.appendingPathComponent("cube-clock-digital.png")) }
        if let rgba = DateCard.render(size: 240, style: .long, showWeekday: true, showYear: true) { save(rgba, 240, 240, out.appendingPathComponent("cube-date-long.png")) }
        if let rgba = DateCard.render(size: 240, style: .numeric, showWeekday: true, showYear: true) { save(rgba, 240, 240, out.appendingPathComponent("cube-date-numeric.png")) }
        if let rgba = WorldClockCard.render(size: 240, zones: ["Europe/Amsterdam", "America/New_York", "Asia/Tokyo"], clock24h: true) { save(rgba, 240, 240, out.appendingPathComponent("cube-worldclock.png")) }
        // Fetch off the main actor (the main thread blocks on the semaphore), render on it afterwards.
        final class Box: @unchecked Sendable { var day: CryptoStats.CoinDay? }
        let box = Box(); let sem = DispatchSemaphore(value: 0)
        Task.detached { box.day = await CryptoStats.today(id: "ethereum", currency: "eur"); sem.signal() }
        _ = sem.wait(timeout: .now() + 15)
        if let rgba = CryptoCoinCard.render(box.day, coinId: "ethereum", currency: "eur", size: 240) { save(rgba, 240, 240, out.appendingPathComponent("cube-crypto-eth.png")) }
        if let rgba = CryptoCoinCard.render(nil, coinId: "", currency: "eur", size: 240) { save(rgba, 240, 240, out.appendingPathComponent("cube-crypto-empty.png")) }

        print("wrote weather previews to \(dir)")
    }

    private static func save(_ rgba: [UInt8], _ w: Int, _ h: Int, _ url: URL) {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: w*4, bitsPerPixel: 32) else { return }
        if let dst = rep.bitmapData { rgba.withUnsafeBytes { dst.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: w*h*4) } }
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url) }
    }
}
