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
        public var id: String { serialNo }
    }

    private struct Persisted: Codable { var coreBars: [PairedCoreBar] = [] }
    private var state = Persisted()

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("UltraWorkspaceMac", isDirectory: true)
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

    public func remove(serial: String) {
        queue.sync {
            state.coreBars.removeAll { $0.serialNo == serial }
            persist()
        }
        deleteToken(serial: serial)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: fileURL, options: .atomic)
        }
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
        let url = tokenURL(serial)
        try? Data(token.utf8).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func loadToken(serial: String) -> String? {
        guard let data = try? Data(contentsOf: tokenURL(serial)) else { return nil }
        return String(data: data, encoding: .utf8)
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

    public func saveEndpoints(_ data: Data, serial: String) {
        try? data.write(to: endpointsURL(serial), options: .atomic)
    }

    public func loadEndpoints(serial: String) -> Data? {
        try? Data(contentsOf: endpointsURL(serial))
    }
}
