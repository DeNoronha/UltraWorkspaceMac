import Foundation
import Security

/// Persists pairing tokens (user-only 0600 files, not the Keychain — see below) and per-CoreBar metadata (cert pin, last
/// known IP, friendly name) in Application Support.
public final class Store: @unchecked Sendable {
    public static let shared = Store()

    private let service = "com.denoronha.ultraworkspacemac.token"
    private let fileURL: URL
    private let queue = DispatchQueue(label: "ultrabar.store")

    public struct PairedCoreBar: Codable, Identifiable, Sendable {
        public var serialNo: String
        public var name: String
        public var lastIp: String
        public var certSHA256: String?
        /// The bar's own hotspot as last reported by a module (property 7). Differs per unit.
        public var hotspotSSID: String?
        public var hotspotPassword: String?
        /// Every Wi-Fi the cube has been joined to from this Mac (ssid → password), so switching back is one click.
        public var savedNetworks: [String: String]?
        public var id: String { serialNo }
    }

    private struct Persisted: Codable { var coreBars: [PairedCoreBar] = [] }
    private var state = Persisted()

    private convenience init() {
        self.init(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("UltraWorkspaceMac", isDirectory: true))
    }

    /// A store rooted at `directory` (the app uses `shared`, in Application Support; checks use a temporary folder).
    public init(directory base: URL) {
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("corebars.json")
        if let data = try? Data(contentsOf: fileURL),
           let p = try? JSONDecoder().decode(Persisted.self, from: data) {
            state = p
        }
    }

    // MARK: Paired CoreBars

    public var pairedCoreBars: [PairedCoreBar] {
        queue.sync { state.coreBars }
    }

    public func certPin(for serial: String) -> String? {
        queue.sync { state.coreBars.first { $0.serialNo == serial }?.certSHA256 }
    }

    public func upsert(serial: String, name: String, ip: String, certSHA256: String?) {
        queue.sync {
            if let idx = state.coreBars.firstIndex(where: { $0.serialNo == serial }) {
                state.coreBars[idx].name = name
                state.coreBars[idx].lastIp = ip
                if let certSHA256 { state.coreBars[idx].certSHA256 = certSHA256 }
            } else {
                state.coreBars.append(PairedCoreBar(serialNo: serial, name: name, lastIp: ip, certSHA256: certSHA256))
            }
            persist()
        }
    }

    /// Remember a CoreBar's hotspot credentials (learned from a cube that reports them, or typed by the user).
    public func setHotspot(serial: String, ssid: String, password: String) {
        queue.sync {
            guard let idx = state.coreBars.firstIndex(where: { $0.serialNo == serial }) else { return }
            state.coreBars[idx].hotspotSSID = ssid
            state.coreBars[idx].hotspotPassword = password
            persist()
        }
    }
    public func rememberNetwork(serial: String, ssid: String, password: String) {
        queue.sync {
            guard let idx = state.coreBars.firstIndex(where: { $0.serialNo == serial }), !ssid.isEmpty else { return }
            var n = state.coreBars[idx].savedNetworks ?? [:]
            n[ssid] = password
            state.coreBars[idx].savedNetworks = n
            persist()
        }
    }
    public func forgetNetwork(serial: String, ssid: String) {
        queue.sync {
            guard let idx = state.coreBars.firstIndex(where: { $0.serialNo == serial }) else { return }
            state.coreBars[idx].savedNetworks?[ssid] = nil
            persist()
        }
    }
    public func savedNetworks(serial: String) -> [(ssid: String, password: String)] {
        queue.sync { (state.coreBars.first { $0.serialNo == serial }?.savedNetworks ?? [:]).sorted { $0.key < $1.key }.map { ($0.key, $0.value) } }
    }
    public func hotspot(serial: String) -> (ssid: String, password: String)? {
        queue.sync {
            guard let b = state.coreBars.first(where: { $0.serialNo == serial }), let s = b.hotspotSSID, let p = b.hotspotPassword, !s.isEmpty else { return nil }
            return (s, p)
        }
    }

    /// Forgets a CoreBar: its entry, its token and the per-serial endpoint caches.
    public func remove(serial: String) {
        queue.sync {
            state.coreBars.removeAll { $0.serialNo == serial }
            persist()
        }
        deleteToken(serial: serial)
        try? FileManager.default.removeItem(at: endpointsURL(serial))
        try? FileManager.default.removeItem(at: knownURL(serial))
    }

    private func persist() {
        // Holds hotspot passwords since 2026-11-03: user-only.
        if let data = try? JSONEncoder().encode(state) { Self.writePrivate(data, to: fileURL) }
    }

    /// Writes `data` to `url` so that no other user can ever read it: the temporary file is created with
    /// mode 0600 by `open(2)` itself (`Data.write(.atomic)` creates it with the umask, 0644 by default, and a
    /// later chmod leaves a window), then renamed over the target. Returns false if any step failed.
    @discardableResult
    public static func writePrivate(_ data: Data, to url: URL) -> Bool {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8)).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        var ok = data.withUnsafeBytes { raw -> Bool in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        if ok { ok = fsync(fd) == 0 }
        ok = close(fd) == 0 && ok
        if ok { ok = rename(tmp.path, url.path) == 0 }
        if !ok { unlink(tmp.path) }
        return ok
    }

    // MARK: Tokens
    //
    // Stored as user-only files in Application Support rather than the Keychain.
    // An ad-hoc-signed app gets a new code signature on every rebuild, which
    // makes the Keychain re-prompt for the login password every launch. A file
    // (0600, in the user's own app-support dir) avoids that friction. For a
    // notarized/Developer-ID release this can move back to the Keychain.

    private func tokenURL(_ serial: String) -> URL {
        let dir = fileURL.deletingLastPathComponent().appendingPathComponent("tokens", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let safe = serial.filter { $0.isLetter || $0.isNumber }
        return dir.appendingPathComponent("\(safe).token")
    }

    public func saveToken(_ token: String, serial: String) {
        Self.writePrivate(Data(token.utf8), to: tokenURL(serial))
    }

    public func loadToken(serial: String) -> String? {
        guard let data = try? Data(contentsOf: tokenURL(serial)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Other secrets (API keys for the bar apps), same user-only files.

    public func saveSecret(_ value: String, name: String) {
        let url = tokenURL("secret-\(name)")
        if value.isEmpty { try? FileManager.default.removeItem(at: url); return }
        Self.writePrivate(Data(value.utf8), to: url)
    }

    public func loadSecret(name: String) -> String? {
        guard let data = try? Data(contentsOf: tokenURL("secret-\(name)")) else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func deleteToken(serial: String) {
        try? FileManager.default.removeItem(at: tokenURL(serial))
    }

    // MARK: Gateway endpoint cache
    //
    // Remembers the raw module endpoints last written to a CoreBar's gateway
    // config. Re-provisioning merges freshly discovered modules with this cache
    // so a module that happens to be asleep during a scan is not dropped.

    private func endpointsURL(_ serial: String) -> URL {
        let dir = fileURL.deletingLastPathComponent().appendingPathComponent("endpoints", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = serial.filter { $0.isLetter || $0.isNumber }
        return dir.appendingPathComponent("\(safe).json")
    }

    /// Append-only list of module endpoints ever discovered on a CoreBar (by module serial).
    public func rememberModules(_ endpoints: [[String: Any]], corebar serial: String) {
        var known = knownModules(corebar: serial)
        for e in endpoints {
            guard let ms = (e["serialNumber"] as? String) ?? (e["serialNo"] as? String), !ms.isEmpty else { continue }
            known[ms] = e
        }
        if let data = try? JSONSerialization.data(withJSONObject: Array(known.values)) {
            try? data.write(to: knownURL(serial), options: .atomic)
        }
    }
    public func knownModules(corebar serial: String) -> [String: [String: Any]] {
        guard let data = try? Data(contentsOf: knownURL(serial)),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        var out: [String: [String: Any]] = [:]
        for e in arr { if let ms = (e["serialNumber"] as? String) ?? (e["serialNo"] as? String) { out[ms] = e } }
        return out
    }
    private func knownURL(_ serial: String) -> URL {
        endpointsURL(serial).deletingLastPathComponent().appendingPathComponent("\(serial.filter { $0.isLetter || $0.isNumber }).known.json")
    }

    public func saveEndpoints(_ data: Data, serial: String) {
        try? data.write(to: endpointsURL(serial), options: .atomic)
    }

    public func loadEndpoints(serial: String) -> Data? {
        try? Data(contentsOf: endpointsURL(serial))
    }
}
