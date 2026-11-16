import Foundation
import CoreWLAN
import CryptoKit
import SystemConfiguration
import UltraBarKit

/// The Connection bar app's data, in the spirit of Network Weather: the path from this Mac to the internet measured
/// hop by hop, and which hop is the likely culprit. Only while the app is on the bar's screen:
///  - Wi-Fi signal, noise and rate (CoreWLAN) and the route (System Configuration), every 10 seconds.
///  - `ping` to the router, to the ISP's first router and to two public resolvers (1.1.1.1, 9.9.9.9): ten pings each,
///    0.2 s apart, every 10 seconds.
///  - `traceroute` to 1.1.1.1 every 30 minutes, to find the ISP's first router.
///  - Services (Microsoft 365, Zoom, Google, GitHub, Apple): one HTTPS request each every minute, timed.
///  - Optional: an ASUS router (ZenWiFi, RT-…) through its own web API with the admin login (Keychain), every minute:
///    model, firmware, internet up, CPU and memory, connected devices and the AiMesh nodes.
/// No administrator rights, no packet capture. Kept in memory only; the app asks for `/connection/data.json`.
@MainActor
final class ConnectionFeed: ObservableObject {
    @Published var routerUser: String = Store.shared.loadSecret(name: "asus-user") ?? "admin" {
        didSet { Store.shared.saveSecret(routerUser.trimmingCharacters(in: .whitespacesAndNewlines), name: "asus-user", debounce: true); routerChanged() }
    }
    @Published var routerPassword: String = Store.shared.loadSecret(name: "asus-password") ?? "" {
        didSet { Store.shared.saveSecret(routerPassword, name: "asus-password", debounce: true); routerChanged() }
    }
    @Published private(set) var routerError: String?
    @Published private(set) var routerName: String?
    @Published private(set) var updatedAt: Date?

    var hasRouterLogin: Bool { !routerUser.trimmingCharacters(in: .whitespaces).isEmpty && !routerPassword.isEmpty }

    private var wifi: Connection.WiFi?
    private var wired = false
    private var iface = ""
    private var gatewayIP: String?
    private var ispIP: String?
    private var traceAt = Date.distantPast
    private var gateway: Connection.Ping?
    private var isp: Connection.Ping?
    private var internet: Connection.Ping?
    private var history: [(gw: Double?, net: Double?)] = []
    private var services: [Connection.Service] = []
    private var servicesAt = Date.distantPast
    private var router: Connection.Router?
    private var routerAt = Date.distantPast
    private var asusToken: String?
    private var asusCookie = "asus_token"
    private var routerRejected = false
    private var routerForced = false
    private var address: () -> String = { "" }
    private var https: () -> Bool = { false }
    private var loop: Task<Void, Never>?
    private let wake = WakeSignal()

    nonisolated static let serviceList: [(String, String)] = [("Microsoft 365", "https://outlook.office.com/"), ("Zoom", "https://zoom.us/"),
                                                              ("Google", "https://www.google.com/"), ("GitHub", "https://github.com/"), ("Apple", "https://www.apple.com/")]

    func start(address: @escaping @MainActor () -> String, https: @escaping @MainActor () -> Bool, wanted: @escaping @MainActor () -> Bool) {
        self.address = address; self.https = https
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let active = wanted()
                if active { await self.step() }
                await self.wake.wait(active ? 10 : 600) { wanted() != active || self.routerForced }
            }
        }
    }
    func stop() { loop?.cancel(); loop = nil }
    func poke() { wake.signal() }
    func refreshRouter() { routerRejected = false; routerAt = .distantPast; routerForced = true; wake.signal() }
    private func routerChanged() { asusToken = nil; routerRejected = false; routerError = nil; router = nil; routerAt = .distantPast; routerForced = true; wake.signal() }

    // MARK: measuring

    private func step() async {
        readRoute()
        readWiFi()
        if gatewayIP != nil, Date().timeIntervalSince(traceAt) > 1800 {
            traceAt = Date()
            let out = await Self.run("/usr/sbin/traceroute", ["-n", "-m", "8", "-q", "1", "-w", "1", "1.1.1.1"])
            ispIP = Connection.ispHop(Connection.traceroute(out ?? ""))
        }
        let gw = gatewayIP, ih = ispIP
        async let g = gw == nil ? nil : Self.ping(gw!)
        async let i = ih == nil ? nil : Self.ping(ih!)
        async let a = Self.ping("1.1.1.1")
        async let b = Self.ping("9.9.9.9")
        let (gp, ip, ap, bp) = await (g, i, a, b)
        gateway = gp; isp = ip
        // The internet: the better of the two resolvers, so one resolver's bad minute is not "the internet".
        internet = [ap, bp].compactMap { $0 }.min { ($0.loss, $0.avg ?? 9999) < ($1.loss, $1.avg ?? 9999) }
        history.append((gateway?.avg, internet?.avg)); if history.count > 60 { history.removeFirst(history.count - 60) }
        if Date().timeIntervalSince(servicesAt) >= 60 { servicesAt = Date(); services = await Self.timeServices() }
        if (routerForced || Date().timeIntervalSince(routerAt) >= 60), hasRouterLogin, !routerRejected { routerForced = false; await readRouter() }
        routerForced = false
        updatedAt = Date()
    }

    private func readRoute() {
        guard let store = SCDynamicStoreCreate(nil, "Deckhand" as CFString, nil, nil),
              let v4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else { gatewayIP = nil; return }
        gatewayIP = v4["Router"] as? String
        iface = (v4["PrimaryInterface"] as? String) ?? ""
    }

    private func readWiFi() {
        let wl = CWWiFiClient.shared().interface()
        wired = wl?.interfaceName != iface || wl?.powerOn() != true
        if !wired, let i = wl, i.rssiValue() != 0 { wifi = Connection.WiFi(rssi: i.rssiValue(), noise: i.noiseMeasurement(), rate: i.transmitRate()) }
        else { wifi = nil }
        if !wired, let ch = wl?.wlanChannel() {
            wifiChannel = ch.channelNumber
            wifiBand = ch.channelBand == .band2GHz ? "2.4 GHz" : ch.channelBand == .band5GHz ? "5 GHz" : ch.channelBand == .band6GHz ? "6 GHz" : ""
        }
    }
    private var wifiChannel = 0
    private var wifiBand = ""

    nonisolated private static func ping(_ host: String) async -> Connection.Ping? {
        guard host.range(of: "^[0-9a-fA-F:.]+$", options: .regularExpression) != nil else { return nil }
        return Connection.ping(await run("/sbin/ping", ["-q", "-c", "10", "-i", "0.2", "-t", "4", host]) ?? "")
    }

    nonisolated private static func run(_ path: String, _ args: [String]) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path); p.arguments = args
            let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(data: data, encoding: .utf8)
        }.value
    }

    nonisolated private static func timeServices() async -> [Connection.Service] {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5; cfg.requestCachePolicy = .reloadIgnoringLocalCacheData; cfg.httpMaximumConnectionsPerHost = 1
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }
        return await withTaskGroup(of: (Int, Connection.Service).self) { group in
            for (n, (name, url)) in serviceList.enumerated() {
                group.addTask {
                    var req = URLRequest(url: URL(string: url)!); req.httpMethod = "HEAD"
                    let t0 = Date()
                    let ok = ((try? await session.data(for: req))?.1 as? HTTPURLResponse) != nil
                    return (n, Connection.Service(name: name, ms: ok ? Date().timeIntervalSince(t0) * 1000 : nil))
                }
            }
            var out: [(Int, Connection.Service)] = []
            for await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    // MARK: the ASUS router

    private struct RouterFailure: Error { let message: String }

    private var routerBase: String? {
        Connection.routerBase(address(), fallback: gatewayIP, https: https())
    }

    private func readRouter() async {
        routerAt = Date()
        guard let base = routerBase else { routerError = "Enter the router's address as 192.168.50.1 or 192.168.50.1:8443."; return }
        do {
            if asusToken == nil { try await asusLogin(base) }
            var text = try await asusGet(base)
            if text.contains("Main_Login.asp") || text.isEmpty { asusToken = nil; try await asusLogin(base); text = try await asusGet(base) }
            let r = Connection.router(Connection.asusJSON(text))
            if r.model.isEmpty && r.nodes.isEmpty && r.wired + r.wireless == 0 { throw RouterFailure(message: "The router's answer had nothing Deckhand understands (" + Self.jsonProblem(text) + ").") }
            router = r; routerName = r.model.isEmpty ? nil : r.model; routerError = nil
        } catch let f as RouterFailure { routerError = f.message } catch { routerError = "Router: \(error.localizedDescription)" }
    }

    /// Where an answer stops being JSON, with a little text around it (long letter-and-digit runs blanked out).
    nonisolated static func jsonProblem(_ text: String) -> String {
        let cleaned = text.replacingOccurrences(of: ",\\s*([}\\]])", with: "$1", options: .regularExpression)
        do { _ = try JSONSerialization.jsonObject(with: Data(cleaned.utf8)); return "\(text.count) characters" }
        catch {
            let info = (error as NSError).userInfo
            let idx = (info["NSJSONSerializationErrorIndex"] as? Int) ?? 0
            let u = Array(cleaned.utf8)
            let lo = max(0, idx - 40), hi = min(u.count, idx + 40)
            let around = String(decoding: u[lo..<hi], as: UTF8.self)
                .replacingOccurrences(of: "[A-Za-z0-9+/=_-]{16,}", with: "…", options: .regularExpression)
            return "at \(idx) of \(u.count): …\(around)…"
        }
    }

    private func asusLogin(_ base: String) async throws {
        var req = URLRequest(url: URL(string: base + "/login.cgi")!, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(base + "/Main_Login.asp", forHTTPHeaderField: "Referer")
        req.setValue("Deckhand", forHTTPHeaderField: "User-Agent")
        let auth = Data("\(routerUser.trimmingCharacters(in: .whitespacesAndNewlines)):\(routerPassword)".utf8).base64EncodedString()
        req.httpBody = Data(("login_authorization=" + (auth.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? auth)).utf8)
        let (data, resp) = try await session.data(for: req)
        let http = resp as? HTTPURLResponse
        // The token comes back as JSON ({"asus_token": "…"}) or as a cookie, depending on the firmware.
        let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        var token = j?["asus_token"] as? String
        // Over HTTPS newer firmware names the cookie asus_s_token; it has to come back under the same name.
        var cookieName = "asus_token"
        if token == nil, let cookie = http?.value(forHTTPHeaderField: "Set-Cookie") {
            for name in ["asus_s_token", "asus_token"] {
                if let r = cookie.range(of: "(^|[;, ])\(name)=", options: .regularExpression) {
                    token = String(cookie[r.upperBound...].prefix { $0 != ";" && $0 != "," }); cookieName = name; break
                }
            }
        }
        guard let t = token, !t.isEmpty, t != "deleted" else {
            let status = (j?["error_status"] as? NSNumber)?.intValue ?? Int((j?["error_status"] as? String) ?? "") ?? 0
            routerRejected = true
            switch status {
            case 3: throw RouterFailure(message: "The router didn't accept the user name and password.")
            case 7, 8, 10: throw RouterFailure(message: "The router has locked logins for a while after failed attempts. Try again later.")
            case 9: throw RouterFailure(message: "Someone else is logged in to the router's web page. Log out there and press Try Again.")
            default:
                // Most ASUS firmware answers a refused login with a page that sends the browser back to Main_Login.asp.
                if String(data: data, encoding: .utf8)?.contains("Main_Login.asp") == true {
                    throw RouterFailure(message: "The router sent Deckhand back to its login page: check the user name and password (as on the router's web page), log out of that page if it is open, and press Try Again.")
                }
                // What came back, without values that could be a token: the JSON keys and values, or the start of the page,
                // with long letter-and-digit runs blanked out; plus the names of any cookies.
                var shape = j.map { $0.map { "\($0.key)=\(String(describing: $0.value).count > 12 ? "…" : String(describing: $0.value))" }.sorted().joined(separator: ", ") }
                    ?? String((String(data: data, encoding: .utf8) ?? "").replacingOccurrences(of: "[A-Za-z0-9+/=_-]{16,}", with: "…", options: .regularExpression)
                        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).prefix(120))
                if let c = http?.value(forHTTPHeaderField: "Set-Cookie") { shape += "; cookies: " + c.split(separator: ",").compactMap { $0.split(separator: "=").first?.trimmingCharacters(in: .whitespaces) }.joined(separator: " ") }
                throw RouterFailure(message: "The router did not let Deckhand log in (\(http?.statusCode ?? 0): \(shape.isEmpty ? "empty answer" : shape)).")
            }
        }
        asusToken = t; asusCookie = cookieName
    }

    private func asusGet(_ base: String) async throws -> String {
        var req = URLRequest(url: URL(string: base + "/appGet.cgi")!, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(base + "/index.asp", forHTTPHeaderField: "Referer")
        req.setValue("Deckhand", forHTTPHeaderField: "User-Agent")
        req.setValue("\(asusCookie)=\(asusToken ?? "")", forHTTPHeaderField: "Cookie")
        req.httpBody = Data(("hook=" + (Connection.asusHooks.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")).utf8)
        let (data, _) = try await session.data(for: req)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// For HTTPS the router's own self-signed certificate is trusted on first use and pinned (its SHA-256 in the
    /// Keychain); a different certificate later is refused.
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieAcceptPolicy = .never; cfg.httpShouldSetCookies = false
        return URLSession(configuration: cfg, delegate: RouterPin(), delegateQueue: nil)
    }()

    // MARK: what the bar gets

    func snapshot() -> [String: Any] {
        var out: [String: Any] = ["at": Int(Date().timeIntervalSince1970)]
        guard updatedAt != nil else { out["warming"] = true; return out }
        let v = Connection.verdict(wifi: wifi, wired: wired, gateway: gateway, internet: internet, services: services, routerWanDown: router?.wanUp == false)
        out["verdict"] = ["sky": v.sky.rawValue, "culprit": v.culprit, "headline": v.headline, "detail": v.detail]
        func p(_ x: Connection.Ping?) -> Any {
            guard let x else { return NSNull() }
            return ["avg": x.avg.map { $0 as Any } ?? NSNull(), "jitter": x.jitter.map { $0 as Any } ?? NSNull(), "loss": x.loss]
        }
        out["wired"] = wired
        if let w = wifi { out["wifi"] = ["rssi": w.rssi, "noise": w.noise, "snr": w.snr, "rate": w.rate, "channel": wifiChannel, "band": wifiBand, "level": Connection.level(w).name] }
        out["gateway"] = p(gateway); out["isp"] = p(isp); out["internet"] = p(internet)
        out["levels"] = ["wifi": wired ? "ok" : Connection.level(wifi).name, "router": Connection.gatewayLevel(gateway).name,
                         "isp": isp == nil ? Connection.internetLevel(internet).name : Connection.level(isp, warnMs: 40, badMs: 120, warnJitter: 20).name,
                         "internet": Connection.internetLevel(internet).name,
                         "services": services.isEmpty ? "unknown" : services.map(\.level).max()!.name]
        out["services"] = services.map { ["name": $0.name, "ms": $0.ms.map { $0 as Any } ?? NSNull(), "level": $0.level.name] }
        out["history"] = ["gw": history.map { $0.gw.map { $0 as Any } ?? NSNull() }, "net": history.map { $0.net.map { $0 as Any } ?? NSNull() }]
        if let r = router {
            out["router"] = ["model": r.model, "firmware": r.firmware, "wanUp": r.wanUp.map { $0 as Any } ?? NSNull(), "cpu": r.cpu.map { $0 as Any } ?? NSNull(),
                             "memory": r.memory.map { $0 as Any } ?? NSNull(), "wired": r.wired, "wireless": r.wireless,
                             "nodes": r.nodes.map { ["name": $0.name, "model": $0.model, "online": $0.online, "clients": $0.clients] }]
        }
        out["routerLogin"] = hasRouterLogin
        if let e = routerError { out["routerError"] = e }
        return out
    }

    func homeLine() -> (line: String, tone: String)? {
        guard updatedAt != nil else { return nil }
        let v = Connection.verdict(wifi: wifi, wired: wired, gateway: gateway, internet: internet, services: services, routerWanDown: router?.wanUp == false)
        return (v.headline, v.sky == .stormy ? "down" : v.sky == .cloudy ? "warn" : v.sky == .clear ? "up" : "")
    }
}

/// Trust-on-first-use for the router's self-signed HTTPS certificate: the first certificate's SHA-256 is kept in the
/// Keychain and only that one is accepted afterwards. Plain HTTP and other hosts are left to the system.
final class RouterPin: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust,
              Connection.isPrivate(challenge.protectionSpace.host),
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return (.performDefaultHandling, nil) }
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        let name = "asus-cert-\(challenge.protectionSpace.host)" + (challenge.protectionSpace.port == 8443 ? "" : ":\(challenge.protectionSpace.port)")
        if let pinned = Store.shared.loadSecret(name: name), !pinned.isEmpty {
            return pinned == digest ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
        }
        Store.shared.saveSecret(digest, name: name)
        return (.useCredential, URLCredential(trust: trust))
    }
}
