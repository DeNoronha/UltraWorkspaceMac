import Foundation
import AppKit
import UltraBarKit

@MainActor
extension AppModel {
    /// Start (or restart) the VivoCube theme carousel from settings.
    func startThemeRotation(settings: AppSettings) {
        themeTask?.cancel(); themeTask = nil
        let themes = settings.enabledThemeList
        guard selectedCoreBar != nil, session(for: selectedCoreBar!) != nil, vivoCubeSerial != nil else {
            say("Pair a CoreBar with a VivoCube first."); themeRunning = false; return
        }
        guard !themes.isEmpty else { say("Enable at least one theme in Settings."); themeRunning = false; return }
        themeRunning = true
        themeIndex = 0
        let interval = max(10, settings.rotateSeconds)
        say("Display started: \(themes.map(\.title).joined(separator: ", ")) · every \(interval)s")
        themeTask = Task {
            while !Task.isCancelled {
                let list = settings.enabledThemeList
                if list.isEmpty { break }
                let t = list[self.themeIndex % list.count]
                self.themeIndex += 1
                self.currentThemeLabel = t.title
                await self.pushTheme(t, settings: settings)
                try? await Task.sleep(nanoseconds: UInt64(max(10, settings.rotateSeconds)) * 1_000_000_000)
            }
            self.themeRunning = false
        }
    }

    func stopThemeRotation() {
        themeTask?.cancel(); themeTask = nil
        themeRunning = false
        say("Display stopped.")
    }

    /// Render one theme now and push it to the VivoCube.
    func pushTheme(_ theme: Theme, settings: AppSettings) async {
        guard let bar = selectedCoreBar, let session = session(for: bar), let serial = vivoCubeSerial else { return }
        guard let rgba = await renderTheme(theme, settings: settings) else { return }
        let bin = DeviceImage.encode(width: 240, height: 240, rgba: rgba)
        let layer = DeployPackager.Layer(layerId: 1, widgetId: 101, defaultBin: bin, pressedBin: bin)
        let tgz = DeployPackager.buildTgz(layers: [layer], defaultLayer: 1)
        do { _ = try await session.upload(serial: serial, tgz: tgz) }
        catch { say("\(theme.title): push failed (\(error.localizedDescription))") }
    }

    private func renderTheme(_ theme: Theme, settings: AppSettings) async -> [UInt8]? {
        switch theme {
        case .weather:
            let now = try? await resolveWeather(settings: settings, metric: settings.units == .metric)
            if let now { lastWeather = now }
            return WeatherCard.render(width: 240, height: 240, now: now, clock24h: settings.clock24h)
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
        }
    }
}
