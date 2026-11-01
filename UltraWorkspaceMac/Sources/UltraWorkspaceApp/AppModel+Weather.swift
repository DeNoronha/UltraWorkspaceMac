import Foundation
import UltraBarKit

@MainActor
extension AppModel {
    var vivoCubeSerial: String? {
        if let m = selectedModule, m.isVivoCube { return m.serial }
        return modules.first(where: { $0.isVivoCube })?.serial
    }

    /// Fetch weather for the configured location and push a time+weather card to a VivoCube.
    func pushWeather(settings: AppSettings, silent: Bool = false) {
        guard let bar = selectedCoreBar, let session = session(for: bar) else {
            if !silent { say("Pair and select a CoreBar first.") }
            return
        }
        guard let serial = vivoCubeSerial else {
            if !silent { say("No VivoCube found to show the weather on.") }
            return
        }
        let metric = settings.units == .metric
        let clock24 = settings.clock24h
        if !silent { say("Fetching weather…") }
        Task {
            do {
                let now = try await self.resolveWeather(settings: settings, metric: metric)
                self.lastWeather = now
                guard let rgba = WeatherCard.render(width: 240, height: 240, now: now, clock24h: clock24) else {
                    if !silent { self.say("Could not render the weather card.") }
                    return
                }
                let bin = DeviceImage.encode(width: 240, height: 240, rgba: rgba)
                let layer = DeployPackager.Layer(layerId: 1, widgetId: 101, defaultBin: bin, pressedBin: bin)
                let tgz = DeployPackager.buildTgz(layers: [layer], defaultLayer: 1)
                _ = try await session.upload(serial: serial, tgz: tgz)
                self.say("Weather on \(serial): \(Int(now.temperature.rounded()))\(now.unitSuffix) · \(now.sky.label)\(now.place.isEmpty ? "" : " · \(now.place)") ✓")
            } catch {
                if !silent { self.say("Weather failed: \(error.localizedDescription)") }
            }
        }
    }

    func resolveWeather(settings: AppSettings, metric: Bool) async throws -> OpenMeteo.Now {
        if settings.locationMode == .manual {
            if let lat = Double(settings.manualLat.replacingOccurrences(of: ",", with: ".")),
               let lon = Double(settings.manualLon.replacingOccurrences(of: ",", with: ".")) {
                return try await OpenMeteo.current(latitude: lat, longitude: lon, metric: metric, placeName: settings.manualCity)
            }
            guard !settings.manualCity.isEmpty, let p = try await OpenMeteo.geocode(settings.manualCity) else {
                throw UltraBarError.protocolError("Set a city (or lat/lon) in Settings → Weather.")
            }
            return try await OpenMeteo.current(latitude: p.latitude, longitude: p.longitude, metric: metric, placeName: p.name)
        } else {
            if let loc = await MacLocation().once() {
                return try await OpenMeteo.current(latitude: loc.lat, longitude: loc.lon, metric: metric, placeName: loc.place)
            }
            if !settings.manualCity.isEmpty, let p = try await OpenMeteo.geocode(settings.manualCity) {
                return try await OpenMeteo.current(latitude: p.latitude, longitude: p.longitude, metric: metric, placeName: p.name)
            }
            throw UltraBarError.protocolError("Allow Location access, or set a city in Settings → Weather.")
        }
    }

    func setWeatherAuto(_ on: Bool, settings: AppSettings) {
        weatherAutoUpdate = on
        weatherTask?.cancel(); weatherTask = nil
        guard on else { return }
        pushWeather(settings: settings, silent: true)
        weatherTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 600_000_000_000) // 10 min
                guard let self, !Task.isCancelled else { return }
                self.pushWeather(settings: settings, silent: true)
            }
        }
    }
}
