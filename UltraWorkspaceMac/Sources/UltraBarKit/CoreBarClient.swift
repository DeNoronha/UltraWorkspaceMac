import Foundation
import Network
import Security
import CryptoKit

/// A single TLS control connection to a CoreBar, speaking line-delimited JSON.
///
/// Certificate handling is trust-on-first-use: the CoreBar uses a self-signed
/// certificate, so at pairing time we record the SHA-256 of the presented
/// certificate and pin it. On later connections a mismatch aborts *before* the
/// token is ever sent.
public actor CoreBarClient {
    private let host: String
    private let port: UInt16
    private let pinnedCertSHA256: String?

    private var connection: NWConnection?
    private var buffer = Data()
    private var lineWaiters: [CheckedContinuation<Data?, Never>] = []
    private var closed = false

    /// SHA-256 (hex) of the certificate the CoreBar presented on this connection.
    public private(set) var presentedCertSHA256: String?
    public private(set) var certMismatch = false

    public init(host: String, pinnedCertSHA256: String? = nil, port: UInt16 = Proto.controlPort) {
        self.host = host
        self.port = port
        self.pinnedCertSHA256 = pinnedCertSHA256
    }

    // MARK: Connection lifecycle

    public func connect() async throws {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, Proto.tlsHost)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)

        let pinned = self.pinnedCertSHA256
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, secTrust, complete in
                let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                let hex = Self.leafCertSHA256(trust)
                Task { await self.recordPresentedCert(hex) }
                guard let hex else { complete(false); return }
                if let pinned, pinned.caseInsensitiveCompare(hex) != .orderedSame {
                    Task { await self.markMismatch() }
                    complete(false)
                    return
                }
                complete(true) // TOFU: accept self-signed, pin captured above.
            },
            DispatchQueue.global(qos: .userInitiated)
        )

        let params = NWParameters(tls: tls)
        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: params
        )
        self.connection = conn

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.stateUpdateHandler = nil
                    cont.resume()
                case .failed(let err):
                    conn.stateUpdateHandler = nil
                    cont.resume(throwing: UltraBarError.tlsFailed(err.localizedDescription))
                case .cancelled:
                    conn.stateUpdateHandler = nil
                    cont.resume(throwing: UltraBarError.notConnected)
                default:
                    break
                }
            }
            conn.start(queue: DispatchQueue.global(qos: .userInitiated))
        }
        if certMismatch, let p = presentedCertSHA256, let pin = pinnedCertSHA256 {
            throw UltraBarError.certPinMismatch(presented: p, pinned: pin)
        }
        startReceiveLoop()
    }

    public func close() {
        closed = true
        connection?.cancel()
        connection = nil
        for w in lineWaiters { w.resume(returning: nil) }
        lineWaiters.removeAll()
    }

    private func recordPresentedCert(_ hex: String?) { presentedCertSHA256 = hex }
    private func markMismatch() { certMismatch = true }

    // MARK: Receiving line-delimited JSON

    private func startReceiveLoop() {
        guard let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                Task { await self.ingest(data) }
            }
            if isComplete || error != nil {
                Task { await self.handleEOF() }
            } else {
                Task { await self.startReceiveLoop() }
            }
        }
    }

    private func ingest(_ data: Data) {
        buffer.append(data)
        drainLines()
    }

    private func handleEOF() {
        closed = true
        for w in lineWaiters { w.resume(returning: nil) }
        lineWaiters.removeAll()
    }

    private var pendingLines: [Data] = []

    private func drainLines() {
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            let trimmed = line.filter { $0 != 0x0D }
            if !trimmed.isEmpty { pendingLines.append(Data(trimmed)) }
        }
        while !lineWaiters.isEmpty, !pendingLines.isEmpty {
            let w = lineWaiters.removeFirst()
            w.resume(returning: pendingLines.removeFirst())
        }
    }

    /// Next JSON line (raw bytes), or nil if the connection closed.
    private func readLine() async -> Data? {
        if !pendingLines.isEmpty { return pendingLines.removeFirst() }
        if closed { return nil }
        return await withCheckedContinuation { cont in
            lineWaiters.append(cont)
        }
    }

    // MARK: Sending

    private func send(_ message: [String: Any]) async throws {
        guard let conn = connection else { throw UltraBarError.notConnected }
        var data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        data.append(0x0A)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: UltraBarError.tlsFailed(err.localizedDescription)) }
                else { cont.resume() }
            })
        }
    }

    // MARK: High-level operations

    /// Pair with the CoreBar. The user must tap Approve on the device within
    /// `approvalWindow`. Returns the token on success.
    public func pair(clientName: String, approvalWindow: TimeInterval) async throws -> String {
        let payload: [String: Any] = [
            "act": Proto.actPair,
            "id": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            "data": [
                "id": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                "clientType": "pc",
                "name": clientName,
            ],
        ]
        try await send(payload)
        let deadline = Date().addingTimeInterval(approvalWindow)
        while Date() < deadline {
            guard let line = await readLineWithTimeout(until: deadline) else { break }
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            let act = intValue(obj["act"])
            guard act == Proto.actPair else { continue }
            if let data = obj["data"] as? [String: Any], let t = data["token"] as? String, !t.isEmpty {
                return t
            }
            if let t = obj["token"] as? String, !t.isEmpty { return t }
            // else: request shown on the CoreBar, keep waiting for approval.
        }
        throw UltraBarError.pairingTimedOut
    }

    /// Authenticate an existing token. Returns true if accepted.
    public func authenticate(token: String) async throws -> Bool {
        let payload: [String: Any] = [
            "act": Proto.actAuth,
            "id": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            "data": token,
        ]
        try await send(payload)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            guard let line = await readLineWithTimeout(until: deadline) else { return false }
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if intValue(obj["act"]) == Proto.actAuth {
                return intValue(obj["code"]) == 200
            }
        }
        return false
    }

    /// Send a request and wait for the reply correlated by `id`. `dataJSON` is
    /// the serialized value for the `data` field (or nil for null). Returns the
    /// raw matched reply line (Sendable `Data`); callers parse it.
    public func request(act: Int, dataJSON: Data?, timeout: TimeInterval) async throws -> Data? {
        let msgId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var payload: [String: Any] = ["act": act, "id": msgId]
        if let dataJSON {
            payload["data"] = try JSONSerialization.jsonObject(with: dataJSON, options: [.fragmentsAllowed])
        } else {
            payload["data"] = NSNull()
        }
        try await send(payload)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let line = await readLineWithTimeout(until: deadline) else { return nil }
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let rid = obj["id"] as? String, rid == msgId { return line }
            // unrelated message; skip
        }
        return nil
    }

    /// Fire a message without waiting for its reply (for push-based flows).
    public func fire(act: Int, dataJSON: Data?) async throws {
        let msgId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var payload: [String: Any] = ["act": act, "id": msgId]
        if let dataJSON {
            payload["data"] = try JSONSerialization.jsonObject(with: dataJSON, options: [.fragmentsAllowed])
        } else {
            payload["data"] = NSNull()
        }
        try await send(payload)
    }

    /// Collect pushed messages with the given `act` for `duration` seconds.
    public func collect(act: Int, duration: TimeInterval) async -> [Data] {
        var out: [Data] = []
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            guard let line = await readLineWithTimeout(until: deadline) else { break }
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               intValue(obj["act"]) == act {
                out.append(line)
            }
        }
        return out
    }

    private func readLineWithTimeout(until deadline: Date) async -> Data? {
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 { return nil }
        return await withTaskGroup(of: Data?.self) { group in
            group.addTask { await self.readLine() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private nonisolated func intValue(_ v: Any?) -> Int {
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String, let i = Int(s) { return i }
        return -1
    }

    // MARK: Certificate helpers

    private nonisolated static func leafCertSHA256(_ trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        let digest = SHA256.hash(data: der)
        return digest.map { String(format: "%02X", $0) }.joined()
    }
}
