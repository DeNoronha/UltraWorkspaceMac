import Foundation
import Security

/// Persists pairing tokens (Keychain) and per-CoreBar metadata (cert pin, last
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

    // MARK: Tokens (Keychain)

    public func saveToken(_ token: String, serial: String) {
        let acct = serial
        let data = Data(token.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acct,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    public func loadToken(serial: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serial,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func deleteToken(serial: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serial,
        ]
        SecItemDelete(base as CFDictionary)
    }
}
