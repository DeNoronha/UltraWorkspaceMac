import Foundation

/// The pure parts of the Traffic bar app: one `nettop -L 1 -x -n -J bytes_in,bytes_out` sample (macOS's own per-process
/// and per-connection byte counters; no packet capture, no root) → processes and their connections, the bytes since the
/// previous sample, and names for hosts and services.
public enum Traffic {
    public struct Connection: Equatable, Sendable {
        public var proto: String          // tcp4, tcp6, udp4, udp6
        public var localIP: String
        public var localPort: Int?
        public var remoteIP: String
        public var remotePort: Int?
        public var bytesIn: UInt64
        public var bytesOut: UInt64
        public var key: String { "\(proto) \(localIP):\(localPort ?? 0)>\(remoteIP):\(remotePort ?? 0)" }
    }
    public struct Process: Equatable, Sendable {
        public var name: String           // nettop's name, cut at 15 characters
        public var pid: Int
        public var bytesIn: UInt64
        public var bytesOut: UInt64
        public var connections: [Connection]
    }

    /// The CSV nettop prints: a header, then a line per process (`name.pid,in,out,`) followed by its connections
    /// (`tcp4 1.2.3.4:5<->6.7.8.9:443,in,out,`). Listening sockets and connections without a remote are left out.
    public static func parse(_ text: String) -> [Process] {
        var out: [Process] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let cols = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 3, !cols[0].isEmpty else { continue }
            let first = cols[0]
            let bin = UInt64(cols[1]) ?? 0, bout = UInt64(cols[2]) ?? 0
            if let sp = first.firstIndex(of: " "), ["tcp4", "tcp6", "udp4", "udp6"].contains(String(first[..<sp])) {
                guard !out.isEmpty else { continue }
                let proto = String(first[..<sp])
                let ends = first[first.index(after: sp)...].components(separatedBy: "<->")
                guard ends.count == 2, let l = endpoint(ends[0], v6: proto.hasSuffix("6")), let r = endpoint(ends[1], v6: proto.hasSuffix("6")) else { continue }
                guard r.ip != "*", !r.ip.isEmpty else { continue }
                out[out.count - 1].connections.append(Connection(proto: proto, localIP: l.ip, localPort: l.port, remoteIP: r.ip, remotePort: r.port, bytesIn: bin, bytesOut: bout))
            } else if let dot = first.lastIndex(of: "."), let pid = Int(first[first.index(after: dot)...]) {
                out.append(Process(name: String(first[..<dot]), pid: pid, bytesIn: bin, bytesOut: bout, connections: []))
            }
        }
        return out
    }

    /// `1.2.3.4:443`, `*:*`, `fe80::1%en0.49158`, `::1.8021`, `*.*` → address (without the %interface) and port.
    public static func endpoint(_ s: String, v6: Bool) -> (ip: String, port: Int?)? {
        let sep: Character = v6 ? "." : ":"
        guard let i = s.lastIndex(of: sep) else { return nil }
        var ip = String(s[..<i])
        if let pct = ip.firstIndex(of: "%") { ip = String(ip[..<pct]) }
        return (ip, Int(s[s.index(after: i)...]))
    }

    /// Bytes per key since the previous sample. A key that was not there before counts in full (it began since then);
    /// a counter that went down (a reused key) counts from zero.
    public static func delta(_ now: [String: (UInt64, UInt64)], previous: [String: (UInt64, UInt64)]) -> [String: (UInt64, UInt64)] {
        var out: [String: (UInt64, UInt64)] = [:]
        for (k, v) in now {
            let p = previous[k] ?? (0, 0)
            let d = (v.0 >= p.0 ? v.0 - p.0 : v.0, v.1 >= p.1 ? v.1 - p.1 : v.1)
            if d.0 > 0 || d.1 > 0 { out[k] = d }
        }
        return out
    }

    /// The service of a connection: the well-known end (below 49152) of the two ports, its name where macOS or this
    /// list knows one, else the number; "?" for none.
    public static func service(local: Int?, remote: Int?, name: (Int, String) -> String? = { _, _ in nil }, proto: String = "tcp") -> String {
        let candidates = [remote, local].compactMap { $0 }.filter { $0 > 0 && $0 < 49152 }
        guard let port = candidates.min() else { return "?" }
        if let n = known[port] { return n }
        if let n = name(port, proto.hasPrefix("udp") ? "udp" : "tcp") { return n }
        return String(port)
    }
    static let known: [Int: String] = [80: "http", 443: "https", 53: "domain", 22: "ssh", 25: "smtp", 587: "submission", 465: "smtps", 993: "imaps",
                                       143: "imap", 5223: "apple push", 5228: "google push", 123: "ntp", 5353: "mdns", 445: "smb", 548: "afp",
                                       3478: "stun", 8801: "zoom", 8802: "zoom", 3389: "rdp", 5900: "vnc", 1900: "ssdp", 853: "dns over tls",
                                       8080: "http-alt", 8443: "https-alt", 7000: "airplay", 7432: "deckhand", 5555: "adb"]

    /// Local addresses: private, link-local, loopback and unique-local ranges.
    public static func isLocal(_ ip: String) -> Bool {
        let p = ip.lowercased()
        if p.contains(":") { return p == "::1" || p.hasPrefix("fe80") || p.hasPrefix("fc") || p.hasPrefix("fd") }
        let o = p.split(separator: ".").compactMap { Int($0) }
        guard o.count == 4 else { return false }
        return o[0] == 10 || o[0] == 127 || (o[0] == 192 && o[1] == 168) || (o[0] == 172 && (16...31).contains(o[1])) || (o[0] == 169 && o[1] == 254)
            || (o[0] == 100 && (64...127).contains(o[1]))
    }

    /// This Mac talking to itself: 127.0.0.0/8 and ::1.
    public static func isLoopback(_ ip: String) -> Bool { ip.hasPrefix("127.") || ip == "::1" || ip == "localhost" }

    /// A host name → the name people know: the registrable part (`server-1.fra.zoom.us` → `zoom.us`,
    /// `x.bbc.co.uk` → `bbc.co.uk`); `.local` names keep their first label.
    public static func domain(_ host: String) -> String {
        var h = host.lowercased()
        if h.hasSuffix(".") { h.removeLast() }
        let labels = h.split(separator: ".").map(String.init)
        if labels.last == "local" { return labels.first ?? h }
        guard labels.count > 2 else { return h }
        let sld = labels[labels.count - 2], tld = labels[labels.count - 1]
        let keep = tld.count == 2 && ["co", "com", "org", "net", "ac", "gov", "edu", "ne", "or"].contains(sld) ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }

    /// An app's name from its executable path: the outermost `.app` bundle (so Chrome's helpers count as Google Chrome),
    /// else the executable's name.
    public static func appName(path: String) -> String? {
        let parts = path.split(separator: "/")
        if let app = parts.first(where: { $0.hasSuffix(".app") }) { return String(app.dropLast(4)) }
        // A tool installed as …/claude/versions/2.1.322: the folder above the versions, not the version.
        let isVersion: (Substring) -> Bool = { $0.allSatisfy { $0.isNumber || $0 == "." } || $0 == "versions" || $0 == "bin" || $0 == "current" }
        return parts.reversed().first(where: { !isVersion($0) }).map(String.init) ?? parts.last.map(String.init)
    }
}
