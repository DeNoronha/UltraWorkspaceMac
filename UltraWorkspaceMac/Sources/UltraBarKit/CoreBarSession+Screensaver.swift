import Foundation

/// The bar's screensaver setting (GET/SET_COREBAR_CONFIG 30740/30741, type BASE_SET). The launcher
/// starts a separate screensaver app with `screensaver://<host>/start`; host = `uri` when `ver < 2`,
/// else `packageName`. Idle time = `lockTime`; `NEVER` still arms the timer while `featureEnabled`.
public extension CoreBarSession {
    struct ScreensaverConfig: Sendable, Equatable {
        public var featureEnabled: Bool
        public var lockTime: String      // TIME_30S, TIME_1MIN … TIME_5MIN, NEVER
        public var packageName: String?
        public var uri: String?
        public var ver: Int
        public init(featureEnabled: Bool, lockTime: String, packageName: String?, uri: String?, ver: Int) {
            self.featureEnabled = featureEnabled; self.lockTime = lockTime; self.packageName = packageName; self.uri = uri; self.ver = ver
        }
        /// What the launcher would start: the package (ver ≥ 2) or the legacy uri host.
        public var activeHost: String? { ver >= 2 ? packageName : (uri ?? packageName) }
        public static let lockTimes = ["TIME_30S", "TIME_1MIN", "TIME_2MIN", "TIME_3MIN", "TIME_4MIN", "TIME_5MIN", "NEVER"]
    }

    func readScreensaver() async throws -> ScreensaverConfig {
        let line = try await rawRequest(act: 30740, data: ["type": "BASE_SET"], timeout: 10)
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let d = obj["data"] as? [String: Any] else { throw UltraBarError.protocolError("30740 BASE_SET: \(line.prefix(200))") }
        return ScreensaverConfig(featureEnabled: (d["featureEnabled"] as? Bool) ?? false,
                                 lockTime: (d["lockTime"] as? String) ?? "NEVER",
                                 packageName: d["packageName"] as? String, uri: d["uri"] as? String,
                                 ver: (d["ver"] as? Int) ?? 0)
    }

    /// Writes the whole config (the launcher replaces it). CONFIRMED accepted on launcher 1.0.9 (2026-11-03).
    func writeScreensaver(_ c: ScreensaverConfig) async throws -> Bool {
        var v: [String: Any] = ["featureEnabled": c.featureEnabled, "lockTime": c.lockTime, "ver": c.ver]
        if let p = c.packageName { v["packageName"] = p }
        if let u = c.uri { v["uri"] = u }
        let line = try await rawRequest(act: 30741, data: ["type": "BASE_SET", "value": v], timeout: 10)
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return false }
        return ((obj["code"] as? Int) ?? (obj["code"] as? NSNumber)?.intValue) == 200
    }
}
