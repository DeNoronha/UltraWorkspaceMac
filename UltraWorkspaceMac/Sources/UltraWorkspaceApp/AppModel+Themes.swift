import Foundation
import AppKit
import UltraBarKit

@MainActor
extension AppModel {
    /// Start (or restart) the VivoCube theme carousel from settings.
    func startThemeRotation(settings: AppSettings) {
        themeTask?.cancel(); themeTask = nil
        let themes = settings.enabledList(for: .vivocube)
        guard selectedCoreBar != nil, session(for: selectedCoreBar!) != nil, vivoCubeSerial != nil else {
            say("Pair a CoreBar with a VivoCube first."); themeRunning = false; return
        }
        guard !themes.isEmpty else { say("Tick at least one widget for the VivoCube."); themeRunning = false; return }
        themeRunning = true
        themeIndex = 0
        let interval = max(10, settings.vivoSeconds)
        if themes.count == 1 {
            say("Publishing \(themes[0].title) to the VivoCube…")
        } else {
            say("Rotation started: \(themes.map(\.title).joined(separator: ", ")) · every \(interval)s")
        }
        themeTask = Task {
            while !Task.isCancelled {
                let list = settings.enabledList(for: .vivocube)
                if list.isEmpty { break }
                let t = list[self.themeIndex % list.count]
                self.themeIndex += 1
                self.currentThemeLabel = t.title
                await self.pushTheme(t, settings: settings)
                if list.count == 1 { break } // single widget: publish once, no rotation
                try? await Task.sleep(nanoseconds: UInt64(max(10, settings.vivoSeconds)) * 1_000_000_000)
            }
            self.themeRunning = false
        }
    }

    func stopThemeRotation() {
        themeTask?.cancel(); themeTask = nil
        themeRunning = false
        say("Display stopped.")
    }

    /// Render one theme now and push it to a specific VivoCube (default: first).
    func pushTheme(_ theme: Theme, settings: AppSettings, to serial: String? = nil) async {
        guard let bar = selectedCoreBar, let session = session(for: bar),
              let target = serial ?? vivoCubeSerial else { return }
        guard let rgba = await renderTheme(theme, settings: settings) else { return }
        let bin = DeviceImage.encode(width: 240, height: 240, rgba: rgba)
        let layer = DeployPackager.Layer(layerId: 1, widgetId: 101, defaultBin: bin, pressedBin: bin)
        let tgz = DeployPackager.buildTgz(layers: [layer], defaultLayer: 1)
        do { _ = try await session.upload(serial: target, tgz: tgz) }
        catch { say("\(theme.title): push failed (\(error.localizedDescription))") }
    }

    /// Publish one add-on to a specific VivoCube now (user-facing, with status).
    func publishAddon(_ theme: Theme, to serial: String, settings: AppSettings) {
        guard let bar = selectedCoreBar, let session = session(for: bar) else { return }
        say("Publishing \(theme.title) to \(serial)…")
        Task {
            guard let rgba = await self.renderTheme(theme, settings: settings) else {
                self.say("\(theme.title): could not render."); return
            }
            let bin = DeviceImage.encode(width: 240, height: 240, rgba: rgba)
            let layer = DeployPackager.Layer(layerId: 1, widgetId: 101, defaultBin: bin, pressedBin: bin)
            let tgz = DeployPackager.buildTgz(layers: [layer], defaultLayer: 1)
            do { _ = try await session.upload(serial: serial, tgz: tgz); self.say("\(theme.title) published to \(serial). ✓") }
            catch { self.say("\(theme.title): publish failed (\(error.localizedDescription))") }
        }
    }

    private func renderTheme(_ theme: Theme, settings: AppSettings) async -> [UInt8]? {
        switch theme {
        case .weather:
            do {
                let now = try await resolveWeather(settings: settings, metric: settings.units == .metric)
                lastWeather = now
                WireLog.shared.event("weather: \(Int(now.temperature.rounded()))\(now.unitSuffix) \(now.sky.label) @ \(now.place.isEmpty ? "?" : now.place)")
                return WeatherCard.render(width: 240, height: 240, now: now, clock24h: settings.clock24h)
            } catch {
                say("Weather unavailable: \(error.localizedDescription)")
                WireLog.shared.event("weather FAILED: \(error.localizedDescription)")
                return WeatherCard.render(width: 240, height: 240, now: nil, clock24h: settings.clock24h)
            }
        case .music:
            refreshNowPlaying()
            let art = AppleMusic.currentArtwork()
            return NowPlayingCard.render(size: 240, art: art, title: nowPlaying.title, artist: nowPlaying.artist)
        case .cpu:
            _ = sysStats.sample()
            try? await Task.sleep(nanoseconds: 900_000_000)
            return StatCard.system(sysStats.sample(), size: 240)
        case .network:
            _ = netStats.sample()
            try? await Task.sleep(nanoseconds: 900_000_000)
            return StatCard.network(netStats.sample(), size: 240)
        case .claude:
            let snap = await Task.detached { ClaudeUsage.snapshot() }.value
            return StatCard.claude(snap, size: 240)
        case .battery:
            return BatteryCard.render(BatteryStats.sample(), size: 240)
        case .disk:
            return DiskCard.render(size: 240)
        case .worldclock:
            return WorldClockCard.render(size: 240, zones: WorldClockCard.defaultZones, clock24h: settings.clock24h)
        case .crypto:
            let coins = await CryptoStats.fetch(currency: "eur")
            return CryptoCard.render(coins, size: 240, currencySymbol: CryptoStats.suffix(for: "eur"))
        case .calendar:
            var auth = CalendarSource.authStatus()
            if auth == .notDetermined { _ = await CalendarSource.requestAccess(); auth = CalendarSource.authStatus() }
            let events = auth == .authorized ? await CalendarSource.upcoming() : []
            return CalendarCard.render(events, auth: auth, size: 240, clock24h: settings.clock24h)
        }
    }
}
