import Foundation
import UltraBarKit

@MainActor
extension AppModel {
    var vivoCubeSerial: String? {
        if let m = selectedModule, m.isVivoCube { return m.serial }
        return modules.first(where: { $0.isVivoCube })?.serial
    }

    /// Where the weather is for (same rules as `resolveWeather`): manual lat/lon, manual city, Mac location, IP.
    func resolveLocation(settings: AppSettings) async throws -> (lat: Double, lon: Double, name: String) {
        if settings.locationMode == .manual {
            if let lat = Double(settings.manualLat.replacingOccurrences(of: ",", with: ".")),
               let lon = Double(settings.manualLon.replacingOccurrences(of: ",", with: ".")) { return (lat, lon, settings.manualCity) }
            guard !settings.manualCity.isEmpty, let p = try await OpenMeteo.geocode(settings.manualCity) else {
                throw UltraBarError.protocolError("Set a city (or lat/lon) in Widgets → Weather.")
            }
            return (p.latitude, p.longitude, p.name)
        }
        if let loc = await MacLocation().once() { return (loc.lat, loc.lon, loc.place) }
        if !settings.manualCity.isEmpty, let p = try await OpenMeteo.geocode(settings.manualCity) { return (p.latitude, p.longitude, p.name) }
        if let ip = await OpenMeteo.ipLocate() { return (ip.lat, ip.lon, ip.city) }
        throw UltraBarError.protocolError("Allow Location access, or set a city in Widgets → Weather.")
    }

    func resolveWeather(settings: AppSettings, metric: Bool) async throws -> OpenMeteo.Now {
        if settings.locationMode == .manual {
            if let lat = Double(settings.manualLat.replacingOccurrences(of: ",", with: ".")),
               let lon = Double(settings.manualLon.replacingOccurrences(of: ",", with: ".")) {
                return try await OpenMeteo.current(latitude: lat, longitude: lon, metric: metric, placeName: settings.manualCity)
            }
            guard !settings.manualCity.isEmpty, let p = try await OpenMeteo.geocode(settings.manualCity) else {
                throw UltraBarError.protocolError("Set a city (or lat/lon) in Widgets → Weather.")
            }
            return try await OpenMeteo.current(latitude: p.latitude, longitude: p.longitude, metric: metric, placeName: p.name)
        } else {
            if let loc = await MacLocation().once() {
                WireLog.shared.event("weather: using Mac location → \(loc.place.isEmpty ? "?" : loc.place)")
                return try await OpenMeteo.current(latitude: loc.lat, longitude: loc.lon, metric: metric, placeName: loc.place)
            }
            WireLog.shared.event("weather: Mac location unavailable, trying manual city / IP")
            if !settings.manualCity.isEmpty, let p = try await OpenMeteo.geocode(settings.manualCity) {
                return try await OpenMeteo.current(latitude: p.latitude, longitude: p.longitude, metric: metric, placeName: p.name)
            }
            // No Location permission and no manual city: fall back to IP geolocation
            // so the weather still works out of the box (ad-hoc-signed apps often
            // can't use CoreLocation).
            if let ip = await OpenMeteo.ipLocate() {
                return try await OpenMeteo.current(latitude: ip.lat, longitude: ip.lon, metric: metric, placeName: ip.city)
            }
            throw UltraBarError.protocolError("Allow Location access, or set a city in Widgets → Weather.")
        }
    }
}
