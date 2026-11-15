import Foundation

/// The diagnostic log: every protocol message between the Mac and the CoreBar (the decrypted contents of the TLS
/// channel, plus HTTP uploads and events), in `wire.log` and an in-memory ring for the Logs view.
///
/// It is **off by default** (Settings → Privacy, `enabled`, kept in UserDefaults under `enabledKey`): while off nothing
/// is kept at all, neither in memory nor on disk. While on, every line is redacted first (`redact`: tokens, keys,
/// passwords, Wi-Fi blobs; coordinates rounded to one decimal, about 10 km), lines older than 7 days are dropped
/// (`retention`) and the file is held under `maxBytes` (2 MB) by keeping its newest part (`keepBytes`).
public final class WireLog: @unchecked Sendable {
    public static let shared = WireLog()

    /// UserDefaults key of the switch, and of the date it was last turned on.
    public static let enabledKey = "diagnosticLogging"
    public static let enabledSinceKey = "diagnosticLoggingSince"

    public let fileURL: URL
    private let defaults: UserDefaults

    private let queue = DispatchQueue(label: "ultrabar.wirelog")
    private var handle: FileHandle?
    private let lock = NSLock()
    private var ring: [String] = []
    private let ringCap = 1000
    private var isOn = false
    /// The day the file was last pruned to `retention` (pruned again on the first line of a new day).
    private var prunedDay = ""

    /// Whether lines are kept. Turning it on opens the file (and prunes it); turning it off closes it and empties the
    /// in-memory ring. The file itself stays until `clear()`.
    public var enabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return isOn }
        set {
            lock.lock(); let was = isOn; isOn = newValue; if !newValue { ring.removeAll() }; lock.unlock()
            guard was != newValue else { return }
            defaults.set(newValue, forKey: Self.enabledKey)
            if newValue {
                defaults.set(Date(), forKey: Self.enabledSinceKey)
                queue.sync { openFile() }
                event("── diagnostic log turned on \(Self.stamp(Date())) ──")
            } else {
                defaults.removeObject(forKey: Self.enabledSinceKey)
                queue.sync { try? handle?.close(); handle = nil }
            }
        }
    }

    /// When logging was last turned on (nil while off).
    public var enabledSince: Date? { enabled ? defaults.object(forKey: Self.enabledSinceKey) as? Date : nil }

    private convenience init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("UltraWorkspaceMac", isDirectory: true)
        self.init(directory: base, defaults: .standard)
    }

    /// A log in `directory` whose switch lives in `defaults` (the app uses `shared`; checks use a temporary folder).
    public init(directory base: URL, defaults: UserDefaults) {
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("wire.log")
        self.defaults = defaults
        isOn = defaults.bool(forKey: Self.enabledKey)
        if isOn {
            queue.sync { openFile() }
            event("── session started \(Self.stamp(Date())) ──")
        } else if FileManager.default.fileExists(atPath: fileURL.path) {
            // Off, but a file from before: still apply the retention, so it does not hold old lines for ever.
            queue.sync { pruneFile(now: Date()) }
        }
    }

    /// Open (creating it 0600) and prune the file. On `queue`.
    private func openFile() {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        // The decrypted control channel (redacted, but still the bar's config and page contents): user-only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        pruneFile(now: Date())
        // Read-write: rotation reads the tail back (a write-only handle made `readToEnd` fail and emptied the file).
        handle = try? FileHandle(forUpdating: fileURL)
        _ = try? handle?.seekToEnd()
    }

    /// `dir` is a short arrow/tag: ">>" sent, "<<" received, "--" event, "HTTP".
    /// The bar polls the Mac's volume about 24× a minute once a KnobKey is attached (its own timer). Logging
    /// each of those drowns everything else, so volume traffic is counted and written as one line a minute.
    private var volumeGets = 0, volumeSets = 0, volumeFlushAt = Date()

    public func log(_ dir: String, _ text: String) {
        guard enabled else { return }
        if dir == ">>" || dir == "<<", text.contains("_VOLUME") {
            lock.lock()
            if text.contains("SET_VOLUME") { volumeSets += 1 } else { volumeGets += 1 }
            let due = Date().timeIntervalSince(volumeFlushAt) >= 60
            let gets = volumeGets, sets = volumeSets
            if due { volumeGets = 0; volumeSets = 0; volumeFlushAt = Date() }
            lock.unlock()
            if due { log("--", "volume: \(gets / 2) GET_VOLUME answered, \(sets / 2) SET_VOLUME in the last minute (not logged one by one)") }
            return
        }
        let now = Date()
        let line = "\(Self.stamp(now)) \(dir) \(Self.redact(text))"
        lock.lock(); ring.append(line); if ring.count > ringCap { ring.removeFirst(ring.count - ringCap) }; lock.unlock()
        let data = Data((line + "\n").utf8)
        queue.async { [weak self] in
            guard let self, let h = self.handle else { return }
            let day = Self.day(now)
            if day != self.prunedDay {
                // A new day: drop what fell out of the retention window, then carry on at the end.
                try? h.close(); self.handle = nil
                self.pruneFile(now: now)
                self.handle = try? FileHandle(forUpdating: self.fileURL)
                _ = try? self.handle?.seekToEnd()
            }
            self.handle?.write(data)
            self.rotateIfNeeded()
        }
    }

    public func sent(_ json: String) { log(">>", json) }
    public func received(_ json: String) { log("<<", json) }
    public func event(_ s: String) { log("--", s) }
    public func http(_ s: String) { log("HTTP", s) }

    public func recent() -> [String] { lock.lock(); defer { lock.unlock() }; return ring }

    /// Bytes in the file (0 when there is none).
    public var fileSize: Int {
        ((try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Empty the ring and the file (whether logging is on or off).
    public func clear() {
        lock.lock(); ring.removeAll(); lock.unlock()
        queue.sync {
            if let h = handle { try? h.truncate(atOffset: 0); try? h.seek(toOffset: 0) }
            else if FileManager.default.fileExists(atPath: fileURL.path) { try? Data().write(to: fileURL) }
        }
    }

    /// Wait until every queued line is on disk (checks).
    public func flush() { queue.sync { try? handle?.synchronize() } }

    // MARK: Time stamps (formatters are expensive: made once; DateFormatter is thread-safe since macOS 10.9)

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    static func stamp(_ d: Date) -> String { stampFormatter.string(from: d) }
    static func day(_ d: Date) -> String { dayFormatter.string(from: d) }

    // MARK: Retention

    /// Lines older than this are dropped (on launch, when logging is turned on, and on the first line of each day).
    public static let retention: TimeInterval = 7 * 86_400
    /// Above `maxBytes` the file keeps only its newest `keepBytes`, cut at a line boundary.
    public static let maxBytes = 2_000_000
    public static let keepBytes = 1_000_000

    /// `data` (log lines) without the lines older than `retention` before `now`, and without lines that carry no
    /// date (written before dates were logged, so their age is unknown); then capped to `keepBytes` when it is
    /// over `maxBytes`. Pure, for the checks.
    public static func pruned(_ data: Data, now: Date, maxBytes: Int = maxBytes, keepBytes: Int = keepBytes) -> Data {
        let cutoff = day(now.addingTimeInterval(-retention))
        var out = Data(); out.reserveCapacity(data.count)
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard line.count >= 10, let d = String(bytes: line.prefix(10), encoding: .ascii),
                  d.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil, d >= cutoff else { continue }
            out.append(contentsOf: line); out.append(UInt8(ascii: "\n"))
        }
        return capped(out, maxBytes: maxBytes, keepBytes: keepBytes)
    }

    /// The newest `keepBytes` of `data` when it is over `maxBytes`, starting at a line boundary.
    public static func capped(_ data: Data, maxBytes: Int = maxBytes, keepBytes: Int = keepBytes) -> Data {
        guard data.count > maxBytes else { return data }
        var tail = data.suffix(keepBytes)
        if let nl = tail.firstIndex(of: UInt8(ascii: "\n")) { tail = tail[tail.index(after: nl)...] }
        return Data(tail)
    }

    /// Apply `pruned` to the file. On `queue`, with the handle closed or about to be reopened.
    private func pruneFile(now: Date) {
        prunedDay = Self.day(now)
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let kept = Self.pruned(data, now: now)
        if kept.count != data.count { Store.writePrivate(kept, to: fileURL) }
    }

    /// Keep the file bounded: above `maxBytes`, keep only the newest `keepBytes` (whole lines). On `queue`.
    private func rotateIfNeeded() {
        guard let h = handle, let size = try? h.seekToEnd(), size > UInt64(Self.maxBytes) else { return }
        try? h.seek(toOffset: 0)
        let all = (try? h.readToEnd()) ?? Data()
        var kept = Self.capped(all)
        kept.append(Data("\(Self.stamp(Date())) -- log rotated (\(size) B → \(kept.count) B)\n".utf8))
        try? h.truncate(atOffset: 0)
        try? h.seek(toOffset: 0)
        h.write(kept)
    }

    // MARK: Redaction

    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    /// Secret values by key name, as JSON (`"name":"value"`) or as a header/query (`name: value`, `name=value`).
    private static let secretKeys = "token|apiKey|APIKey|api_key|sessionToken|password|passwd|pwd|psk|secret|clientSecret|client_secret|access_token|refresh_token|accessToken|refreshToken|Authorization|authorization|key"
    private static let reJSONSecret = re("(\"(?:\(secretKeys))\"\\s*:\\s*\")[^\"]*(\")")
    private static let reQuerySecret = re("((?:[?&]|\\b)(?:sessionToken|token|key|apiKey|access_token)=)[^&\\s\"]+")
    private static let reAuthHeader = re("((?:Authorization|X-Deckhand-Key)\\s*:\\s*)(?:Bearer\\s+)?[^\\s\",}]+")
    private static let reAuthAct = re("\"act\"\\s*:\\s*100\\s*[,}]")
    private static let reData = re("(\"data\"\\s*:\\s*\")[^\"]*(\")")
    private static let reProp7 = re("\"propertyId\"\\s*:\\s*7\\s*[,}]")
    private static let reProp7Value = re("(\"(?:value|result)\"\\s*:\\s*\")[0-9A-Fa-f]+(\")")
    /// `lat=52.3676`, `"lon":4.90`, `latitude: 52.37`: one decimal is kept (about 10 km).
    private static let reCoordKey = re("((?:\\b|\")(?:lat|lon|lng|latitude|longitude)\"?\\s*[=:]\\s*\"?-?\\d{1,3}\\.\\d)\\d+")
    /// `(52.3676,4.9041)`: a coordinate pair in parentheses.
    private static let reCoordPair = re("\\((-?\\d{1,3}\\.\\d)\\d*\\s*,\\s*(-?\\d{1,3}\\.\\d)\\d*\\)")

    private static func sub(_ s: inout String, _ re: NSRegularExpression, _ template: String) {
        s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
    private static func has(_ s: String, _ re: NSRegularExpression) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Redact secrets before a line reaches the ring buffer or the file:
    /// - values of secret-looking keys (`token`, `apiKey`, `password`, `psk`, `secret`, `access_token`, `key`, …), in
    ///   JSON, in `name=value` query strings and in `Authorization:`/`X-Deckhand-Key:` headers;
    /// - the AUTH frame (act 100), whose `data` IS the pairing token;
    /// - module Wi-Fi config (property 7): `value`/`result` is hex(len+ssid+len+password);
    /// - coordinates, rounded to one decimal.
    /// The act / propertyId tests do not depend on key order or spacing: our own frames are written
    /// with sorted keys, but the bar's replies are not.
    public static func redact(_ s: String) -> String {
        var out = s
        sub(&out, reJSONSecret, "$1<redacted>$2")
        sub(&out, reQuerySecret, "$1<redacted>")
        sub(&out, reAuthHeader, "$1<redacted>")
        if has(out, reAuthAct) { sub(&out, reData, "$1<redacted>$2") }
        if has(out, reProp7) { sub(&out, reProp7Value, "$1<redacted>$2") }
        sub(&out, reCoordKey, "$1")
        sub(&out, reCoordPair, "($1,$2)")
        return out
    }

    /// An SSID as the logs show it: the first two characters and the length ("Ho…(9)").
    public static func maskSSID(_ ssid: String) -> String {
        ssid.count <= 2 ? "…(\(ssid.count))" : "\(ssid.prefix(2))…(\(ssid.count))"
    }

    private static let reIPv4 = re("\\b(\\d{1,3})\\.(\\d{1,3})\\.\\d{1,3}\\.\\d{1,3}\\b")
    private static let reCoordNumber = re("((?:\\b|\")(?:lat|lon|lng|latitude|longitude)\"?\\s*[=:]\\s*\"?)-?\\d{1,3}(?:\\.\\d+)?")
    private static let rePlace = re("((?:location|weather|geolocation)\\b[^\\n]*?(?:→|@)\\s*)[^\\n(]+")
    private static let reSSID = re("(\"(?:ssid|SSID)\"\\s*:\\s*\")[^\"]*(\")")

    /// A text meant to be pasted somewhere public (the Status page's Copy report): `redact`, then IPv4 addresses
    /// to their first two parts (`192.168.x.x`), each of `serials` to its last four characters, coordinates and
    /// place names dropped, SSIDs in JSON masked.
    public static func forReport(_ s: String, serials: [String]) -> String {
        var out = redact(s)
        for serial in serials where serial.count > 4 {
            out = out.replacingOccurrences(of: serial, with: "…" + serial.suffix(4))
        }
        sub(&out, reIPv4, "$1.$2.x.x")
        sub(&out, reCoordNumber, "$1?")
        sub(&out, reCoordPair, "(?)")
        sub(&out, rePlace, "$1<place>")
        sub(&out, reSSID, "$1<ssid>$2")
        return out
    }
}
