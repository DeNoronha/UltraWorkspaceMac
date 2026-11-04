import Foundation

/// Logs every protocol message between the Mac and the CoreBar (the decrypted
/// contents of the TLS channel, plus HTTP uploads) to a file and an in-memory
/// ring for the UI. The token is redacted.
public final class WireLog: @unchecked Sendable {
    public static let shared = WireLog()

    public let fileURL: URL
    public var enabled = true

    private let queue = DispatchQueue(label: "ultrabar.wirelog")
    private var handle: FileHandle?
    private let lock = NSLock()
    private var ring: [String] = []
    private let ringCap = 1000

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("UltraWorkspaceMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("wire.log")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        // The decrypted control channel (redacted, but still the bar's config, Wi-Fi SSIDs, page
        // contents): user-only, like the token files.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        handle = try? FileHandle(forWritingTo: fileURL)
        handle?.seekToEndOfFile()
        event("── session started \(Self.ts()) ──")
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
        let line = "\(Self.ts()) \(dir) \(Self.redact(text))"
        lock.lock(); ring.append(line); if ring.count > ringCap { ring.removeFirst(ring.count - ringCap) }; lock.unlock()
        let data = (line + "\n").data(using: .utf8) ?? Data()
        queue.async { [weak self] in self?.handle?.write(data); self?.rotateIfNeeded() }
    }

    public func sent(_ json: String) { log(">>", json) }
    public func received(_ json: String) { log("<<", json) }
    public func event(_ s: String) { log("--", s) }
    public func http(_ s: String) { log("HTTP", s) }

    public func recent() -> [String] { lock.lock(); defer { lock.unlock() }; return ring }

    public func clear() {
        lock.lock(); ring.removeAll(); lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            try? self.handle?.truncate(atOffset: 0)
        }
    }

    private static func ts() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    /// Redact secrets before a line reaches the ring buffer or the file:
    /// - `"token":"…"` values;
    /// - the AUTH frame (act 100), whose `data` IS the pairing token;
    /// - module Wi-Fi config (property 7): `value`/`result` is hex(len+ssid+len+password);
    /// - `"apiKey":"…"` (AccuWeather key sent via act 1010), `"sessionToken":"…"` (a bar app's web UI,
    ///   in APP_LIST replies) and `"password":"…"`.
    /// The act / propertyId tests do not depend on key order or spacing: our own frames are written
    /// with sorted keys, but the bar's replies are not, and `"propertyId":7}` at the end of an object
    /// used to slip through.
    public static func redact(_ s: String) -> String {
        var out = s
        func sub(_ pattern: String, _ template: String) {
            if let re = try? NSRegularExpression(pattern: pattern) {
                out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
            }
        }
        func has(_ pattern: String) -> Bool { out.range(of: pattern, options: .regularExpression) != nil }
        sub("(\"(?:token|apiKey|sessionToken|password)\"\\s*:\\s*\")[^\"]*(\")", "$1<redacted>$2")
        if has("\"act\"\\s*:\\s*100\\s*[,}]") {
            sub("(\"data\"\\s*:\\s*\")[^\"]*(\")", "$1<redacted>$2")
        }
        if has("\"propertyId\"\\s*:\\s*7\\s*[,}]") {
            sub("(\"(?:value|result)\"\\s*:\\s*\")[0-9A-Fa-f]+(\")", "$1<redacted>$2")
        }
        return out
    }

    /// Keep the file bounded: above `maxBytes`, keep only the last `keepBytes`.
    static let maxBytes: UInt64 = 5_000_000
    static let keepBytes: UInt64 = 1_000_000
    private func rotateIfNeeded() {
        guard let h = handle, let size = try? h.seekToEnd(), size > Self.maxBytes else { return }
        try? h.seek(toOffset: size - Self.keepBytes)
        let tail = (try? h.readToEnd()) ?? Data()
        try? h.truncate(atOffset: 0)
        try? h.seek(toOffset: 0)
        h.write(("-- log rotated (\(size) B → \(tail.count) B)\n").data(using: .utf8)!)
        h.write(tail)
    }
}
