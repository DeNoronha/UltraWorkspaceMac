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
        queue.async { [weak self] in self?.handle?.write(data) }
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

    /// Redact any `"token":"…"` value and bare long hex tokens.
    public static func redact(_ s: String) -> String {
        var out = s
        if let re = try? NSRegularExpression(pattern: "(\"token\"\\s*:\\s*\")[^\"]*(\")") {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1<redacted>$2")
        }
        return out
    }
}
