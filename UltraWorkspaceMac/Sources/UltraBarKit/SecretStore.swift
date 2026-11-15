import Foundation
import Security

/// Where Deckhand keeps its secrets: bar pairing tokens, the per-bar data key, API keys, OAuth tokens and Wi-Fi
/// passwords. A Developer-ID-signed build uses the login Keychain (`KeychainSecretStore`); a development build
/// (`swift run`, ad-hoc signed), `kitcheck` and `DECKHAND_FILE_SECRETS=1` use user-only files (`FileSecretStore`), so
/// they never raise Keychain prompts. `DECKHAND_KEYCHAIN=1` forces the Keychain (to read a release's items from a dev
/// build, after one "Always Allow").
public protocol SecretStore: AnyObject, Sendable {
    /// The value, or nil when there is none (or it could not be read).
    func get(_ account: SecretAccount) -> String?
    /// Store `value`; nil or empty deletes the item. Returns errSecSuccess (0) or the failing OSStatus.
    @discardableResult func set(_ value: String?, for account: SecretAccount) -> OSStatus
    /// A short name for the Doctor and the logs ("Keychain", "files").
    var kind: String { get }
}

/// One secret's name. The prefixes keep a bar's serial from ever naming an API key (finding L1): a bar token is
/// always `bar-token:<serial>`, an API key always `api:<name>`.
public enum SecretAccount: Hashable, Sendable, CustomStringConvertible {
    case barToken(serial: String)
    /// The random key the bar apps send with every data request (pushed to them over ADB).
    case barKey(serial: String)
    case hotspot(serial: String)
    case wifi(serial: String, ssid: String)
    case api(String)
    case oauth(String)

    /// `kSecAttrAccount`, and the file name (hex-encoded) of the file fallback.
    public var account: String {
        switch self {
        case .barToken(let s): return "bar-token:\(s)"
        case .barKey(let s): return "bar-key:\(s)"
        case .hotspot(let s): return "bar-hotspot:\(s)"
        case .wifi(let s, let ssid): return "wifi:\(s):\(ssid)"
        case .api(let n): return "api:\(n)"
        case .oauth(let n): return "oauth:\(n)"
        }
    }
    /// What Keychain Access shows. Never contains the value.
    public var label: String {
        switch self {
        case .barToken: return "Deckhand – bar pairing token"
        case .barKey: return "Deckhand – bar apps data key"
        case .hotspot: return "Deckhand – bar hotspot password"
        case .wifi(_, let ssid): return "Deckhand – Wi-Fi password (\(ssid))"
        case .api(let n): return "Deckhand – \(n) API key"
        case .oauth(let n): return "Deckhand – \(n) sign-in"
        }
    }
    public var description: String { account.hasPrefix("wifi:") ? "wifi:<serial>:<ssid>" : account }

    /// Serials Deckhand accepts from discovery and as an account component (L1).
    public static func isValidSerial(_ s: String) -> Bool { s.range(of: "^[A-Za-z0-9]{4,64}$", options: .regularExpression) != nil }
}

public enum SecretStores {
    /// The production service name (the bundle id). Tests pass their own.
    public static let service = "com.denoronha.ultraworkspacemac"

    /// Keychain for a Developer-ID-signed build, files otherwise (see `SecretStore`).
    public static func makeDefault(fileDirectory: URL) -> SecretStore {
        let env = ProcessInfo.processInfo.environment
        if env["DECKHAND_FILE_SECRETS"] == "1" { return FileSecretStore(directory: fileDirectory) }
        if env["DECKHAND_KEYCHAIN"] == "1" || runningCodeHasTeamID() { return KeychainSecretStore(service: service) }
        return FileSecretStore(directory: fileDirectory)
    }

    /// True when the running code is signed with a team identifier (Developer ID), false for ad-hoc or unsigned code.
    public static func runningCodeHasTeamID() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return false }
        return (dict[kSecCodeInfoTeamIdentifier as String] as? String).map { !$0.isEmpty } ?? false
    }
}

/// Generic-password items under one service, `AfterFirstUnlockThisDeviceOnly`, never synchronised.
public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    public let service: String
    public var kind: String { "Keychain" }
    public init(service: String) { self.service = service }

    private func base(_ a: SecretAccount) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: a.account,
         kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
    }

    public func get(_ a: SecretAccount) -> String? { read(a).value }

    /// The value and the OSStatus of the lookup (errSecItemNotFound when there is none).
    public func read(_ a: SecretAccount) -> (value: String?, status: OSStatus) {
        var q = base(a)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        guard st == errSecSuccess, let data = out as? Data else { return (nil, st) }
        return (String(data: data, encoding: .utf8), st)
    }

    @discardableResult
    public func set(_ value: String?, for a: SecretAccount) -> OSStatus {
        guard let value, !value.isEmpty else {
            let st = SecItemDelete(base(a) as CFDictionary)
            return st == errSecItemNotFound ? errSecSuccess : st
        }
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: a.label]
        var st = SecItemUpdate(base(a) as CFDictionary, update as CFDictionary)
        if st == errSecItemNotFound {
            var add = base(a)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = a.label
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            st = SecItemAdd(add as CFDictionary, nil)
        }
        return st
    }
}

/// User-only files, one per account, in `<dir>/secrets/` (0700); the file name is the account in hex, so no serial
/// or SSID can ever name another secret's file (L1). Used by development builds and `kitcheck`.
public final class FileSecretStore: SecretStore, @unchecked Sendable {
    public let directory: URL
    public var kind: String { "files" }
    public init(directory base: URL) { directory = base.appendingPathComponent("secrets", isDirectory: true) }

    public func url(_ a: SecretAccount) -> URL {
        directory.appendingPathComponent(Data(a.account.utf8).map { String(format: "%02x", $0) }.joined() + ".secret")
    }

    public func get(_ a: SecretAccount) -> String? {
        guard let data = try? Data(contentsOf: url(a)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func set(_ value: String?, for a: SecretAccount) -> OSStatus {
        let u = url(a)
        guard let value, !value.isEmpty else {
            if FileManager.default.fileExists(atPath: u.path) { SecretMigration.shred(u) }
            return errSecSuccess
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return Store.writePrivate(Data(value.utf8), to: u) ? errSecSuccess : errSecIO
    }

    /// Every account stored here (for the move from files to the Keychain).
    public func allAccounts() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { n -> String? in
            guard n.hasSuffix(".secret") else { return nil }
            let hex = Array(n.dropLast(7))
            guard hex.count % 2 == 0 else { return nil }
            var bytes: [UInt8] = []
            var i = 0
            while i < hex.count { guard let b = UInt8(String(hex[i..<i + 2]), radix: 16) else { return nil }; bytes.append(b); i += 2 }
            return String(bytes: bytes, encoding: .utf8)
        }
    }
}

/// The one-time move of the secrets out of plain files (`tokens/*.token`, `settings.json` `accuWeatherKey`,
/// `corebars.json` `hotspotPassword`/`savedNetworks`, and in Keychain mode a development build's `secrets/` folder)
/// into `store`. Each value is written, read back and compared before its old copy is zeroed and deleted; a failure
/// keeps the old copy and is reported by account name and OSStatus only. `flagKey` is set in `defaults` only when
/// every item moved.
public enum SecretMigration {
    public struct Report: Sendable {
        public var moved: [String] = []
        public var failed: [(account: String, status: OSStatus)] = []
        public var skipped = false
        public var ok: Bool { failed.isEmpty }
    }

    public static func run(directory base: URL, into store: SecretStore, defaults: UserDefaults, flagKey: String,
                           extraSource: FileSecretStore? = nil) -> Report {
        var report = Report()
        if defaults.bool(forKey: flagKey) { report.skipped = true; return report }
        func move(_ value: String, _ account: SecretAccount) -> Bool {
            let st = store.set(value, for: account)
            guard st == errSecSuccess else { report.failed.append((account.description, st)); return false }
            guard store.get(account) == value else { report.failed.append((account.description, errSecDecode)); return false }
            report.moved.append(account.description)
            return true
        }
        // The paired bars' serials, to map a token file name (letters and digits of the serial) back to its serial.
        let corebarsURL = base.appendingPathComponent("corebars.json")
        let pairedSerials: [String] = {
            guard let data = try? Data(contentsOf: corebarsURL),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let bars = obj["coreBars"] as? [[String: Any]] else { return [] }
            return bars.compactMap { $0["serialNo"] as? String }
        }()
        // 1. tokens/*.token: `secret-<name>` files are API keys/OAuth tokens, every other file a bar's token.
        let tokens = base.appendingPathComponent("tokens", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: tokens.path)) ?? []
        for f in files where f.hasSuffix(".token") {
            let url = tokens.appendingPathComponent(f)
            guard let raw = try? Data(contentsOf: url), let s = String(data: raw, encoding: .utf8) else { continue }
            let stem = String(f.dropLast(6))
            let account: SecretAccount
            let value: String
            if stem.hasPrefix("secret") {
                // The old code stripped punctuation from the file name: `secret-strava-tokens` → `secretstravatokens`.
                let known = ["strava-client-secret", "strava-client-id", "strava-tokens", "schiphol-id", "schiphol-key",
                             "linear", "aisstream", "whiskystats"]
                guard let name = known.first(where: { "secret" + $0.filter { $0.isLetter || $0.isNumber } == stem }) else { continue }
                account = Store.account(forSecret: name)
                value = s.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                // The bar's serial as the old code wrote it (letters and digits only).
                if let serial = pairedSerials.first(where: { $0.filter { $0.isLetter || $0.isNumber } == stem }) {
                    account = .barToken(serial: serial)
                } else {
                    guard SecretAccount.isValidSerial(stem) else { continue }
                    account = .barToken(serial: stem)
                }
                value = s
            }
            if value.isEmpty || move(value, account) { shred(url) }
        }
        if (try? FileManager.default.contentsOfDirectory(atPath: tokens.path))?.isEmpty ?? false {
            try? FileManager.default.removeItem(at: tokens)
        }
        // 2. settings.json: accuWeatherKey.
        let settingsURL = base.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: settingsURL),
           var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let key = obj["accuWeatherKey"] as? String {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || move(trimmed, .api("accuweather")) {
                obj.removeValue(forKey: "accuWeatherKey")
                if let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
                    Store.writePrivate(out, to: settingsURL)
                }
            }
        }
        // 3. corebars.json: hotspotPassword and savedNetworks (ssid → password) per bar.
        if let data = try? Data(contentsOf: corebarsURL),
           var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           var bars = obj["coreBars"] as? [[String: Any]] {
            var changed = false
            for i in bars.indices {
                guard let serial = bars[i]["serialNo"] as? String, !serial.isEmpty else { continue }
                if let pw = bars[i]["hotspotPassword"] as? String {
                    if pw.isEmpty || move(pw, .hotspot(serial: serial)) { bars[i].removeValue(forKey: "hotspotPassword"); changed = true }
                }
                if let nets = bars[i]["savedNetworks"] as? [String: String] {
                    var left: [String: String] = [:]
                    var ssids: [String] = (bars[i]["savedSSIDs"] as? [String]) ?? []
                    for (ssid, pw) in nets {
                        if pw.isEmpty || move(pw, .wifi(serial: serial, ssid: ssid)) { if !ssids.contains(ssid) { ssids.append(ssid) } }
                        else { left[ssid] = pw }
                    }
                    if left.isEmpty { bars[i].removeValue(forKey: "savedNetworks") } else { bars[i]["savedNetworks"] = left }
                    bars[i]["savedSSIDs"] = ssids.sorted()
                    changed = true
                }
            }
            if changed {
                obj["coreBars"] = bars
                if let out = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) { Store.writePrivate(out, to: corebarsURL) }
            }
        }
        // 4. A development build's file store (Keychain mode only).
        if let extra = extraSource, extra !== store {
            for name in extra.allAccounts() {
                guard let a = parse(name), let v = extra.get(a) else { continue }
                if move(v, a) { extra.set(nil, for: a) }
            }
            if (try? FileManager.default.contentsOfDirectory(atPath: extra.directory.path))?.isEmpty ?? false {
                try? FileManager.default.removeItem(at: extra.directory)
            }
        }
        if report.ok { defaults.set(true, forKey: flagKey) }
        return report
    }

    /// `SecretAccount` from its `account` string.
    public static func parse(_ s: String) -> SecretAccount? {
        let p = s.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard p.count >= 2 else { return nil }
        switch p[0] {
        case "bar-token": return .barToken(serial: p[1])
        case "bar-key": return .barKey(serial: p[1])
        case "bar-hotspot": return .hotspot(serial: p[1])
        case "wifi": return p.count == 3 ? .wifi(serial: p[1], ssid: p[2]) : nil
        case "api": return .api(p[1])
        case "oauth": return .oauth(p[1])
        default: return nil
        }
    }

    /// Overwrite with zeros, fsync, unlink. (APFS copy-on-write and snapshots may still hold the old blocks.)
    public static func shred(_ url: URL) {
        let fd = open(url.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd >= 0 {
            var st = stat()
            if fstat(fd, &st) == 0, st.st_size > 0 {
                let zeros = [UInt8](repeating: 0, count: Int(st.st_size))
                _ = zeros.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                fsync(fd)
            }
            close(fd)
        }
        unlink(url.path)
    }
}
