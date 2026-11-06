import Foundation
import Network
#if canImport(Darwin)
import Darwin
#endif

/// The small HTTP server behind the bar apps' data API: a fixed port on every interface, GET/HEAD for data, POST
/// with a marker header for the few actions, routes answered by closures. It serves JSON and images only, never a
/// page and never anything on disk, and answers only the allowed peers (the selected bar) and loopback (see SECURITY.md).
public final class MonitorServer: @unchecked Sendable {
    public static let shared = MonitorServer()
    public static let defaultPort: UInt16 = 7432

    public struct Response: Sendable {
        public var status: String; public var type: String; public var body: Data
        public init(_ status: String = "200 OK", type: String, body: Data) { self.status = status; self.type = type; self.body = body }
        public static func text(_ s: String, type: String = "text/plain; charset=utf-8") -> Response { Response(type: type, body: Data(s.utf8)) }
        public static func json(_ obj: Any) -> Response {
            Response(type: "application/json", body: (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8))
        }
    }
    public typealias Route = @Sendable (_ path: String) -> Response?
    /// Routes that change something (play/next, mark a task done): called only for a POST that carries the
    /// `X-Deckhand: action` header, which a cross-site <img> or form cannot send; the bar apps set it.
    public typealias ActionRoute = @Sendable (_ path: String) -> Response?

    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var route: Route = { _ in nil }
    private var actionRoute: ActionRoute = { _ in nil }
    /// Addresses that are answered at all (the paired bar); loopback always is. The data carries calendar titles,
    /// Claude transcripts and what is playing, which not every LAN should be able to read. Empty: loopback only.
    private var allowedPeers: Set<String> = []
    public private(set) var port: UInt16 = 0
    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return listener?.state == .ready }

    /// A connection that has not been answered after this long is closed: a client that opens a
    /// socket and never finishes its request head (or trickles it) must not hold a connection for ever.
    nonisolated(unsafe) public static var requestTimeout: TimeInterval = 15

    private init() {}

    public func setRoute(_ r: @escaping Route) { lock.lock(); route = r; lock.unlock() }
    public func setActionRoute(_ r: @escaping ActionRoute) { lock.lock(); actionRoute = r; lock.unlock() }
    /// Only these peer addresses (plus loopback) get an answer; everyone else gets 403. The app sets it to the
    /// selected bar's address, so another host on the LAN can neither read the data nor drive Music or close issues.
    public func setAllowedPeers(_ peers: Set<String>) { lock.lock(); allowedPeers = peers; lock.unlock() }

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

    /// `http://<ip>:<port>` as seen from `peerIP`.
    public func baseURL(reachableFrom peerIP: String) -> String? {
        guard port != 0, let ip = LocalIP.address(reaching: peerIP) else { return nil }
        return "http://\(ip):\(port)"
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
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.requestTimeout) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let open = self.connections[ObjectIdentifier(conn)] != nil; self.lock.unlock()
            if open { conn.cancel() }
        }
    }

    private func drop(_ conn: NWConnection) {
        lock.lock(); connections.removeValue(forKey: ObjectIdentifier(conn)); lock.unlock()
    }

    /// The request line, whatever the line ending; `target` with control characters removed (it is
    /// logged, and a log line must not be forged by a request).
    static func requestLine(_ head: String) -> (method: String, target: String) {
        let line = head.split(whereSeparator: { $0 == "\r\n" || $0 == "\n" || $0 == "\r" }).first.map(String.init) ?? ""
        let parts = line.split(separator: " ")
        let method = parts.count > 0 ? String(parts[0]) : ""
        var target = parts.count > 1 ? String(parts[1]) : "/"
        if let q = target.firstIndex(of: "?") { target = String(target[..<q]) }
        target = String(target.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F })
        return (method, target)
    }

    /// The first header called `name` (case-insensitive), trimmed; nil when absent.
    public static func header(_ name: String, in head: String) -> String? {
        let want = name.lowercased() + ":"
        for line in head.split(whereSeparator: { $0 == "\r\n" || $0 == "\n" || $0 == "\r" }).dropFirst() {
            guard line.lowercased().hasPrefix(want) else { continue }
            return line.dropFirst(want.count).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// An action is a POST whose `X-Deckhand` header is exactly `action` (a header, not the string anywhere in the head).
    public static func hasActionMarker(_ head: String) -> Bool { header("x-deckhand", in: head)?.lowercased() == "action" }

    /// Whether the request's `Host` is acceptable: an IPv4/IPv6 literal (optionally with a port), `localhost`, or no
    /// Host at all (HTTP/1.0). A DNS name is refused: the data has no login, so a web page the user visits could
    /// otherwise point a name it controls at this Mac's address (DNS rebinding) and read it from the browser,
    /// same-origin, including the headers an action needs. The bar always uses the IP.
    public static func hostIsAllowed(_ head: String) -> Bool {
        guard var host = header("host", in: head) else { return true }
        host = host.lowercased()
        if host.hasPrefix("[") {                       // [v6]:port
            guard let close = host.firstIndex(of: "]") else { return false }
            host = String(host[host.index(after: host.startIndex)..<close])
        } else if let colon = host.lastIndex(of: ":"), host[host.startIndex..<colon].contains(":") == false {
            host = String(host[..<colon])                // v4:port or name:port
        }
        if host.isEmpty { return false }
        if host == "localhost" { return true }
        if let pct = host.firstIndex(of: "%") { host = String(host[..<pct]) }   // v6 zone id
        var a4 = in_addr(), a6 = in6_addr()
        return inet_pton(AF_INET, host, &a4) == 1 || inet_pton(AF_INET6, host, &a6) == 1
    }

    /// The peer's address as a string, or nil when it is not an IP endpoint.
    static func peerAddress(_ conn: NWConnection) -> String? {
        guard case let .hostPort(host, _) = conn.endpoint else { return nil }
        switch host {
        case .ipv4(let a): return "\(a)"
        case .ipv6(let a): return "\(a)".split(separator: "%").first.map(String.init)
        case .name(let n, _): return n
        @unknown default: return nil
        }
    }

    /// Loopback (any form) or one of the listed peers (also IPv4-mapped).
    public static func peerIsAllowed(_ address: String?, peers: Set<String>) -> Bool {
        guard let address else { return false }
        if address.hasPrefix("127.") || address == "::1" || address.hasPrefix("::ffff:127.") { return true }
        return peers.contains(address) || (address.hasPrefix("::ffff:") && peers.contains(String(address.dropFirst(7))))
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

    /// Response head: no caching, no sniffing, no referrer, no framing.
    static func responseHead(_ status: String, _ type: String, _ length: Int) -> Data {
        var h = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(length)\r\nCache-Control: no-store\r\n"
        h += "X-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nX-Frame-Options: DENY\r\n"
        return Data((h + "Connection: close\r\n\r\n").utf8)
    }

    private func respond(_ conn: NWConnection, requestHead: String) {
        let (method, target) = Self.requestLine(requestHead)
        let header = Self.responseHead
        guard Self.hostIsAllowed(requestHead) else {
            WireLog.shared.http("monitor ← \(method) \(target) 421 (Host is not an address)")
            send(conn, header("421 Misdirected Request", "text/plain", 0)); return
        }
        guard method == "POST" || method == "GET" || method == "HEAD" else { send(conn, header("405 Method Not Allowed", "text/plain", 0)); return }
        let path = target.removingPercentEncoding ?? target
        let notFound = Response("404 Not Found", type: "text/plain", body: Data("not found".utf8))
        lock.lock(); let r = route, a = actionRoute, peers = allowedPeers; lock.unlock()
        let resp: Response
        if !Self.peerIsAllowed(Self.peerAddress(conn), peers: peers) {
            resp = Response("403 Forbidden", type: "text/plain", body: Data("answered for the paired bar only".utf8))
        } else if method == "POST" {
            // Actions: POST + a custom header, so a page on another origin cannot trigger them (no CORS preflight passes).
            resp = Self.hasActionMarker(requestHead) ? (a(path) ?? notFound)
                : Response("403 Forbidden", type: "text/plain", body: Data("actions need the X-Deckhand header".utf8))
        } else {
            resp = r(path) ?? notFound
        }
        if !target.hasSuffix(".json") { WireLog.shared.http("monitor ← \(method) \(target) \(resp.status)") }
        var out = header(resp.status, resp.type, resp.body.count)
        if method != "HEAD" { out.append(resp.body) }   // a POST reply carried a Content-Length but no body before 2026-11-04
        send(conn, out)
    }

    private func send(_ conn: NWConnection, _ data: Data) {
        conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
    }
}

/// UDP beacon the bar apps listen for: `{"deckhand":"monitor","v":2,"base":"http://<mac>:7432","url":"<base>/monitor"}`
/// to 255.255.255.255:5320. The apps use `base`; `url` is the v1 field, kept so the wire format stays as documented.
public enum MonitorBeacon {
    public static let port: UInt16 = 5320

    /// One beacon: broadcast plus a unicast copy to `host` (the bar's IP) — the bar's Wi-Fi does not pass
    /// 255.255.255.255 broadcasts to it (checked 2026-11-04), the unicast always arrives.
    @discardableResult
    public static func send(base: String, to host: String? = nil) -> Bool {
        let obj: [String: Any] = ["deckhand": "monitor", "v": 2, "base": base, "url": base + "/monitor"]
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
