import Foundation
import Network
#if canImport(Darwin)
import Darwin
#endif

/// A tiny HTTP/1.1 file server the CoreBar can *pull* images from.
///
/// Why: `PREVIEW_SCREENSAVER` (30742) on the real firmware loads its `url`
/// with `HttpURLConnection(new URL(url))` — it accepts http(s) URLs only, and
/// the device's own :8080 server does not serve files uploaded via
/// `/upload/zip`. So for a one-shot preview the Mac serves the PNG itself and
/// the device fetches `http://<mac-lan-ip>:<port>/<name>`.
///
/// Serves only what was explicitly `publish`ed (in memory), GET/HEAD only,
/// no directory listing, no filesystem access. Listens on an ephemeral port.
public final class PreviewServer: @unchecked Sendable {
    public static let shared = PreviewServer()

    private let lock = NSLock()
    private var files: [String: (data: Data, type: String)] = [:]
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    public private(set) var port: UInt16 = 0

    private init() {}

    /// Start listening (idempotent). Returns the bound port.
    @discardableResult
    public func start() throws -> UInt16 {
        lock.lock(); defer { lock.unlock() }
        if let l = listener, l.state == .ready { return port }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: .any)
        let ready = DispatchSemaphore(value: 0)
        final class ErrBox: @unchecked Sendable { var err: Error? }
        let errBox = ErrBox()
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = l.port?.rawValue ?? 0
                ready.signal()
            case .failed(let e):
                errBox.err = e; ready.signal()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.start(queue: DispatchQueue(label: "deckhand.previewserver"))
        _ = ready.wait(timeout: .now() + 3)
        if let e = errBox.err { throw UltraBarError.protocolError("preview server: \(e.localizedDescription)") }
        guard port != 0 else { throw UltraBarError.protocolError("preview server: no port") }
        listener = l
        WireLog.shared.event("preview server listening on :\(port)")
        return port
    }

    /// Make `data` available at `/<name>`. Replaces any previous file of that name.
    public func publish(_ data: Data, name: String, contentType: String = "image/png") {
        lock.lock(); files[name] = (data, contentType); lock.unlock()
    }

    public func unpublish(name: String) {
        lock.lock(); files.removeValue(forKey: name); lock.unlock()
    }

    /// Full URL for `name` as seen from `peerIP` (picks the local interface that
    /// routes to that peer, so it works with multiple NICs / VPNs).
    public func url(for name: String, reachableFrom peerIP: String) -> String? {
        guard port != 0, let ip = LocalIP.address(reaching: peerIP) else { return nil }
        let host = ip.contains(":") ? "[\(ip)]" : ip
        return "http://\(host):\(port)/\(name)"
    }

    // MARK: - Request handling

    private func accept(_ conn: NWConnection) {
        lock.lock(); connections[ObjectIdentifier(conn)] = conn; lock.unlock()
        conn.stateUpdateHandler = { [weak self] st in
            if case .failed = st { self?.drop(conn) }
            if case .cancelled = st { self?.drop(conn) }
        }
        conn.start(queue: DispatchQueue.global(qos: .userInitiated))
        readRequest(conn, buffer: Data())
    }

    private func drop(_ conn: NWConnection) {
        lock.lock(); connections.removeValue(forKey: ObjectIdentifier(conn)); lock.unlock()
    }

    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if buf.count > 65536 || error != nil { conn.cancel(); return }
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<range.lowerBound], as: UTF8.self)
                self.respond(conn, requestHead: head)
            } else if complete {
                conn.cancel()
            } else {
                self.readRequest(conn, buffer: buf)
            }
        }
    }

    private func respond(_ conn: NWConnection, requestHead: String) {
        let line = requestHead.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = line.split(separator: " ")
        let method = parts.count > 0 ? String(parts[0]) : ""
        var target = parts.count > 1 ? String(parts[1]) : "/"
        if let q = target.firstIndex(of: "?") { target = String(target[..<q]) }
        let name = String(target.drop(while: { $0 == "/" })).removingPercentEncoding ?? ""

        lock.lock(); let file = files[name]; lock.unlock()
        WireLog.shared.http("preview server ← \(method) \(target) \(file == nil ? "404" : "200 (\(file!.data.count) B)")")

        var response = Data()
        func header(_ status: String, _ type: String, _ length: Int) -> Data {
            Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(length)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        }
        guard method == "GET" || method == "HEAD" else {
            response = header("405 Method Not Allowed", "text/plain", 0)
            send(conn, response); return
        }
        if let file {
            response = header("200 OK", file.type, file.data.count)
            if method == "GET" { response.append(file.data) }
        } else {
            let body = Data("not found".utf8)
            response = header("404 Not Found", "text/plain", body.count)
            if method == "GET" { response.append(body) }
        }
        send(conn, response)
    }

    private func send(_ conn: NWConnection, _ data: Data) {
        conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
    }
}

/// Which local IPv4 address would be used to reach `peer`? Uses a connected
/// UDP socket (nothing is sent) and reads the kernel's choice via getsockname.
public enum LocalIP {
    public static func address(reaching peer: String) -> String? {
        var dst = sockaddr_in()
        dst.sin_family = sa_family_t(AF_INET)
        dst.sin_port = UInt16(9).bigEndian
        guard inet_pton(AF_INET, peer, &dst.sin_addr) == 1 else { return nil }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let rc = withUnsafePointer(to: &dst) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { return nil }
        var local = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let gs = withUnsafeMutablePointer(to: &local) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in getsockname(fd, sa, &len) }
        }
        guard gs == 0 else { return nil }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &local.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
