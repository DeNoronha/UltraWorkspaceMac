import Foundation

/// The vendor's app catalogue for the CoreBar (public, no token). Third-party data: strings are shown,
/// never executed; the bar downloads the APK itself (APP_MANAGER 30600), Deckhand never touches the file.
enum BarAppStore {
    struct StoreApp: Identifiable, Sendable, Hashable {
        var id: String { package }
        let package: String, name: String, versionName: String, versionCode: Int
        let summary: String, changeLog: String, iconURL: URL?
    }

    /// 100 = apps, 101 = screensavers (what the bar's own Settings → Screensaver lists).
    static let appsType = 100, screensaversType = 101
    static func catalogueURL(_ appType: Int) -> URL { URL(string: "https://gatewayssl.dev.aiks360.com/api/v1/base-service/pub/apps/\(appType)/fetchListV2")! }

    static func fetch(appType: Int = appsType) async throws -> [StoreApp] {
        var req = URLRequest(url: catalogueURL(appType))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(#"{"pi":1,"ps":200}"#.utf8)
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let recs = ((obj["data"] as? [String: Any])?["records"] as? [[String: Any]]) ?? (obj["data"] as? [[String: Any]]) ?? []
        return recs.compactMap { r in
            guard let pkg = r["application"] as? String, !pkg.isEmpty else { return nil }
            return StoreApp(package: pkg, name: (r["appName"] as? String) ?? pkg,
                            versionName: (r["versionName"] as? String) ?? "",
                            versionCode: (r["versionCode"] as? Int) ?? 0,
                            summary: (r["desc"] as? String) ?? "", changeLog: (r["changeLog"] as? String) ?? "",
                            iconURL: (r["icon"] as? String).flatMap { URL(string: $0.replacingOccurrences(of: "http://", with: "https://")) })
        }
    }
}
