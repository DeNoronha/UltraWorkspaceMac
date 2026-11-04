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
    private var lineWaiters: [(id: UUID, cont: CheckedContinuation<Data?, Never>)] = []
    /// The deadline task of each waiter, cancelled as soon as the waiter is resumed (so a link
    /// reading with a 90 s timeout does not pile up a sleeping task per received line).
    private var waiterTimers: [UUID: Task<Void, Never>] = [:]
    private var closed = false

    /// A peer that never sends a newline must not grow `buffer` without bound: above this the
    /// connection is closed (a real reply is a few KB; the biggest known one, APP_LIST, ~50 KB).
    public static let maxLineBytes = 4 * 1024 * 1024

    /// Certificate facts captured *synchronously* inside the TLS verify block
    /// (which runs off the actor), so `connect()` can report a pin mismatch
    /// deterministically instead of racing an actor hop.
    private final class CertBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _presented: String?
        private var _mismatch = false
        var presented: String? { lock.withLock { _presented } }
        var mismatch: Bool { lock.withLock { _mismatch } }
        func record(_ hex: String?) { lock.withLock { _presented = hex } }
        func markMismatch() { lock.withLock { _mismatch = true } }
    }
    private let certBox = CertBox()

    /// Resumes a connect continuation exactly once, from whichever of the
    /// state handler / timeout fires first.
    private final class ConnectOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<Void, Error>?
        private let conn: NWConnection
        init(_ cont: CheckedContinuation<Void, Error>, _ conn: NWConnection) { self.cont = cont; self.conn = conn }
        func finish(_ result: Result<Void, Error>, cancel: Bool = false) {
            lock.lock()
            let c = cont; cont = nil
            lock.unlock()
            guard let c else { return }
            conn.stateUpdateHandler = nil
            if cancel { conn.cancel() }
            c.resume(with: result)
        }
    }

    /// SHA-256 (hex) of the certificate the CoreBar presented on this connection.
    public var presentedCertSHA256: String? { certBox.presented }
    public var certMismatch: Bool { certBox.mismatch }

    /// Upper bound for TCP+TLS setup. Without it a TLS failure can leave
    /// NWConnection in `.waiting` forever (it retries silently).
    public static let connectTimeout: TimeInterval = 10

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
        let box = certBox
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, secTrust, complete in
                let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                let hex = Self.leafCertSHA256(trust)
                box.record(hex)
                guard let hex else { complete(false); return }
                if let pinned, pinned.caseInsensitiveCompare(hex) != .orderedSame {
                    box.markMismatch()
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

        // Resume exactly once: NWConnection can report .waiting (TLS alert,
        // unreachable host) and then sit there retrying, so treat .waiting as
        // failure and back everything with a hard timeout.
        let timeoutSeconds = Self.connectTimeout
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let once = ConnectOnce(cont, conn)
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        once.finish(.success(()))
                    case .failed(let err):
                        once.finish(.failure(UltraBarError.tlsFailed(err.localizedDescription)))
                    case .waiting(let err):
                        once.finish(.failure(UltraBarError.tlsFailed(err.localizedDescription)), cancel: true)
                    case .cancelled:
                        once.finish(.failure(UltraBarError.notConnected))
                    default:
                        break
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                    once.finish(.failure(UltraBarError.tlsFailed("connect timed out after \(Int(timeoutSeconds))s")), cancel: true)
                }
                conn.start(queue: DispatchQueue.global(qos: .userInitiated))
            }
        } catch {
            // A pin mismatch always surfaces as a TLS failure (we refused the
            // handshake); report it as such so callers never send the token.
            if certMismatch, let p = presentedCertSHA256, let pin = pinnedCertSHA256 {
                throw UltraBarError.certPinMismatch(presented: p, pinned: pin)
            }
            throw error
        }
        if certMismatch, let p = presentedCertSHA256, let pin = pinnedCertSHA256 {
            conn.cancel()
            throw UltraBarError.certPinMismatch(presented: p, pinned: pin)
        }
        WireLog.shared.event("connected \(host):\(port) (TLS) cert=\(presentedCertSHA256?.prefix(16) ?? "?")")
        startReceiveLoop()
    }

    public func close() {
        closed = true
        connection?.cancel()
        connection = nil
        let ws = lineWaiters; lineWaiters.removeAll()
        for w in ws { resumeWaiter(w, with: nil) }
    }

    // MARK: Receiving line-delimited JSON

    /// One task per receive callback does ingest → (EOF | next receive) in that order, so chunk N
    /// is always parsed before chunk N+1 and before the EOF that follows it. (Separate tasks for
    /// ingest and EOF could run in either order on the actor, and an EOF that overtook the last
    /// chunk would resume the waiter with nil and drop a complete reply.)
    private func startReceiveLoop() {
        guard let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task {
                if let data, !data.isEmpty { await self.ingest(data) }
                if isComplete || error != nil { await self.handleEOF() } else { await self.startReceiveLoop() }
            }
        }
    }

    private func ingest(_ data: Data) {
        buffer.append(data)
        drainLines()
        if buffer.count > Self.maxLineBytes {
            WireLog.shared.event("line from \(host):\(port) exceeds \(Self.maxLineBytes) B without a newline; closing")
            close()
        }
    }

    private func handleEOF() {
        closed = true
        let ws = lineWaiters; lineWaiters.removeAll()
        for w in ws { resumeWaiter(w, with: nil) }
    }

    private func resumeWaiter(_ w: (id: UUID, cont: CheckedContinuation<Data?, Never>), with value: Data?) {
        waiterTimers.removeValue(forKey: w.id)?.cancel()
        w.cont.resume(returning: value)
    }

    private var pendingLines: [Data] = []

    private func drainLines() {
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            let trimmed = line.filter { $0 != 0x0D }
            if !trimmed.isEmpty {
                pendingLines.append(Data(trimmed))
                WireLog.shared.received(String(bytes: trimmed, encoding: .utf8) ?? "<binary>")
            }
        }
        while !lineWaiters.isEmpty, !pendingLines.isEmpty {
            let w = lineWaiters.removeFirst()
            resumeWaiter(w, with: pendingLines.removeFirst())
        }
    }

    /// Next JSON line (raw bytes), or nil if the connection closed or
    /// `deadline` passed. The waiter is removed on expiry, so a silent peer
    /// never leaves a continuation (or caller) stuck.
    private func readLine(until deadline: Date) async -> Data? {
        if !pendingLines.isEmpty { return pendingLines.removeFirst() }
        if closed { return nil }
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 { return nil }
        let id = UUID()
        return await withCheckedContinuation { cont in
            lineWaiters.append((id, cont))
            waiterTimers[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.expireWaiter(id)
            }
        }
    }

    private func expireWaiter(_ id: UUID) {
        guard let i = lineWaiters.firstIndex(where: { $0.id == id }) else { return }
        let w = lineWaiters.remove(at: i)
        resumeWaiter(w, with: nil)
    }

    // MARK: Sending

    private func send(_ message: [String: Any]) async throws {
        guard let conn = connection else { throw UltraBarError.notConnected }
        var data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        WireLog.shared.sent(String(data: data, encoding: .utf8) ?? "<binary>")
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

    /// Next inbound frame (raw line) or nil on close/timeout. Used by the
    /// persistent link to consume device-initiated pushes.
    public func nextLine(timeout: TimeInterval) async -> Data? {
        await readLine(until: Date().addingTimeInterval(timeout))
    }

    /// Send an arbitrary frame as-is (e.g. a reply to a device push, or the
    /// vendor-style heartbeat `{"act":20,"id":"n"}` without a `data` key).
    public func sendFrame(_ frame: [String: Any]) async throws {
        try await send(frame)
    }

    public var isClosed: Bool { closed }

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
        await readLine(until: deadline)
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
