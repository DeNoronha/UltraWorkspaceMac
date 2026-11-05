import Foundation

/// The vendor's software releases on GitHub (`Qinkunex/UltraWorkspace`): the bar's launcher (`LineOS.V1.0.9.9.apk`),
/// its bridge service (`bridge.1.0.4.4.apk`) and the SenseCube firmware. Deckhand reads the latest release, downloads
/// the two APKs and installs them over the debug bridge, so nobody needs the vendor's desktop app for an update.
public enum VendorRelease {
    public static let repo = "Qinkunex/UltraWorkspace"
    public static let latestURL = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    public static let pageURL = URL(string: "https://github.com/\(repo)/releases")!

    /// The packages the two APKs carry; an APK whose manifest names anything else is never installed.
    public static let launcherPackage = "com.ultrabar.launch"
    public static let bridgePackage = "com.ultrabar.hub"

    public struct Asset: Sendable, Equatable {
        public var name: String
        public var url: URL
        public var size: Int
        /// As printed in the file name, e.g. `1.0.9.9`: the first three parts are the versionName, the last the versionCode.
        public var version: String
        public var versionName: String { VendorRelease.split(version).name }
        public var versionCode: Int { VendorRelease.split(version).code }
    }

    public struct Release: Sendable {
        public var tag: String
        public var published: Date?
        public var launcher: Asset?
        public var bridge: Asset?
        public var senseCubeFirmware: Asset?
    }

    /// `1.0.9.9` → name `1.0.9`, code 9; `1.0.4.4` → `1.0.4`, 4. A three-part version has no code (0).
    public static func split(_ v: String) -> (name: String, code: Int) {
        let parts = v.split(separator: ".").map(String.init)
        guard parts.count >= 4, let code = Int(parts.last!) else { return (v, 0) }
        return (parts.dropLast().joined(separator: "."), code)
    }

    /// Parse GitHub's "latest release" JSON. Assets are matched by their file names only.
    public static func parse(_ data: Data) throws -> Release {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else { throw UltraBarError.protocolError("not a GitHub release") }
        var rel = Release(tag: tag)
        if let p = obj["published_at"] as? String { rel.published = ISO8601DateFormatter().date(from: p) }
        for a in (obj["assets"] as? [[String: Any]]) ?? [] {
            guard let name = a["name"] as? String, let urlS = a["browser_download_url"] as? String, let url = URL(string: urlS),
                  url.scheme == "https", url.host == "github.com" else { continue }
            let size = (a["size"] as? Int) ?? 0
            if let v = capture(name, #"^LineOS\.V(\d+(?:\.\d+){1,3})\.apk$"#) { rel.launcher = Asset(name: name, url: url, size: size, version: v) }
            else if let v = capture(name, #"^bridge\.(\d+(?:\.\d+){1,3})\.apk$"#) { rel.bridge = Asset(name: name, url: url, size: size, version: v) }
            else if name.lowercased().hasSuffix("_ota.bin"), name.lowercased().contains("cube") { rel.senseCubeFirmware = Asset(name: name, url: url, size: size, version: "") }
        }
        return rel
    }

    public static func fetchLatest() async throws -> Release {
        var req = URLRequest(url: latestURL); req.timeoutInterval = 15
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Deckhand (+https://denoronha.github.io/UltraWorkspaceMac/)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw UltraBarError.protocolError("GitHub answered \(h.statusCode)") }
        return try parse(data)
    }

    private static func capture(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }
}
