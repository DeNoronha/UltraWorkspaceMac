import Foundation
import AppKit
import Network
import UltraBarKit

/// The athlete's own Strava activities for the Training bar app (Strava API v3), held on this Mac so the tokens never
/// reach the bar; the app asks for `/strava/data.json`.
///
/// The athlete creates their own API application at strava.com/settings/api (Authorization Callback Domain
/// `localhost`) and pastes its Client ID and Client Secret under Apps → Training. **Connect** opens Strava's authorize
/// page in the browser (scope `read,activity:read`); Strava sends the browser back to
/// `http://localhost:<port>/strava/callback`, which `StravaCallback` answers — a one-shot listener on the loopback
/// interface only, for this one connection, that takes the code only with the `state` this Mac made. Deckhand trades
/// the code for tokens and keeps them, with the client id and secret, in user-only secret files (`Store.saveSecret`).
/// The access token (six hours) is refreshed before it runs out; every refresh stores the new refresh token.
/// **Disconnect** revokes the tokens at Strava and forgets them.
///
/// Polling respects Strava's limits (by default 100 read requests per 15 minutes and 1,000 a day per application):
/// one call every 12 minutes while the app is on the bar (two when a busy fortnight needs a second page), the stats
/// at most hourly or when a new activity appears, nothing when the app is not on the bar, and a pause until the next
/// window on a 429 or when the rate headers say the window is nearly used. Data is kept in memory only.
@MainActor
final class StravaFeed: ObservableObject {
    @Published var clientID: String = Store.shared.loadSecret(name: "strava-client-id") ?? "" {
        didSet { Store.shared.saveSecret(clientID.trimmingCharacters(in: .whitespacesAndNewlines), name: "strava-client-id") }
    }
    @Published var clientSecret: String = Store.shared.loadSecret(name: "strava-client-secret") ?? "" {
        didSet { Store.shared.saveSecret(clientSecret.trimmingCharacters(in: .whitespacesAndNewlines), name: "strava-client-secret") }
    }
    @Published private(set) var tokens: StravaTokens? = StravaFeed.loadTokens()
    @Published private(set) var connecting = false
    @Published private(set) var lastError: String?
    @Published private(set) var updatedAt: Date?
    /// Read requests used in the current 15-minute window and today, as Strava last reported them.
    @Published private(set) var usage: (short: Int, shortLimit: Int, day: Int, dayLimit: Int)?
    /// The newest activity, for "View on Strava" in the settings.
    @Published private(set) var latestID: Int?

    var hasClient: Bool { !clientID.trimmingCharacters(in: .whitespaces).isEmpty && !clientSecret.trimmingCharacters(in: .whitespaces).isEmpty }
    var connected: Bool { tokens != nil }

    private var activities: [StravaActivity] = []
    private var stats: StravaStats?
    private var statsAt = Date.distantPast
    private var statsForLatest: Int?
    private var fetchedAt = Date.distantPast
    private var pausedUntil = Date.distantPast
    private var loop: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var callback: StravaCallback?
    private var kick = false

    nonisolated static let api = "https://www.strava.com/api/v3"
    nonisolated static let interval: TimeInterval = 12 * 60

    // MARK: tokens

    private nonisolated static func loadTokens() -> StravaTokens? {
        guard let s = Store.shared.loadSecret(name: "strava-tokens") else { return nil }
        return try? JSONDecoder().decode(StravaTokens.self, from: Data(s.utf8))
    }
    private func saveTokens(_ t: StravaTokens?) {
        tokens = t
        let json = t.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        Store.shared.saveSecret(json, name: "strava-tokens")
    }

    // MARK: the poll

    /// Runs while `wanted()` says so (the Training app is on the bar, or asked for data in the last ten minutes).
    func start(wanted: @escaping @MainActor () -> Bool) {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.connected, self.hasClient, wanted() || self.kick, Date() >= self.pausedUntil,
                   self.kick || Date().timeIntervalSince(self.fetchedAt) >= Self.interval {
                    self.kick = false
                    await self.refresh()
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
    func stop() { loop?.cancel(); loop = nil }
    /// Fetch at the next tick, whatever the interval (after connecting).
    func refreshSoon() { kick = true }

    private enum Failure: Error { case http(Int, String?), revoked, network(String) }

    private func refresh() async {
        fetchedAt = Date()
        do {
            let thisWeek = StravaData.weekStarts(now: Date())
            // Newest first; a second (and third) page only when one page does not reach back to the start of last week.
            var list: [StravaActivity] = []
            for page in 1...3 {
                let data = try await get("/athlete/activities?per_page=30&page=\(page)")
                let batch = try StravaData.activities(data)
                list += batch
                let oldest = batch.compactMap { StravaData.date($0.start_date) }.min() ?? .distantPast
                if batch.count < 30 || oldest < thisWeek.last { break }
            }
            activities = list
            let newest = list.compactMap { a in StravaData.date(a.start_date).map { (a.id, $0) } }.max { $0.1 < $1.1 }?.0
            latestID = newest
            if let id = tokens?.athleteID, stats == nil || Date().timeIntervalSince(statsAt) > 3600 || statsForLatest != newest {
                stats = try StravaData.stats(try await get("/athletes/\(id)/stats"))
                statsAt = Date(); statsForLatest = newest
            }
            lastError = nil; updatedAt = Date()
        } catch Failure.revoked {
            lastError = "Strava no longer accepts Deckhand's access. Connect again."
        } catch Failure.http(429, _) {
            lastError = "Strava's request limit is reached; Deckhand waits for the next window."
        } catch Failure.http(let code, let msg) {
            lastError = "Strava answered \(code)" + (msg.map { ": \($0)" } ?? "")
        } catch Failure.network(let m) {
            lastError = m
        } catch {
            lastError = "Could not read Strava's answer: \(error.localizedDescription)"
        }
    }

    /// One read call with a fresh access token; a 401 refreshes once and tries again.
    private func get(_ path: String, retried: Bool = false) async throws -> Data {
        let token = try await accessToken()
        guard let url = URL(string: Self.api + path) else { throw Failure.network("bad URL") }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await send(req)
        noteRate(resp)
        switch resp.statusCode {
        case 200: return data
        case 401 where !retried:
            if var t = tokens { t.expiresAt = 0; saveTokens(t) }
            return try await get(path, retried: true)
        case 401: throw Failure.revoked
        case 429:
            pausedUntil = Self.nextWindow(Date())
            throw Failure.http(429, nil)
        default: throw Failure.http(resp.statusCode, StravaData.errorMessage(data))
        }
    }

    /// The access token, refreshed when it has less than an hour left (Strava hands out a new one only then).
    private func accessToken() async throws -> String {
        guard let t = tokens else { throw Failure.revoked }
        if t.expiresAt - Int(Date().timeIntervalSince1970) > 3600 { return t.access }
        let (data, resp) = try await send(tokenRequest(["grant_type": "refresh_token", "refresh_token": t.refresh]))
        if resp.statusCode == 400 || resp.statusCode == 401 {
            // The refresh token is no longer valid (revoked at Strava, or the app's secret changed): start over.
            saveTokens(nil); activities = []; stats = nil
            WireLog.shared.event("strava: refresh refused (\(resp.statusCode)); disconnected")
            throw Failure.revoked
        }
        guard resp.statusCode == 200 else { throw Failure.http(resp.statusCode, StravaData.errorMessage(data)) }
        let r = try StravaData.token(data)
        var n = t
        n.access = r.access_token; n.refresh = r.refresh_token; n.expiresAt = r.expires_at
        saveTokens(n)
        return n.access
    }

    private func tokenRequest(_ fields: [String: String]) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://www.strava.com/oauth/token")!, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var all = fields
        all["client_id"] = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        all["client_secret"] = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        req.httpBody = Data(Self.form(all).utf8)
        return req
    }

    nonisolated static func form(_ f: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        return f.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&")
    }

    /// URLSession with a hard deadline: a request that never comes back must not stall the poll.
    private func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw Failure.network("No HTTP answer from Strava") }
            return (data, http)
        } catch let f as Failure { throw f } catch { throw Failure.network("Strava: \(error.localizedDescription)") }
    }

    /// X-ReadRateLimit-Usage / -Limit ("15-minute,daily"). Near either limit, wait for that window to pass.
    private func noteRate(_ r: HTTPURLResponse) {
        func pair(_ h: String) -> (Int, Int)? {
            let v = (r.value(forHTTPHeaderField: h) ?? "").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            return v.count == 2 ? (v[0], v[1]) : nil
        }
        guard let u = pair("X-ReadRateLimit-Usage") ?? pair("X-RateLimit-Usage"),
              let l = pair("X-ReadRateLimit-Limit") ?? pair("X-RateLimit-Limit") else { return }
        usage = (u.0, l.0, u.1, l.1)
        if u.1 >= l.1 - 10 { pausedUntil = Self.nextUTCMidnight(Date()) }
        else if u.0 >= l.0 - 5 { pausedUntil = Self.nextWindow(Date()) }
    }
    /// Strava's 15-minute windows reset at :00, :15, :30 and :45.
    nonisolated static func nextWindow(_ now: Date) -> Date {
        let t = now.timeIntervalSince1970
        return Date(timeIntervalSince1970: (floor(t / 900) + 1) * 900 + 5)
    }
    nonisolated static func nextUTCMidnight(_ now: Date) -> Date {
        Date(timeIntervalSince1970: (floor(now.timeIntervalSince1970 / 86400) + 1) * 86400 + 5)
    }

    // MARK: connect / disconnect

    /// Opens Strava's authorize page and waits (up to ten minutes) for the browser to come back to the loopback callback.
    func connect() {
        guard hasClient, !connecting else { return }
        connectTask?.cancel()
        lastError = nil; connecting = true
        connectTask = Task { [weak self] in
            guard let self else { return }
            defer { self.connecting = false; self.callback?.stop(); self.callback = nil }
            let state = StravaCallback.randomState()
            let cb = StravaCallback(state: state)
            self.callback = cb
            guard let port = await cb.start() else { self.lastError = "Could not open the callback on this Mac."; return }
            let redirect = "http://localhost:\(port)/strava/callback"
            var c = URLComponents(string: "https://www.strava.com/oauth/authorize")!
            c.queryItems = [.init(name: "client_id", value: self.clientID.trimmingCharacters(in: .whitespacesAndNewlines)),
                            .init(name: "redirect_uri", value: redirect), .init(name: "response_type", value: "code"),
                            .init(name: "approval_prompt", value: "auto"), .init(name: "scope", value: "read,activity:read"),
                            .init(name: "state", value: state)]
            guard let url = c.url else { return }
            NSWorkspace.shared.open(url)
            let result = await cb.wait(timeout: 600)
            if Task.isCancelled { return }
            switch result {
            case .none: self.lastError = "No answer from Strava within ten minutes. Press Connect again."
            case .some(.failure(let msg)): self.lastError = msg
            case .some(.success(let code, let scope)):
                do {
                    let (data, resp) = try await self.send(self.tokenRequest(["grant_type": "authorization_code", "code": code]))
                    guard resp.statusCode == 200 else {
                        self.lastError = "Strava refused the connection (\(resp.statusCode))" + (StravaData.errorMessage(data).map { ": \($0)" } ?? "") + ". Check the Client ID and Secret."
                        return
                    }
                    let r = try StravaData.token(data)
                    guard let athlete = r.athlete else { self.lastError = "Strava's answer had no athlete."; return }
                    self.saveTokens(StravaTokens(access: r.access_token, refresh: r.refresh_token, expiresAt: r.expires_at,
                                                 athleteID: athlete.id, firstName: athlete.firstname ?? "", scope: scope))
                    self.activities = []; self.stats = nil; self.statsAt = .distantPast; self.pausedUntil = .distantPast
                    WireLog.shared.event("strava: connected")
                    self.refreshSoon()
                } catch { self.lastError = "Connecting failed: \(error)" }
            }
        }
    }

    func cancelConnect() { connectTask?.cancel(); connectTask = nil; callback?.stop(); callback = nil; connecting = false }

    /// Revokes the tokens at Strava (which removes Deckhand from the athlete's apps there) and forgets them here,
    /// also when Strava cannot be reached — then the athlete can remove it at strava.com/settings/apps.
    func disconnect() {
        guard let t = tokens else { return }
        saveTokens(nil); activities = []; stats = nil; latestID = nil; updatedAt = nil; usage = nil
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines), secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { [weak self] in
            var req = URLRequest(url: URL(string: "https://www.strava.com/oauth/revoke")!, timeoutInterval: 20)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.setValue("Basic " + Data("\(id):\(secret)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
            req.httpBody = Data(Self.form(["token": t.refresh, "token_type_hint": "refresh_token"]).utf8)
            let code = ((try? await URLSession.shared.data(for: req))?.1 as? HTTPURLResponse)?.statusCode
            WireLog.shared.event("strava: disconnected (revoke \(code.map(String.init) ?? "unreachable"))")
            if code != 200 { self?.lastError = "Forgotten here, but Strava could not be told. Remove Deckhand's app at strava.com/settings/apps." }
        }
    }

    // MARK: what the bar gets

    func snapshot(metric: Bool, clock24h: Bool) -> [String: Any] {
        var out: [String: Any] = ["hasClient": hasClient, "connected": connected, "at": Int(Date().timeIntervalSince1970)]
        if let t = tokens {
            out["athlete"] = t.firstName
            if !t.scope.contains("activity:read") { out["error"] = "Strava access without activities: connect again and tick “View data about your activities”." }
        }
        if connected, updatedAt != nil {
            out.merge(StravaData.snapshot(activities: activities, stats: stats, now: Date(), units: .init(metric: metric, clock24h: clock24h))) { $1 }
            out["updated"] = Int(updatedAt!.timeIntervalSince1970)
        }
        if let e = lastError { out["error"] = e }
        return out
    }
}

/// The OAuth redirect target: `GET /strava/callback?state=…&code=…&scope=…` on the loopback interface only, on a
/// port the system picks, open only while one connection is under way. It answers any other request with 404, a
/// request from anywhere but loopback is dropped, a Host that is not localhost/127.0.0.1/[::1] gets 421 (DNS
/// rebinding), and a callback whose `state` is not the one this Mac sent gets 400 — the wait goes on. The code is
/// never logged; the browser gets a short "you can close this tab" page.
final class StravaCallback: @unchecked Sendable {
    enum Result: Sendable { case success(code: String, scope: String), failure(String) }

    private let state: String
    private let lock = NSLock()
    private var listener: NWListener?
    private var continuation: CheckedContinuation<Result?, Never>?
    private var result: Result?
    private let queue = DispatchQueue(label: "deckhand.strava.callback")

    init(state: String) { self.state = state }

    static func randomState() -> String {
        var b = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
        return b.map { String(format: "%02x", $0) }.joined()
    }

    /// The port, once listening.
    func start() async -> UInt16? {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        guard let l = try? NWListener(using: params, on: .any) else { return nil }
        setListener(l)
        return await withCheckedContinuation { (c: CheckedContinuation<UInt16?, Never>) in
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            l.stateUpdateHandler = { st in
                switch st {
                case .ready: if !once.done { once.done = true; c.resume(returning: l.port?.rawValue) }
                case .failed, .cancelled: if !once.done { once.done = true; c.resume(returning: nil) }
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.start(queue: queue)
        }
    }

    private func setListener(_ l: NWListener) { lock.withLock { listener = l } }

    /// The callback's outcome, or nil after `timeout` seconds or `stop()`.
    func wait(timeout: TimeInterval) async -> Result? {
        await withCheckedContinuation { (c: CheckedContinuation<Result?, Never>) in
            lock.lock()
            if let r = result { lock.unlock(); c.resume(returning: r); return }
            if listener == nil { lock.unlock(); c.resume(returning: nil); return }   // stopped already
            continuation = c; lock.unlock()
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(nil) }
        }
    }

    func stop() { finish(nil) }

    /// Ends the wait (with the callback's result, or nil on timeout/stop) and closes the listener. Only the first
    /// result counts; a result that arrives before `wait` is kept for it.
    private func finish(_ r: Result?) {
        lock.lock()
        if result == nil, let r { result = r }
        let c = continuation; continuation = nil
        let l = listener; listener = nil
        let out = result
        lock.unlock()
        l?.cancel()
        c?.resume(returning: r == nil ? nil : out)
    }

    private func accept(_ conn: NWConnection) {
        // Loopback only: requiredInterfaceType already keeps the LAN out; this is the second lock.
        guard Self.isLoopback(conn.endpoint) else { conn.cancel(); return }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { conn.cancel() }
        read(conn, Data())
    }

    static func isLoopback(_ e: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = e else { return false }
        switch host {
        case .ipv4(let a): return a.isLoopback
        case .ipv6(let a): return a.isLoopback || "\(a)".hasPrefix("::ffff:127.")
        default: return false
        }
    }

    private func read(_ conn: NWConnection, _ buf: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { conn.cancel(); return }
            var b = buf; if let data { b.append(data) }
            if b.count > 16384 || error != nil { conn.cancel(); return }
            if let r = b.range(of: Data("\r\n\r\n".utf8)) { self.respond(conn, String(decoding: b[..<r.lowerBound], as: UTF8.self)) }
            else if complete { conn.cancel() } else { self.read(conn, b) }
        }
    }

    /// The decision for one request head: status, page text, and the result it produces (if any). Pure, for the check.
    static func handle(head: String, state: String) -> (status: String, text: String, result: Result?) {
        let line = head.split(whereSeparator: { $0 == "\r\n" || $0 == "\n" }).first.map(String.init) ?? ""
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let c = URLComponents(string: String(parts[1])), c.path == "/strava/callback" else {
            return ("404 Not Found", "Not found.", nil)
        }
        let host = (MonitorServer.header("host", in: head) ?? "").lowercased()
        let hostName = host.hasPrefix("[") ? String(host.prefix { $0 != "]" }) + "]" : String(host.split(separator: ":").first ?? "")
        guard ["localhost", "127.0.0.1", "[::1]"].contains(hostName) else { return ("421 Misdirected Request", "Wrong host.", nil) }
        let q = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        // Constant-time compare of the state.
        let got = Array((q["state"] ?? "").utf8), want = Array(state.utf8)
        guard got.count == want.count, zip(got, want).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0 else {
            return ("400 Bad Request", "This link does not belong to the connection Deckhand started. Press Connect in Deckhand again.", nil)
        }
        if let e = q["error"] {
            let msg = e == "access_denied" ? "You did not allow Deckhand to read your Strava activities." : "Strava said: \(e)"
            return ("200 OK", msg + " You can close this tab.", .failure(msg))
        }
        guard let code = q["code"], !code.isEmpty else { return ("400 Bad Request", "No code from Strava.", nil) }
        let scope = q["scope"] ?? ""
        guard scope.split(separator: ",").contains(where: { $0 == "activity:read" || $0 == "activity:read_all" }) else {
            let msg = "Strava gave no access to your activities. Connect again and leave “View data about your activities” ticked."
            return ("200 OK", msg, .failure(msg))
        }
        return ("200 OK", "Deckhand is connected to Strava. You can close this tab.", .success(code: code, scope: scope))
    }

    private func respond(_ conn: NWConnection, _ head: String) {
        let (status, text, result) = Self.handle(head: head, state: state)
        let esc = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let html = "<!doctype html><meta charset=utf-8><title>Deckhand</title><body style=\"font:16px -apple-system,sans-serif;margin:3em;color:#222\"><p>\(esc)</p>"
        let body = Data(html.utf8)
        var h = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\n"
        h += "Referrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        var out = Data(h.utf8); out.append(body)
        conn.send(content: out, completion: .contentProcessed { [weak self] _ in
            conn.cancel()
            if let result { self?.finish(result) }
        })
    }
}
