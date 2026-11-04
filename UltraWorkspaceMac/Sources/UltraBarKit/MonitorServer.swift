import Foundation
import Network
#if canImport(Darwin)
import Darwin
#endif

/// The small HTTP server behind the bar's Monitor app (2026-11-04): a fixed port on every
/// interface, GET/HEAD only, routes answered by a closure. Nothing on disk is ever served.
/// The page is a live view of this Mac (CPU, memory, network, disk) — read-only, LAN-only, and
/// only while the user has the Monitor switched on (see SECURITY.md).
public final class MonitorServer: @unchecked Sendable {
    public static let shared = MonitorServer()
    public static let defaultPort: UInt16 = 7432

    public struct Response: Sendable {
        public var status: String; public var type: String; public var body: Data
        public init(_ status: String = "200 OK", type: String, body: Data) { self.status = status; self.type = type; self.body = body }
        public static func text(_ s: String, type: String = "text/plain; charset=utf-8") -> Response { Response(type: type, body: Data(s.utf8)) }
        public static func html(_ s: String) -> Response { .text(s, type: "text/html; charset=utf-8") }
        public static func json(_ obj: Any) -> Response {
            Response(type: "application/json", body: (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8))
        }
    }
    public typealias Route = @Sendable (_ path: String) -> Response?

    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var route: Route = { _ in nil }
    public private(set) var port: UInt16 = 0
    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return listener?.state == .ready }

    private init() {}

    public func setRoute(_ r: @escaping Route) { lock.lock(); route = r; lock.unlock() }

    /// Start on `port` (idempotent). Throws when the port is taken.
    public func start(port requested: UInt16 = MonitorServer.defaultPort) throws {
        lock.lock(); defer { lock.unlock() }
        if let l = listener, l.state == .ready { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: requested) else { throw UltraBarError.protocolError("monitor: bad port") }
        let l = try NWListener(using: params, on: nwPort)
        let ready = DispatchSemaphore(value: 0)
        final class ErrBox: @unchecked Sendable { var err: Error? }
        let errBox = ErrBox()
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.port = l.port?.rawValue ?? 0; ready.signal()
            case .failed(let e): errBox.err = e; ready.signal()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.start(queue: DispatchQueue(label: "deckhand.monitorserver"))
        _ = ready.wait(timeout: .now() + 3)
        if let e = errBox.err { throw UltraBarError.protocolError("monitor server: \(e.localizedDescription)") }
        guard port != 0 else { throw UltraBarError.protocolError("monitor server: no port") }
        listener = l
        WireLog.shared.event("monitor server listening on :\(port)")
    }

    public func stop() {
        lock.lock()
        listener?.cancel(); listener = nil; port = 0
        let conns = connections.values; connections.removeAll()
        lock.unlock()
        conns.forEach { $0.cancel() }
        WireLog.shared.event("monitor server stopped")
    }

    /// `http://<ip>:<port>/monitor` as seen from `peerIP`.
    public func url(reachableFrom peerIP: String) -> String? {
        guard port != 0, let ip = LocalIP.address(reaching: peerIP) else { return nil }
        return "http://\(ip):\(port)/monitor"
    }

    // MARK: - Requests (same shape as PreviewServer)

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
                self.respond(conn, requestHead: String(decoding: buf[..<range.lowerBound], as: UTF8.self))
            } else if complete { conn.cancel() } else { self.readRequest(conn, buffer: buf) }
        }
    }

    private func respond(_ conn: NWConnection, requestHead: String) {
        let line = requestHead.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = line.split(separator: " ")
        let method = parts.count > 0 ? String(parts[0]) : ""
        var target = parts.count > 1 ? String(parts[1]) : "/"
        if let q = target.firstIndex(of: "?") { target = String(target[..<q]) }
        func header(_ status: String, _ type: String, _ length: Int) -> Data {
            Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(length)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        }
        guard method == "GET" || method == "HEAD" else { send(conn, header("405 Method Not Allowed", "text/plain", 0)); return }
        lock.lock(); let r = route; lock.unlock()
        let resp = r(target.removingPercentEncoding ?? target) ?? Response("404 Not Found", type: "text/plain", body: Data("not found".utf8))
        if !target.hasSuffix(".json") { WireLog.shared.http("monitor ← \(method) \(target) \(resp.status)") }
        var out = header(resp.status, resp.type, resp.body.count)
        if method == "GET" { out.append(resp.body) }
        send(conn, out)
    }

    private func send(_ conn: NWConnection, _ data: Data) {
        conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
    }
}

/// UDP beacon the Monitor app listens for: `{"deckhand":"monitor","url":…,"v":1}` to 255.255.255.255:5320.
public enum MonitorBeacon {
    public static let port: UInt16 = 5320

    /// One beacon: broadcast plus a unicast copy to `host` (the bar's IP) — the bar's Wi-Fi does not pass
    /// 255.255.255.255 broadcasts to it (checked 2026-11-04), the unicast always arrives.
    @discardableResult
    public static func send(url: String, base: String? = nil, to host: String? = nil) -> Bool {
        var obj: [String: Any] = ["deckhand": "monitor", "url": url, "v": base == nil ? 1 : 2]
        if let base { obj["base"] = base }   // v2: each bar app opens base + "/" + its page
        guard let payload = try? JSONSerialization.data(withJSONObject: obj) else { return false }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        func send(to addr: in_addr_t) -> Bool {
            var dst = sockaddr_in()
            dst.sin_family = sa_family_t(AF_INET)
            dst.sin_port = port.bigEndian
            dst.sin_addr.s_addr = addr
            let sent = payload.withUnsafeBytes { buf in
                withUnsafePointer(to: &dst) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        sendto(fd, buf.baseAddress, buf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            return sent == payload.count
        }
        var ok = send(to: INADDR_BROADCAST)
        if let host { var a = in_addr(); if inet_pton(AF_INET, host, &a) == 1 { ok = send(to: a.s_addr) || ok } }
        return ok
    }
}
