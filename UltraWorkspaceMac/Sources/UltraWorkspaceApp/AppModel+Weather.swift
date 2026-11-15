import Foundation
import UltraBarKit

@MainActor
extension AppModel {
    var vivoCubeSerial: String? {
        if let m = selectedModule, m.isVivoCube { return m.serial }
        return modules.first(where: { $0.isVivoCube })?.serial
    }

    /// How long a resolved location is reused. CoreLocation (which can start a Wi-Fi scan) and Apple's reverse
    /// geocoder (a network call, refusing after a burst) are not meant to be hit often, and a desk does not move:
    /// an hour (5 minutes until 2026-11-15).
    static let locationCacheSeconds: TimeInterval = 3600
    /// How long a failed lookup is not tried again: without this, a Mac without Location access and offline
    /// retried CoreLocation, the IP lookup and the geocoder on every call.
    static let locationRetrySeconds: TimeInterval = 600

    /// Where "here" is: manual lat/lon, manual city, Mac location, IP — the one chain for the weather card,
    /// the clock-card cover, the bar's WEATHER card and the on-bar apps' config document. Cached (see above);
    /// a change of the location settings invalidates the cache at once. A failed refresh keeps the last good
    /// location for these settings; a failure without one is repeated for ten minutes without trying again.
    func resolveLocation(settings: AppSettings) async throws -> (lat: Double, lon: Double, name: String) {
        let key = "\(settings.locationMode.rawValue)|\(settings.manualCity)|\(settings.manualLat)|\(settings.manualLon)"
        let cached = locationCache.flatMap { $0.key == key ? $0 : nil }
        if let c = cached, Date().timeIntervalSince(c.at) < Self.locationCacheSeconds { return c.loc }
        if let f = locationFailure, f.key == key, Date().timeIntervalSince(f.at) < Self.locationRetrySeconds {
            if let c = cached { return c.loc }
            throw UltraBarError.protocolError(f.message)
        }
        do {
            let loc = try await resolveLocationUncached(settings: settings)
            locationCache = (key, Date(), loc); locationFailure = nil
            return loc
        } catch {
            locationFailure = (key, Date(), error.localizedDescription)
            if let c = cached { return c.loc }
            throw error
        }
    }

    private func resolveLocationUncached(settings: AppSettings) async throws -> (lat: Double, lon: Double, name: String) {
        if settings.locationMode == .manual {
            if let lat = Double(settings.manualLat.replacingOccurrences(of: ",", with: ".")),
               let lon = Double(settings.manualLon.replacingOccurrences(of: ",", with: ".")) { return (lat, lon, settings.manualCity) }
            guard !settings.manualCity.isEmpty, let p = try await OpenMeteo.geocode(settings.manualCity) else {
                throw UltraBarError.protocolError("Set a city (or latitude and longitude) in Settings → Location & Units.")
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
        throw UltraBarError.protocolError("Allow Location access, or set a city in Settings → Location & Units.")
    }

    func resolveWeather(settings: AppSettings, metric: Bool) async throws -> OpenMeteo.Now {
        let loc = try await resolveLocation(settings: settings)
        return try await OpenMeteo.current(latitude: loc.lat, longitude: loc.lon, metric: metric, placeName: loc.name)
    }
}
