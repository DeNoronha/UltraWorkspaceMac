import Foundation
import UltraBarKit

/// Screensaver section of the Apps page: which screensaver app runs, after how long, on/off.
extension AppModel {
    /// Legacy (ver < 2) screensaver apps identify themselves by a uri host from their manifest; the PC
    /// cannot read manifests, so the ones seen on hardware are listed here. Everything else is
    /// addressed by package name (ver 2).
    static let legacyScreensaverURIs: [String: String] = ["com.racecar.screensaver": "racecar"]

    var screensaverApps: [CoreBarSession.AppInfo] { barApps.filter(\.isScreensaver) }

    func isActiveScreensaver(_ a: CoreBarSession.AppInfo) -> Bool {
        guard let c = screensaver, let host = c.activeHost else { return false }
        return host == a.packageName || host == Self.legacyScreensaverURIs[a.packageName]
    }

    func readScreensaver() {
        guard let bar = selectedCoreBar, let session = session(for: bar) else { return }
        Task { if let c = try? await session.readScreensaver() { self.screensaver = c } }
    }

    func setScreensaver(enabled: Bool? = nil, lockTime: String? = nil, app: CoreBarSession.AppInfo? = nil) {
        guard let bar = selectedCoreBar, let session = session(for: bar) else { return }
        var c = screensaver ?? CoreBarSession.ScreensaverConfig(featureEnabled: false, lockTime: "TIME_5MIN", packageName: nil, uri: nil, ver: 0)
        if let enabled { c.featureEnabled = enabled }
        if let lockTime { c.lockTime = lockTime }
        if let app {
            if let uri = Self.legacyScreensaverURIs[app.packageName] { c.uri = uri; c.packageName = app.packageName; c.ver = 0 }
            else { c.packageName = app.packageName; c.uri = app.packageName; c.ver = 2 }
        }
        let want = c
        Task {
            do {
                if try await session.writeScreensaver(want) {
                    self.screensaver = (try? await session.readScreensaver()) ?? want
                    say("Bar: screensaver " + (want.featureEnabled ? "on, after \(Self.lockTimeLabel(want.lockTime))" : "off") + (app.map { " · \($0.appName)" } ?? "") + ".")
                } else { self.appStoreError = "The bar refused the screensaver setting." }
            } catch { self.appStoreError = "Screensaver setting failed: \(FriendlyError.text(error))" }
        }
    }

    static func lockTimeLabel(_ t: String) -> String {
        switch t {
        case "TIME_30S": return "30 s"
        case "TIME_1MIN": return "1 min"
        case "TIME_2MIN": return "2 min"
        case "TIME_3MIN": return "3 min"
        case "TIME_4MIN": return "4 min"
        case "TIME_5MIN": return "5 min"
        case "NEVER": return "never"
        default: return t
        }
    }
}
