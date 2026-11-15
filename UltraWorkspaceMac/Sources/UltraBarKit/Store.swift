import Foundation
import Security

/// Per-CoreBar metadata (cert pin, last known IP, friendly name, hotspot SSID) in `corebars.json`, and every secret
/// through a `SecretStore`: the login Keychain in a Developer-ID build, user-only files in a development build and in
/// `kitcheck` (see SecretStore.swift). Secrets are read once and then served from memory.
public final class Store: @unchecked Sendable {
    public static let shared = Store()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "ultrabar.store")
    /// Where the secrets live.
    public let secrets: SecretStore
    /// Secrets read so far (nil = looked up, none there), so the Keychain is not asked on every poll.
    private var cache: [SecretAccount: String?] = [:]
    /// Debounced writes (a key typed into a field is written once typing stops, not per keystroke).
    private var pending: [SecretAccount: DispatchWorkItem] = [:]
    private let writeQueue = DispatchQueue(label: "ultrabar.store.secrets")
    /// What the move of the old plain-file secrets did at launch (nil when it did not run in this process).
    public private(set) var migrationReport: SecretMigration.Report?
    /// UserDefaults flag set once every legacy secret is in the store (one per kind of store).
    public static func migrationFlag(_ kind: String) -> String { "secretsMigratedV1.\(kind)" }

    public struct PairedCoreBar: Codable, Identifiable, Sendable {
        public var serialNo: String
        public var name: String
        public var lastIp: String
        public var certSHA256: String?
        /// The bar's own hotspot as last reported by a module (property 7). Differs per unit. Its password is in
        /// the secret store (`bar-hotspot:<serial>`).
        public var hotspotSSID: String?
        /// Before 0.5 the hotspot password and the saved networks were kept here; read only by the migration.
        public var hotspotPassword: String?
        public var savedNetworks: [String: String]?
        /// Every Wi-Fi the cube has been joined to from this Mac; the passwords are in the secret store
        /// (`wifi:<serial>:<ssid>`), so switching back is one click.
        public var savedSSIDs: [String]?
        public var id: String { serialNo }
    }

    private struct Persisted: Codable { var coreBars: [PairedCoreBar] = [] }
    private var state = Persisted()

    private convenience init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("UltraWorkspaceMac", isDirectory: true)
        // Only the app itself moves the old files (never kitcheck or another tool linking this library).
        let isApp = Bundle.main.bundleIdentifier == SecretStores.service || ProcessInfo.processInfo.processName == "UltraWorkspaceApp"
        self.init(directory: base, secrets: SecretStores.makeDefault(fileDirectory: base), migrate: isApp ? .standard : nil)
    }

    /// A store rooted at `directory` (the app uses `shared`, in Application Support; checks use a temporary folder).
    /// `secrets` defaults to user-only files under `directory`. With `migrate`, the plain-file secrets of older
    /// versions are moved into `secrets` first (flag kept in that UserDefaults).
    public init(directory base: URL, secrets: SecretStore? = nil, migrate defaults: UserDefaults? = nil) {
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("corebars.json")
        let store = secrets ?? FileSecretStore(directory: base)
        self.secrets = store
        if let defaults {
            let extra = store is FileSecretStore ? nil : FileSecretStore(directory: base)
            let r = SecretMigration.run(directory: base, into: store, defaults: defaults,
                                        flagKey: Self.migrationFlag(store.kind), extraSource: extra)
            migrationReport = r
            // Only the app's own store writes to the app's log (a check's temporary store must not touch it).
            if defaults === UserDefaults.standard {
                for f in r.failed { WireLog.shared.event("secret \(f.account) not migrated: OSStatus \(f.status)") }
                if !r.moved.isEmpty { WireLog.shared.event("secrets: \(r.moved.count) moved to the \(store.kind)") }
            }
        }
        if let data = try? Data(contentsOf: fileURL),
           let p = try? JSONDecoder().decode(Persisted.self, from: data) {
            state = p
        }
    }

    // MARK: Secrets (cached)

    public func secret(_ a: SecretAccount) -> String? {
        if let hit = queue.sync(execute: { cache[a] }) { return hit }
        let v = secrets.get(a)
        queue.sync { cache[a] = .some(v) }
        return v
    }

    /// Store a secret (nil/empty deletes it). `debounce`: written 0.8 s after the last call for the same account.
    @discardableResult
    public func setSecret(_ value: String?, for a: SecretAccount, debounce: Bool = false) -> OSStatus {
        let v = (value?.isEmpty ?? true) ? nil : value
        queue.sync { cache[a] = .some(v); pending[a]?.cancel(); pending[a] = nil }
        guard debounce else { return writeQueue.sync { secrets.set(v, for: a) } }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let st = self.secrets.set(v, for: a)
            if st != errSecSuccess { WireLog.shared.event("secret \(a) not saved: OSStatus \(st)") }
        }
        queue.sync { pending[a] = item }
        writeQueue.asyncAfter(deadline: .now() + 0.8, execute: item)
        return errSecSuccess
    }

    /// Write every debounced secret now (at quit).
    public func flushPendingSecrets() {
        let items = queue.sync { () -> [DispatchWorkItem] in let v = Array(pending.values); pending.removeAll(); return v }
        for i in items where !i.isCancelled { writeQueue.sync { i.perform() } }
    }

    /// The random key the bar's Deckhand apps send with every data request (64 hex characters), made on first use.
    public func barKey(serial: String) -> String {
        if let k = secret(.barKey(serial: serial)), k.count == 64 { return k }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return "" }
        let k = bytes.map { String(format: "%02x", $0) }.joined()
        setSecret(k, for: .barKey(serial: serial))
        return k
    }

    /// The secret-store account a legacy secret name maps to (`saveSecret(name:)`).
    public static func account(forSecret name: String) -> SecretAccount {
        switch name {
        case "strava-tokens": return .oauth("strava")
        case "schiphol-key": return .api("schiphol-secret")
        default: return .api(name)
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
        let known = queue.sync { () -> Bool in
            guard let idx = state.coreBars.firstIndex(where: { $0.serialNo == serial }) else { return false }
            state.coreBars[idx].hotspotSSID = ssid
            state.coreBars[idx].hotspotPassword = nil
            persist()
            return true
        }
        if known { setSecret(password, for: .hotspot(serial: serial)) }
    }
    public func rememberNetwork(serial: String, ssid: String, password: String) {
        let known = queue.sync { () -> Bool in
            guard let idx = state.coreBars.firstIndex(where: { $0.serialNo == serial }), !ssid.isEmpty else { return false }
            var n = Set(state.coreBars[idx].savedSSIDs ?? [])
            n.insert(ssid)
            state.coreBars[idx].savedSSIDs = n.sorted()
            persist()
            return true
        }
        if known { setSecret(password, for: .wifi(serial: serial, ssid: ssid)) }
    }
    public func forgetNetwork(serial: String, ssid: String) {
        queue.sync {
            guard let idx = state.coreBars.firstIndex(where: { $0.serialNo == serial }) else { return }
            state.coreBars[idx].savedSSIDs?.removeAll { $0 == ssid }
            persist()
        }
        setSecret(nil, for: .wifi(serial: serial, ssid: ssid))
    }
    public func savedNetworks(serial: String) -> [(ssid: String, password: String)] {
        let ssids = queue.sync { state.coreBars.first { $0.serialNo == serial }?.savedSSIDs ?? [] }
        return ssids.sorted().compactMap { s in secret(.wifi(serial: serial, ssid: s)).map { (s, $0) } }
    }
    public func hotspot(serial: String) -> (ssid: String, password: String)? {
        guard let s = queue.sync(execute: { state.coreBars.first(where: { $0.serialNo == serial })?.hotspotSSID }), !s.isEmpty,
              let p = secret(.hotspot(serial: serial)) else { return nil }
        return (s, p)
    }

    /// Forgets a CoreBar: its entry, its token, data key, hotspot and Wi-Fi passwords, and the per-serial endpoint caches.
    public func remove(serial: String) {
        let ssids = queue.sync { () -> [String] in
            let s = state.coreBars.first { $0.serialNo == serial }?.savedSSIDs ?? []
            state.coreBars.removeAll { $0.serialNo == serial }
            persist()
            return s
        }
        deleteToken(serial: serial)
        setSecret(nil, for: .barKey(serial: serial))
        setSecret(nil, for: .hotspot(serial: serial))
        for s in ssids { setSecret(nil, for: .wifi(serial: serial, ssid: s)) }
        try? FileManager.default.removeItem(at: endpointsURL(serial))
        try? FileManager.default.removeItem(at: knownURL(serial))
    }

    private func persist() {
        // No secrets since 0.5 (they are in the secret store), still user-only: it holds the cert pins.
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

    // MARK: Tokens and other secrets (API keys for the bar apps), in the secret store.

    public func saveToken(_ token: String, serial: String) { setSecret(token, for: .barToken(serial: serial)) }
    public func loadToken(serial: String) -> String? { secret(.barToken(serial: serial)) }
    public func deleteToken(serial: String) { setSecret(nil, for: .barToken(serial: serial)) }

    /// `debounce` for a field bound to a text box (see `setSecret`).
    public func saveSecret(_ value: String, name: String, debounce: Bool = false) {
        setSecret(value, for: Self.account(forSecret: name), debounce: debounce)
    }

    public func loadSecret(name: String) -> String? {
        secret(Self.account(forSecret: name))?.trimmingCharacters(in: .whitespacesAndNewlines)
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
