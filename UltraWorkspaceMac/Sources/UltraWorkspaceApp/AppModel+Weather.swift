import Foundation
import UltraBarKit

@MainActor
extension AppModel {
    var vivoCubeSerial: String? {
        if let m = selectedModule, m.isVivoCube { return m.serial }
        return modules.first(where: { $0.isVivoCube })?.serial
    }

    /// How long a resolved location is reused. The bar apps' config document asks every 10 s;
    /// CoreLocation and Apple's reverse geocoder are not meant to be hit at that rate (the geocoder starts
    /// refusing after a burst), and nothing here moves that fast.
    static let locationCacheSeconds: TimeInterval = 300

    /// Where "here" is: manual lat/lon, manual city, Mac location, IP — the one chain for the weather card,
    /// the clock-card cover, the bar's WEATHER card and the on-bar apps' config document. Cached (see above);
    /// a change of the location settings invalidates the cache at once.
    func resolveLocation(settings: AppSettings) async throws -> (lat: Double, lon: Double, name: String) {
        let key = "\(settings.locationMode.rawValue)|\(settings.manualCity)|\(settings.manualLat)|\(settings.manualLon)"
        if let c = locationCache, c.key == key, Date().timeIntervalSince(c.at) < Self.locationCacheSeconds { return c.loc }
        let loc = try await resolveLocationUncached(settings: settings)
        locationCache = (key, Date(), loc)
        return loc
    }

    private func resolveLocationUncached(settings: AppSettings) async throws -> (lat: Double, lon: Double, name: String) {
        if settings.locationMode == .manual {
            if let lat = Double(settings.manualLat.replacingOccurrences(of: ",", with: ".")),
               let lon = Double(settings.manualLon.replacingOccurrences(of: ",", with: ".")) { return (lat, lon, settings.manualCity) }
            guard !settings.manualCity.isEmpty, let p = try await OpenMeteo.geocode(settings.manualCity) else {
                throw UltraBarError.protocolError("Set a city (or lat/lon) in Widgets → Weather.")
            }
            return (p.latitude, p.longitude, p.name)
        }
        if let loc = await MacLocation().once() {
            WireLog.shared.event("location: using Mac location → \(loc.place.isEmpty ? "?" : loc.place)")
            return (loc.lat, loc.lon, loc.place)
        }
        WireLog.shared.event("location: Mac location unavailable, trying manual city / IP")
        if !settings.manualCity.isEmpty, let p = try await OpenMeteo.geocode(settings.manualCity) { return (p.latitude, p.longitude, p.name) }
        // No Location permission and no manual city: fall back to IP geolocation so the weather still
        // works out of the box (ad-hoc-signed apps often can't use CoreLocation).
        if let ip = await OpenMeteo.ipLocate() { return (ip.lat, ip.lon, ip.city) }
        throw UltraBarError.protocolError("Allow Location access, or set a city in Widgets → Weather.")
    }

    func resolveWeather(settings: AppSettings, metric: Bool) async throws -> OpenMeteo.Now {
        let loc = try await resolveLocation(settings: settings)
        return try await OpenMeteo.current(latitude: loc.lat, longitude: loc.lon, metric: metric, placeName: loc.name)
    }
}
