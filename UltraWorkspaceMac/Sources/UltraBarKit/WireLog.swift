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
        handle = try? FileHandle(forWritingTo: fileURL)
        handle?.seekToEndOfFile()
        event("── session started \(Self.ts()) ──")
    }

    /// `dir` is a short arrow/tag: ">>" sent, "<<" received, "--" event, "HTTP".
    public func log(_ dir: String, _ text: String) {
        guard enabled else { return }
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
    /// - `"apiKey":"…"` (AccuWeather key sent via act 1010).
    public static func redact(_ s: String) -> String {
        var out = s
        func sub(_ pattern: String, _ template: String) {
            if let re = try? NSRegularExpression(pattern: pattern) {
                out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
            }
        }
        sub("(\"token\"\\s*:\\s*\")[^\"]*(\")", "$1<redacted>$2")
        sub("(\"apiKey\"\\s*:\\s*\")[^\"]*(\")", "$1<redacted>$2")
        if out.contains("\"act\":100,") || out.contains("\"act\": 100,") {
            sub("(\"data\"\\s*:\\s*\")[^\"]*(\")", "$1<redacted>$2")
        }
        if out.contains("\"propertyId\":7,") || out.contains("\"propertyId\": 7,") {
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
