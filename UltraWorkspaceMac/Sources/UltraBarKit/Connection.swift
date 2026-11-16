import Foundation

/// The pure parts of the Connection bar app: ping and traceroute output, the ASUS router's answers, and the verdict on
/// the path Mac → Wi-Fi → router → ISP → internet → services (which hop is the likely culprit).
public enum Connection {

    // MARK: ping and traceroute

    public struct Ping: Equatable, Sendable {
        public var sent: Int
        public var received: Int
        public var avg: Double?
        public var max: Double?
        /// ping's stddev: the jitter.
        public var jitter: Double?
        public var loss: Double { sent > 0 ? Double(sent - received) / Double(sent) : 1 }
        public init(sent: Int, received: Int, avg: Double?, max: Double?, jitter: Double?) {
            self.sent = sent; self.received = received; self.avg = avg; self.max = max; self.jitter = jitter
        }
    }

    /// `ping -q` summary: "10 packets transmitted, 9 packets received, 10.0% packet loss" and
    /// "round-trip min/avg/max/stddev = 5.677/6.394/6.953/0.534 ms".
    public static func ping(_ out: String) -> Ping? {
        var sent: Int?, recv: Int?, avg: Double?, mx: Double?, sd: Double?
        for line in out.split(whereSeparator: \.isNewline) {
            let l = String(line)
            if l.contains("packets transmitted") {
                let nums = l.split(whereSeparator: { !$0.isNumber && $0 != "." }).compactMap { Double($0) }
                if nums.count >= 2 { sent = Int(nums[0]); recv = Int(nums[1]) }
            } else if l.contains("min/avg/max"), let eq = l.firstIndex(of: "=") {
                let v = l[l.index(after: eq)...].trimmingCharacters(in: .whitespaces).split(separator: " ").first?.split(separator: "/").compactMap { Double($0) } ?? []
                if v.count >= 4 { avg = v[1]; mx = v[2]; sd = v[3] }
            }
        }
        guard let s = sent, let r = recv else { return nil }
        return Ping(sent: s, received: r, avg: avg, max: mx, jitter: sd)
    }

    /// `traceroute -n -q 1` → the address of each hop (nil for "*").
    public static func traceroute(_ out: String) -> [String?] {
        out.split(whereSeparator: \.isNewline).compactMap { line -> String?? in
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 2, Int(f[0]) != nil else { return nil }
            return f[1] == "*" ? .some(nil) : .some(String(f[1]))
        }
    }

    /// The ISP's first router: the first public address after the home network (private and carrier-grade NAT
    /// addresses are skipped).
    public static func ispHop(_ hops: [String?]) -> String? {
        hops.compactMap { $0 }.first { !isPrivate($0) }
    }

    public static func isPrivate(_ ip: String) -> Bool {
        let o = ip.split(separator: ".").compactMap { Int($0) }
        guard o.count == 4 else { return ip.lowercased().hasPrefix("fe80") || ip.lowercased().hasPrefix("fd") }
        return o[0] == 10 || o[0] == 127 || (o[0] == 192 && o[1] == 168) || (o[0] == 172 && (16...31).contains(o[1]))
            || (o[0] == 100 && (64...127).contains(o[1])) || (o[0] == 169 && o[1] == 254)
    }

    // MARK: the verdict

    public enum Level: Int, Comparable, Sendable {
        case ok = 0, warn = 1, bad = 2, unknown = -1
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
        public var name: String { switch self { case .ok: "ok"; case .warn: "warn"; case .bad: "bad"; case .unknown: "unknown" } }
    }

    public struct WiFi: Equatable, Sendable {
        public var rssi: Int
        public var noise: Int
        public var rate: Double
        public init(rssi: Int, noise: Int, rate: Double) { self.rssi = rssi; self.noise = noise; self.rate = rate }
        public var snr: Int { rssi - noise }
    }

    public static func level(_ w: WiFi?) -> Level {
        guard let w else { return .unknown }
        if w.rssi < -77 || w.snr < 15 { return .bad }
        if w.rssi < -67 || w.snr < 25 { return .warn }
        return .ok
    }

    /// A ping against limits for latency (ms), jitter (ms) and loss (fraction).
    public static func level(_ p: Ping?, warnMs: Double, badMs: Double, warnJitter: Double) -> Level {
        guard let p else { return .unknown }
        if p.received == 0 || p.loss >= 0.1 { return .bad }
        if let a = p.avg, a >= badMs { return .bad }
        if p.loss > 0 { return .warn }
        if let a = p.avg, a >= warnMs { return .warn }
        if let j = p.jitter, j >= warnJitter { return .warn }
        return .ok
    }
    public static func gatewayLevel(_ p: Ping?) -> Level { level(p, warnMs: 15, badMs: 60, warnJitter: 15) }
    public static func internetLevel(_ p: Ping?) -> Level { level(p, warnMs: 60, badMs: 150, warnJitter: 20) }

    public struct Service: Equatable, Sendable {
        public var name: String
        /// Time to an answer over HTTPS (connection, TLS and the first byte), nil when it failed.
        public var ms: Double?
        public init(name: String, ms: Double?) { self.name = name; self.ms = ms }
        public var level: Level { guard let ms else { return .bad }; return ms >= 1500 ? .bad : ms >= 600 ? .warn : .ok }
    }

    public enum Sky: String, Sendable { case clear, cloudy, stormy, unknown }

    public struct Verdict: Equatable, Sendable {
        public var sky: Sky
        /// The hop to look at: "wifi", "router", "isp", "service" or "" when all is well.
        public var culprit: String
        public var headline: String
        public var detail: String
    }

    /// Which hop is the likely culprit. The first hop that is bad (or, when none is, the first that is shaky) wins,
    /// because a problem near the Mac shows up again at every hop after it.
    public static func verdict(wifi: WiFi?, wired: Bool, gateway: Ping?, internet: Ping?, services: [Service], routerWanDown: Bool = false) -> Verdict {
        let w = wired ? Level.ok : level(wifi), g = gatewayLevel(gateway), i = internetLevel(internet)
        let slow = services.filter { $0.level != .ok }
        let s: Level = services.isEmpty ? .unknown : slow.isEmpty ? .ok : slow.contains { $0.level == .bad } && slow.count == services.count ? .bad : .warn
        if gateway == nil && internet == nil { return Verdict(sky: .unknown, culprit: "", headline: "Measuring…", detail: "") }
        func ms(_ p: Ping?) -> String { p?.avg.map { "\(Int($0.rounded())) ms" } ?? "no answer" }
        func loss(_ p: Ping?) -> String { p.map { "\(Int(($0.loss * 100).rounded()))% lost" } ?? "" }
        // Bad first, nearest hop first.
        if w == .bad, let wf = wifi { return Verdict(sky: .stormy, culprit: "wifi", headline: "Weak Wi-Fi", detail: "Signal \(wf.rssi) dBm. Move closer to a ZenWiFi node or check what is in between.") }
        if g == .bad { return Verdict(sky: .stormy, culprit: wired ? "router" : "wifi", headline: wired ? "Home network trouble" : "Wi-Fi trouble",
                                      detail: "The router: \(ms(gateway)), \(loss(gateway)). The problem is inside your home.") }
        if routerWanDown { return Verdict(sky: .stormy, culprit: "isp", headline: "Internet is down", detail: "The router has no internet connection. The problem is at your provider or the modem.") }
        if i == .bad { return Verdict(sky: .stormy, culprit: "isp", headline: "Provider trouble", detail: "Your home network is fine; the internet: \(ms(internet)), \(loss(internet)).") }
        if s == .bad { return Verdict(sky: .stormy, culprit: "service", headline: "Services not answering", detail: "Your connection is fine, but \(slow.map(\.name).joined(separator: ", ")) do not answer.") }
        if w == .warn, let wf = wifi { return Verdict(sky: .cloudy, culprit: "wifi", headline: "Wi-Fi could be better", detail: "Signal \(wf.rssi) dBm, \(wf.snr) dB above the noise.") }
        if g == .warn { return Verdict(sky: .cloudy, culprit: wired ? "router" : "wifi", headline: wired ? "Home network a bit slow" : "Wi-Fi a bit shaky",
                                       detail: "The router: \(ms(gateway)), jitter \(Int((gateway?.jitter ?? 0).rounded())) ms, \(loss(gateway)).") }
        if i == .warn { return Verdict(sky: .cloudy, culprit: "isp", headline: "Internet a bit slow", detail: "The internet: \(ms(internet)), jitter \(Int((internet?.jitter ?? 0).rounded())) ms, \(loss(internet)).") }
        if s == .warn { return Verdict(sky: .cloudy, culprit: "service", headline: "\(slow.first!.name) is slow", detail: "Your connection is fine; \(slow.map(\.name).joined(separator: ", ")) answer slowly.") }
        return Verdict(sky: .clear, culprit: "", headline: "Clear skies", detail: "Everything looks good: \(ms(internet)) to the internet.")
    }

    // MARK: ASUS

    public struct Node: Equatable, Sendable {
        public var name: String
        public var model: String
        public var ip: String
        public var online: Bool
        public var clients: Int
        public init(name: String, model: String, ip: String, online: Bool, clients: Int) {
            self.name = name; self.model = model; self.ip = ip; self.online = online; self.clients = clients
        }
    }

    public struct Router: Equatable, Sendable {
        public var model: String
        public var firmware: String
        public var wanUp: Bool?
        public var cpu: Double?
        public var memory: Double?
        public var wired: Int
        public var wireless: Int
        public var nodes: [Node]
    }

    /// `appGet.cgi` answers with JSON keyed by hook. Some firmware puts a trailing comma or plain JavaScript in it;
    /// those parts are ignored.
    public static func asusJSON(_ text: String) -> [String: Any] {
        if let j = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] { return j }
        let cleaned = keylessObjectsAsLists(text).replacingOccurrences(of: ",\\s*([}\\]])", with: "$1", options: .regularExpression)
        return (try? JSONSerialization.jsonObject(with: Data(cleaned.utf8))) as? [String: Any] ?? [:]
    }

    /// Newer firmware writes some hooks as an object of objects without keys (`"cpu_usage":{{"cpu0":{…}},{…}}`);
    /// such an object is read as the list it means. Strings are skipped, so braces inside names do not count.
    static func keylessObjectsAsLists(_ text: String) -> String {
        let c = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView(), stack: [Bool] = []      // true = an object rewritten as a list
        var i = 0, inString = false
        while i < c.count {
            let ch = c[i]
            if inString {
                out.append(ch)
                if ch == "\\", i + 1 < c.count { out.append(c[i + 1]); i += 2; continue }
                if ch == "\"" { inString = false }
            } else if ch == "\"" { inString = true; out.append(ch)
            } else if ch == "{" {
                var k = i + 1
                while k < c.count, c[k].properties.isWhitespace { k += 1 }
                let keyless = k < c.count && c[k] == "{"
                stack.append(keyless); out.append(keyless ? "[" : "{")
            } else if ch == "}" {
                out.append((stack.popLast() ?? false) ? "]" : "}")
            } else { out.append(ch) }
            i += 1
        }
        return String(out)
    }

    /// An object, or a list of objects merged into one.
    static func merged(_ v: Any?) -> [String: Any]? {
        if let d = v as? [String: Any] { return d }
        guard let l = v as? [[String: Any]] else { return nil }
        return l.reduce(into: [:]) { $0.merge($1) { a, _ in a } }
    }

    public static func router(_ j: [String: Any]) -> Router {
        func s(_ k: String) -> String { (j[k] as? String) ?? ((j[k] as? NSNumber)?.stringValue ?? "") }
        let fw = [s("firmver"), s("buildno"), s("extendno")].filter { !$0.isEmpty }
        var firmware = fw.count >= 2 ? "\(fw[0]).\(fw[1])" : fw.first ?? ""
        if fw.count == 3 { firmware += "_\(fw[2])" }
        // CPU: cpuN_total / cpuN_usage counters are since boot; their ratio is the load since boot, close enough on a
        // router that runs for weeks. Memory: used / total.
        var cpu: Double?
        // Older firmware: { "cpu1_total": …, "cpu1_usage": … }; newer: { "cpu0": { "total": …, "usage": … }, … }.
        if let c = merged(j["cpu_usage"]) {
            var used = 0.0, total = 0.0
            func add(_ k: String, _ v: Any) {
                if let d = v as? [String: Any] { for (k2, v2) in d { add(k2, v2) }; return }
                let n = Double((v as? String) ?? "") ?? (v as? NSNumber)?.doubleValue ?? 0
                if k == "total" || k.hasSuffix("_total") { total += n } else if k == "usage" || k.hasSuffix("_usage") { used += n }
            }
            for (k, v) in c { add(k, v) }
            if total > 0 { cpu = used / total * 100 }
        }
        var mem: Double?
        if let m = j["memory_usage"] {
            // Keys and nesting differ per firmware (mem_total / total, nested or flat, "123456 kB"): find them by name.
            var flat: [String: Double] = [:]
            func walk(_ v: Any, _ key: String) {
                if let d = v as? [String: Any] { for (k, x) in d { walk(x, k.lowercased()) }; return }
                if let l = v as? [Any] { for x in l { walk(x, key) }; return }
                let str = (v as? String) ?? (v as? NSNumber)?.stringValue ?? ""
                if let num = Double(str.prefix { $0.isNumber || $0 == "." }) { flat[key] = num }
            }
            walk(m, "")
            func n(_ name: String) -> Double { flat.first { $0.key.hasSuffix(name) }?.value ?? 0 }
            let t = n("total"), u = n("used") > 0 ? n("used") : max(0, t - n("free"))
            if t > 0 { mem = u / t * 100 }
        }
        // Clients: get_clientlist is { "maclist": [...], "<MAC>": { "isWL": "0" wired / "1".."3" a Wi-Fi band, "isOnline": "1" } }.
        var wired = 0, wireless = 0
        var perNode: [String: Int] = [:]
        if let cl = j["get_clientlist"] as? [String: Any] {
            for (k, v) in cl where k != "maclist" && k != "ClientAPILevel" {
                guard let c = v as? [String: Any], (c["isOnline"] as? String ?? "1") == "1" else { continue }
                if (c["isWL"] as? String ?? "0") == "0" { wired += 1 } else { wireless += 1 }
                if let node = c["amesh_papMac"] as? String, !node.isEmpty { perNode[node.uppercased(), default: 0] += 1 }
            }
        }
        // AiMesh nodes: get_cfg_clientlist is a list of { alias, model_name, ip, mac, online }.
        let nodes = ((j["get_cfg_clientlist"] as? [[String: Any]]) ?? []).map { n -> Node in
            let mac = ((n["mac"] as? String) ?? "").uppercased()
            let alias = ((n["alias"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            let model = ((n["ui_model_name"] as? String) ?? (n["model_name"] as? String) ?? "")
            return Node(name: alias.isEmpty ? (model.isEmpty ? mac : model) : alias, model: model, ip: (n["ip"] as? String) ?? "",
                        online: ((n["online"] as? String) ?? (n["online"] as? NSNumber)?.stringValue ?? "1") == "1", clients: perNode[mac] ?? 0)
        }
        let wan = s("wan0_state_t")
        return Router(model: s("productid"), firmware: firmware, wanUp: wan.isEmpty ? nil : wan == "2", cpu: cpu, memory: mem,
                      wired: wired, wireless: wireless, nodes: nodes)
    }

    /// The hooks Deckhand asks the router for, in one request.
    public static let asusHooks = "nvram_get(productid);nvram_get(firmver);nvram_get(buildno);nvram_get(extendno);nvram_get(wan0_state_t);cpu_usage(appobj);memory_usage(appobj);get_clientlist();get_cfg_clientlist()"

    /// The router's web address from what someone typed: `192.168.50.1`, `192.168.50.1:8443`, `https://router.asus.com:8443/index.asp`.
    /// HTTPS when the text says so, the port is 8443 or `https` is on (then 8443 unless a port is given); empty → `fallback`
    /// (the gateway). Only a host name or address and a port are accepted, nothing else ends up in the URL.
    public static func routerBase(_ typed: String, fallback: String?, https: Bool) -> String? {
        var a = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        var secure = https
        if let r = a.range(of: "^[A-Za-z]+://", options: .regularExpression) {
            let scheme = a[r].lowercased()
            guard scheme == "http://" || scheme == "https://" else { return nil }
            if scheme == "https://" { secure = true }
            a.removeSubrange(r)
        }
        if let slash = a.firstIndex(of: "/") { a = String(a[..<slash]) }
        if a.isEmpty { a = fallback ?? "" }
        var port: Int?
        if let colon = a.lastIndex(of: ":") {
            guard let p = Int(a[a.index(after: colon)...]), (1...65535).contains(p) else { return nil }
            port = p; a = String(a[..<colon])
        }
        guard !a.isEmpty, a.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil else { return nil }
        if port == 8443 { secure = true }
        if secure { return "https://\(a):\(port ?? 8443)" }
        return port.map { "http://\(a):\($0)" } ?? "http://\(a)"
    }
}
