import Foundation

/// The bar's app store, APP_MANAGER (act 30600). CONFIRMED on hardware 2026-11-03 (launcher 1.0.9):
/// `{type: 0|1|2, appType: 100, packageName}` — 0 = status, 1 = install, 2 = uninstall. The PC sends no
/// URL: the bar looks the package up in the vendor cloud itself (`apps/100/<package>/fetchLastVerV2`),
/// downloads and installs it. Only one install runs at a time.
public extension CoreBarSession {
    struct AppStatus: Sendable, Equatable {
        public let installed: Bool
        public let versionCode: Int
        public let versionName: String
    }

    func appStatus(package: String) async throws -> AppStatus {
        let line = try await rawRequest(act: 30600, data: ["type": 0, "packageName": package], timeout: 15)
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let d = obj["data"] as? [String: Any], let st = d["status"] as? String else {
            throw UltraBarError.protocolError("30600 status: \(line.prefix(200))")
        }
        return AppStatus(installed: st == "INSTALLED",
                         versionCode: (d["versionCode"] as? Int) ?? 0,
                         versionName: (d["versionName"] as? String) ?? "")
    }

    /// Asks the bar to install (`appType` 100 = the CoreBar app store). Returns the first reply line
    /// (usually a 30601 progress push `STATUS: DOWNLOADING`); poll `appStatus` for the outcome.
    /// `appType`: 100 = the CoreBar app store, 101 = the screensaver catalogue (both confirmed 2026-11-03).
    @discardableResult
    func installApp(package: String, appType: Int = 100) async throws -> String {
        try await rawRequest(act: 30600, data: ["type": 1, "appType": appType, "packageName": package], timeout: 15)
    }

    func uninstallApp(package: String) async throws -> Bool {
        let line = try await rawRequest(act: 30600, data: ["type": 2, "packageName": package], timeout: 15)
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return false }
        return ((obj["code"] as? Int) ?? (obj["code"] as? NSNumber)?.intValue) == 200
    }
}
