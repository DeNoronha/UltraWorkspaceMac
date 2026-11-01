import Foundation
import CoreLocation

/// One-shot access to this Mac's location (for "same as this Mac"). Returns nil
/// if permission is denied or unavailable; callers fall back to a manual city.
@MainActor
final class MacLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var cont: CheckedContinuation<CLLocation?, Never>?

    func once(timeout: TimeInterval = 8) async -> (lat: Double, lon: Double, place: String)? {
        manager.delegate = self
        let status = manager.authorizationStatus
        if status == .notDetermined { manager.requestWhenInUseAuthorization() }
        if status == .denied || status == .restricted { return nil }

        let loc: CLLocation? = await withCheckedContinuation { c in
            self.cont = c
            manager.requestLocation()
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let cc = self.cont { self.cont = nil; cc.resume(returning: nil) }
            }
        }
        guard let loc else { return nil }
        let place = await reverseGeocode(loc)
        return (loc.coordinate.latitude, loc.coordinate.longitude, place)
    }

    private func reverseGeocode(_ loc: CLLocation) async -> String {
        let geo = CLGeocoder()
        if let marks = try? await geo.reverseGeocodeLocation(loc), let m = marks.first {
            return m.locality ?? m.administrativeArea ?? m.country ?? ""
        }
        return ""
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let loc = locations.last
        Task { @MainActor in
            if let c = self.cont { self.cont = nil; c.resume(returning: loc) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if let c = self.cont { self.cont = nil; c.resume(returning: nil) }
        }
    }
}
