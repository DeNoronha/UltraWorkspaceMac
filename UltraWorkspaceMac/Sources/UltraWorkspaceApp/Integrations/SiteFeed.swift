import Foundation
import AppKit
import CryptoKit
import UltraBarKit

/// The SEO bar app's data for one site (the URL under Apps → SEO), gathered on this Mac so the Google sign-in and the
/// API key never reach the bar; the app asks for `/seo/data.json`. Three parts, each on its own clock:
///
///  - **Audit** (hourly): the page itself. Deckhand fetches the URL (status, redirects, response time), reads its head
///    (title, meta description, one H1, canonical, language, viewport, `noindex`), asks for `/robots.txt` and the
///    sitemap it names (or `/sitemap.xml`), whether plain http sends you to https, and how long the certificate is valid.
///  - **PageSpeed** (every 6 hours, mobile and desktop): Google's Lighthouse scores for Performance, SEO, Accessibility
///    and Best Practices, the lab timings, and the Core Web Vitals of real visitors (Chrome UX Report) when Google has
///    them. PageSpeed Insights needs a key in practice (the anonymous allowance is shared and used up): the user's own,
///    from the same Google Cloud project; without one Deckhand tries with the Search Console sign-in.
///  - **Search Console** (every 6 hours; Google's numbers lag two to three days): clicks, impressions, CTR and
///    average position over the last 28 days against the 28 before, per day, and the top search terms. Needs the
///    user's own Google OAuth client (type Desktop app) and one sign-in: the browser comes back to a one-shot listener on
///    the loopback interface (`OAuthCallback`, as for Strava), with PKCE. Scope `webmasters.readonly`. The tokens, the
///    client id and secret and the PageSpeed key live in the Keychain (`Store.saveSecret`).
///
/// Nothing runs while the app is not on the bar and nobody asked for it in the last ten minutes. Kept in memory only.
@MainActor
final class SiteFeed: ObservableObject {
    @Published var clientID: String = Store.shared.loadSecret(name: "google-client-id") ?? "" {
        didSet { Store.shared.saveSecret(clientID.trimmingCharacters(in: .whitespacesAndNewlines), name: "google-client-id", debounce: true) }
    }
    @Published var clientSecret: String = Store.shared.loadSecret(name: "google-client-secret") ?? "" {
        didSet { Store.shared.saveSecret(clientSecret.trimmingCharacters(in: .whitespacesAndNewlines), name: "google-client-secret", debounce: true) }
    }
    @Published var pageSpeedKey: String = Store.shared.loadSecret(name: "pagespeed-key") ?? "" {
        didSet { Store.shared.saveSecret(pageSpeedKey.trimmingCharacters(in: .whitespacesAndNewlines), name: "pagespeed-key", debounce: true); psiAt = .distantPast; poke() }
    }
    @Published private(set) var tokens: GoogleTokens? = SiteFeed.loadTokens()
    @Published private(set) var connecting = false
    @Published private(set) var gscError: String?
    @Published private(set) var psiError: String?
    @Published private(set) var auditError: String?
    /// The Search Console property that matches the URL ("sc-domain:example.com" or "https://www.example.com/").
    @Published private(set) var property: String?
    @Published private(set) var updatedAt: Date?

    var hasClient: Bool { !clientID.trimmingCharacters(in: .whitespaces).isEmpty && !clientSecret.trimmingCharacters(in: .whitespaces).isEmpty }
    var connected: Bool { tokens != nil }

    private var url: () -> String = { "" }
    private var audit: [String: Any]?
    private var auditAt = Date.distantPast
    private var psi: [String: Any] = [:]          // "mobile", "desktop" → result
    private var psiAt = Date.distantPast
    private var gsc: [String: Any]?
    private var gscAt = Date.distantPast
    private var lastURL = ""
    private var loop: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var callback: OAuthCallback?
    private let wake = WakeSignal()

    nonisolated static let auditInterval: TimeInterval = 3600
    nonisolated static let psiInterval: TimeInterval = 6 * 3600
    nonisolated static let gscInterval: TimeInterval = 6 * 3600
    nonisolated static let scope = "https://www.googleapis.com/auth/webmasters.readonly"

    // MARK: tokens

    private nonisolated static func loadTokens() -> GoogleTokens? {
        guard let s = Store.shared.loadSecret(name: "google-tokens") else { return nil }
        return try? JSONDecoder().decode(GoogleTokens.self, from: Data(s.utf8))
    }
    private func saveTokens(_ t: GoogleTokens?) {
        tokens = t
        let json = t.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        Store.shared.saveSecret(json, name: "google-tokens")
    }

    // MARK: the poll

    func start(url: @escaping @MainActor () -> String, wanted: @escaping @MainActor () -> Bool) {
        self.url = url
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let site = SiteAudit.normalized(url())
                if site != self.lastURL {
                    // A new URL: forget what belonged to the old one and fetch everything again.
                    self.lastURL = site; self.audit = nil; self.psi = [:]; self.gsc = nil; self.property = nil
                    self.auditAt = .distantPast; self.psiAt = .distantPast; self.gscAt = .distantPast
                    self.auditError = nil; self.psiError = nil; self.gscError = nil
                }
                if !site.isEmpty, wanted() {
                    if Date().timeIntervalSince(self.auditAt) >= Self.auditInterval { await self.refreshAudit(site) }
                    if Date().timeIntervalSince(self.psiAt) >= Self.psiInterval { await self.refreshPageSpeed(site) }
                    if self.connected, self.hasClient, Date().timeIntervalSince(self.gscAt) >= Self.gscInterval { await self.refreshSearchConsole(site) }
                }
                let next = [self.auditAt.addingTimeInterval(Self.auditInterval), self.psiAt.addingTimeInterval(Self.psiInterval),
                            self.gscAt.addingTimeInterval(Self.gscInterval)].min()!.timeIntervalSinceNow
                await self.wake.wait(min(600, max(30, next))) { SiteAudit.normalized(url()) != self.lastURL }
            }
        }
    }
    func stop() { loop?.cancel(); loop = nil }
    func poke() { wake.signal() }
    /// Everything again now (Refresh in the settings).
    func refreshAll() { auditAt = .distantPast; psiAt = .distantPast; gscAt = .distantPast; wake.signal() }

    // MARK: audit

    private func refreshAudit(_ site: String) async {
        auditAt = Date()
        if let a = await SiteAudit.run(site) { audit = a; auditError = nil; updatedAt = Date() }
        else { auditError = "The site did not answer." }
    }

    // MARK: PageSpeed

    private func refreshPageSpeed(_ site: String) async {
        psiAt = Date()
        var out: [String: Any] = [:]
        for strategy in ["mobile", "desktop"] {
            var c = URLComponents(string: "https://www.googleapis.com/pagespeedonline/v5/runPagespeed")!
            var items: [URLQueryItem] = [.init(name: "url", value: site), .init(name: "strategy", value: strategy)]
            for cat in ["PERFORMANCE", "SEO", "ACCESSIBILITY", "BEST_PRACTICES"] { items.append(.init(name: "category", value: cat)) }
            let key = pageSpeedKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { items.append(.init(name: "key", value: key)) }
            c.queryItems = items
            var req = URLRequest(url: c.url!, timeoutInterval: 90)
            if key.isEmpty, connected, let t = try? await accessToken() { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    psiError = code == 429 ? "PageSpeed Insights: no requests left today" + (key.isEmpty ? ". Add your own PageSpeed key." : ".")
                                           : "PageSpeed Insights answered \(code)" + (SiteAudit.googleError(data).map { ": \($0)" } ?? "")
                    if code == 429 && key.isEmpty { psiAt = Date().addingTimeInterval(-Self.psiInterval + 3600) }   // try again in an hour
                    return
                }
                out[strategy] = SiteAudit.pageSpeed(j)
            } catch { psiError = "PageSpeed Insights: \(error.localizedDescription)"; return }
        }
        psi = out; psiError = nil; updatedAt = Date()
    }

    // MARK: Search Console

    private enum Failure: Error { case http(Int, String?), revoked, noProperty }

    private func refreshSearchConsole(_ site: String) async {
        gscAt = Date()
        do {
            let prop: String
            if let p = property { prop = p } else {
                let list = try await api("GET", "https://www.googleapis.com/webmasters/v3/sites")
                let entries = ((try? JSONSerialization.jsonObject(with: list) as? [String: Any])?["siteEntry"] as? [[String: Any]]) ?? []
                guard let p = SiteAudit.matchProperty(site, entries.compactMap { e in
                    (e["permissionLevel"] as? String) == "siteUnverifiedUser" ? nil : e["siteUrl"] as? String }) else { throw Failure.noProperty }
                prop = p; property = p
            }
            let enc = prop.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? prop
            let q = "https://www.googleapis.com/webmasters/v3/sites/\(enc)/searchAnalytics/query"
            let cal = Calendar(identifier: .gregorian)
            let end = cal.date(byAdding: .day, value: -1, to: Date())!
            let start = cal.date(byAdding: .day, value: -27, to: end)!
            let prevEnd = cal.date(byAdding: .day, value: -1, to: start)!, prevStart = cal.date(byAdding: .day, value: -27, to: prevEnd)!
            func body(_ s: Date, _ e: Date, _ dims: [String], _ limit: Int) -> Data {
                try! JSONSerialization.data(withJSONObject: ["startDate": SiteAudit.day(s), "endDate": SiteAudit.day(e), "dimensions": dims, "rowLimit": limit, "dataState": "all"])
            }
            let days = SiteAudit.rows(try await api("POST", q, body(start, end, ["date"], 40)))
            let total = SiteAudit.rows(try await api("POST", q, body(start, end, [], 1))).first
            let prev = SiteAudit.rows(try await api("POST", q, body(prevStart, prevEnd, [], 1))).first
            let queries = SiteAudit.rows(try await api("POST", q, body(start, end, ["query"], 6)))
            gsc = SiteAudit.searchConsole(days: days, total: total, prev: prev, queries: queries, start: start, end: end)
            gscError = nil; updatedAt = Date()
        } catch Failure.revoked {
            gscError = "Google no longer accepts Deckhand's access. Connect again."
        } catch Failure.noProperty {
            gscError = "None of your Search Console properties covers this URL. Add the site at search.google.com/search-console."
            gscAt = Date().addingTimeInterval(-Self.gscInterval + 1800)
        } catch Failure.http(let code, let msg) {
            gscError = "Search Console answered \(code)" + (msg.map { ": \($0)" } ?? "")
        } catch {
            gscError = "Search Console: \(error.localizedDescription)"
        }
    }

    private func api(_ method: String, _ url: String, _ body: Data? = nil, retried: Bool = false) async throws -> Data {
        let token = try await accessToken()
        var req = URLRequest(url: URL(string: url)!, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: return data
        case 401 where !retried:
            if var t = tokens { t.expiresAt = 0; saveTokens(t) }
            return try await api(method, url, body, retried: true)
        case 401: throw Failure.revoked
        default: throw Failure.http(code, SiteAudit.googleError(data))
        }
    }

    private func accessToken() async throws -> String {
        guard let t = tokens else { throw Failure.revoked }
        if t.expiresAt - Int(Date().timeIntervalSince1970) > 120 { return t.access }
        let (data, resp) = try await URLSession.shared.data(for: tokenRequest(["grant_type": "refresh_token", "refresh_token": t.refresh]))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 400 || code == 401 {
            saveTokens(nil); gsc = nil; property = nil
            WireLog.shared.event("google: refresh refused (\(code)); disconnected")
            throw Failure.revoked
        }
        guard code == 200, let r = try? JSONDecoder().decode(GoogleTokenResponse.self, from: data) else { throw Failure.http(code, SiteAudit.googleError(data)) }
        var n = t
        n.access = r.access_token; n.expiresAt = Int(Date().timeIntervalSince1970) + r.expires_in
        if let rt = r.refresh_token { n.refresh = rt }
        saveTokens(n)
        return n.access
    }

    private func tokenRequest(_ fields: [String: String]) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var all = fields
        all["client_id"] = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        all["client_secret"] = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        req.httpBody = Data(StravaFeed.form(all).utf8)
        return req
    }

    // MARK: connect / disconnect

    /// Opens Google's consent page (PKCE, offline access) and waits up to ten minutes for the browser to come back.
    func connect() {
        guard hasClient, !connecting else { return }
        connectTask?.cancel()
        gscError = nil; connecting = true
        connectTask = Task { [weak self] in
            guard let self else { return }
            defer { self.connecting = false; self.callback?.stop(); self.callback = nil }
            let state = OAuthCallback.randomState()
            let verifier = OAuthCallback.randomState() + OAuthCallback.randomState()
            let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            let cb = OAuthCallback(state: state, spec: .google)
            self.callback = cb
            guard let port = await cb.start() else { self.gscError = "Could not open the callback on this Mac."; return }
            let redirect = "http://127.0.0.1:\(port)/google/callback"
            var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            c.queryItems = [.init(name: "client_id", value: self.clientID.trimmingCharacters(in: .whitespacesAndNewlines)),
                            .init(name: "redirect_uri", value: redirect), .init(name: "response_type", value: "code"),
                            .init(name: "scope", value: "openid " + Self.scope), .init(name: "access_type", value: "offline"),
                            .init(name: "prompt", value: "consent"), .init(name: "state", value: state),
                            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256")]
            NSWorkspace.shared.open(c.url!)
            let result = await cb.wait(timeout: 600)
            if Task.isCancelled { return }
            switch result {
            case .none: self.gscError = "No answer from Google within ten minutes. Press Connect again."
            case .some(.failure(let msg)): self.gscError = msg
            case .some(.success(let code, _)):
                do {
                    let (data, resp) = try await URLSession.shared.data(for: self.tokenRequest(["grant_type": "authorization_code", "code": code,
                                                                                               "redirect_uri": redirect, "code_verifier": verifier]))
                    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200, let r = try? JSONDecoder().decode(GoogleTokenResponse.self, from: data), let refresh = r.refresh_token else {
                        self.gscError = "Google refused the connection (\(status))" + (SiteAudit.googleError(data).map { ": \($0)" } ?? "") + ". Check the Client ID and Secret."
                        return
                    }
                    self.saveTokens(GoogleTokens(access: r.access_token, refresh: refresh, expiresAt: Int(Date().timeIntervalSince1970) + r.expires_in))
                    self.property = nil; self.gsc = nil; self.gscAt = .distantPast
                    WireLog.shared.event("google: connected")
                    self.poke()
                } catch { self.gscError = "Connecting failed: \(error.localizedDescription)" }
            }
        }
    }

    func cancelConnect() { connectTask?.cancel(); connectTask = nil; callback?.stop(); callback = nil; connecting = false }

    /// Revokes the access at Google and forgets it here (also when Google cannot be reached: then remove Deckhand's
    /// access at myaccount.google.com/permissions).
    func disconnect() {
        guard let t = tokens else { return }
        saveTokens(nil); gsc = nil; property = nil; gscError = nil
        Task { [weak self] in
            var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!, timeoutInterval: 20)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(StravaFeed.form(["token": t.refresh]).utf8)
            let code = ((try? await URLSession.shared.data(for: req))?.1 as? HTTPURLResponse)?.statusCode
            WireLog.shared.event("google: disconnected (revoke \(code.map(String.init) ?? "unreachable"))")
            if code != 200 { self?.gscError = "Forgotten here, but Google could not be told. Remove Deckhand at myaccount.google.com/permissions." }
        }
    }

    // MARK: what the bar gets

    func snapshot() -> [String: Any] {
        let site = SiteAudit.normalized(url())
        var out: [String: Any] = ["url": site, "host": URL(string: site)?.host ?? "", "at": Int(Date().timeIntervalSince1970),
                                  "gscConnected": connected, "gscClient": hasClient]
        if let a = audit { out["audit"] = a }
        if !psi.isEmpty { out["psi"] = psi.merging(["at": Int(psiAt.timeIntervalSince1970)]) { $1 } }
        if let g = gsc { out["gsc"] = g.merging(["property": property ?? ""]) { $1 } }
        let errors = [auditError, psiError, gscError].compactMap { $0 }
        if !errors.isEmpty { out["errors"] = errors }
        return out
    }

    /// Deckhand Home's line: the mobile SEO score and the clicks of the last 28 days.
    func homeLine() -> String? {
        var parts: [String] = []
        if let s = (psi["mobile"] as? [String: Any])?["seo"] as? Int { parts.append("SEO \(s)") }
        if let c = gsc?["clicks"] as? Int { parts.append("\(SiteAudit.short(c)) clicks") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct GoogleTokens: Codable { var access: String; var refresh: String; var expiresAt: Int }
struct GoogleTokenResponse: Decodable { let access_token: String; let expires_in: Int; let refresh_token: String? }

/// The pure parts of the SEO feed: the page audit, and turning Google's answers into what the bar draws.
enum SiteAudit {
    /// "example.com" → "https://example.com/"; anything that is not http(s) → "".
    static func normalized(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "" }
        if !t.lowercased().hasPrefix("http://") && !t.lowercased().hasPrefix("https://") { t = "https://" + t }
        guard var c = URLComponents(string: t), let host = c.host, host.contains("."), ["http", "https"].contains(c.scheme?.lowercased() ?? "") else { return "" }
        c.host = host.lowercased(); c.fragment = nil
        if c.path.isEmpty { c.path = "/" }
        return c.url?.absoluteString ?? ""
    }

    static func day(_ d: Date) -> String {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/Los_Angeles"); f.dateFormat = "yyyy-MM-dd"   // Search Console's days are Pacific time
        return f.string(from: d)
    }

    static func short(_ n: Int) -> String { n >= 10_000 ? "\(n / 1000)k" : n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)" }

    static func googleError(_ data: Data) -> String? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let e = j["error"] as? [String: Any], let m = e["message"] as? String { return String(m.prefix(200)) }
        if let e = j["error_description"] as? String { return e }
        return j["error"] as? String
    }

    /// The property that covers `site`: a domain property for its domain (or a parent), else the longest URL-prefix one.
    static func matchProperty(_ site: String, _ props: [String]) -> String? {
        guard let host = URL(string: site)?.host?.lowercased() else { return nil }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if let d = props.first(where: { p in p.hasPrefix("sc-domain:") && { let d = String(p.dropFirst(10)).lowercased(); return bare == d || bare.hasSuffix("." + d) || host == d }() }) { return d }
        return props.filter { !$0.hasPrefix("sc-domain:") && site.lowercased().hasPrefix($0.lowercased()) }.max { $0.count < $1.count }
    }

    struct Row { let keys: [String]; let clicks: Double; let impressions: Double; let ctr: Double; let position: Double }
    static func rows(_ data: Data) -> [Row] {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = j["rows"] as? [[String: Any]] else { return [] }
        return rows.map { r in Row(keys: r["keys"] as? [String] ?? [], clicks: r["clicks"] as? Double ?? 0, impressions: r["impressions"] as? Double ?? 0,
                                   ctr: r["ctr"] as? Double ?? 0, position: r["position"] as? Double ?? 0) }
    }

    static func searchConsole(days: [Row], total: Row?, prev: Row?, queries: [Row], start: Date, end: Date) -> [String: Any] {
        func totals(_ r: Row?) -> [String: Any] {
            guard let r else { return ["clicks": 0, "impressions": 0, "ctr": 0.0, "position": 0.0] }
            return ["clicks": Int(r.clicks), "impressions": Int(r.impressions), "ctr": (r.ctr * 1000).rounded() / 10, "position": (r.position * 10).rounded() / 10]
        }
        var out = totals(total)
        out["prev"] = totals(prev)
        out["days"] = days.sorted { ($0.keys.first ?? "") < ($1.keys.first ?? "") }.map { ["d": $0.keys.first ?? "", "c": Int($0.clicks), "i": Int($0.impressions)] }
        out["queries"] = queries.map { ["q": $0.keys.first ?? "", "clicks": Int($0.clicks), "impressions": Int($0.impressions), "position": ($0.position * 10).rounded() / 10] }
        out["from"] = day(start); out["to"] = day(end)
        return out
    }

    /// Scores 0–100, lab timings, and the field Core Web Vitals (75th percentile and Google's verdict) when present.
    static func pageSpeed(_ j: [String: Any]) -> [String: Any] {
        let lh = j["lighthouseResult"] as? [String: Any] ?? [:]
        let cats = lh["categories"] as? [String: Any] ?? [:]
        func score(_ k: String) -> Int? { ((cats[k] as? [String: Any])?["score"] as? Double).map { Int(($0 * 100).rounded()) } }
        let audits = lh["audits"] as? [String: Any] ?? [:]
        func num(_ k: String) -> Double? { (audits[k] as? [String: Any])?["numericValue"] as? Double }
        var out: [String: Any] = [:]
        for (k, name) in [("performance", "performance"), ("seo", "seo"), ("accessibility", "accessibility"), ("best-practices", "bestPractices")] {
            if let s = score(k) { out[name] = s }
        }
        var lab: [String: Any] = [:]
        if let v = num("largest-contentful-paint") { lab["lcp"] = Int(v) }
        if let v = num("cumulative-layout-shift") { lab["cls"] = (v * 1000).rounded() / 1000 }
        if let v = num("total-blocking-time") { lab["tbt"] = Int(v) }
        if let v = num("first-contentful-paint") { lab["fcp"] = Int(v) }
        out["lab"] = lab
        let metrics = (j["loadingExperience"] as? [String: Any])?["metrics"] as? [String: Any] ?? [:]
        var field: [String: Any] = [:]
        for (k, name) in [("LARGEST_CONTENTFUL_PAINT_MS", "lcp"), ("INTERACTION_TO_NEXT_PAINT", "inp"), ("CUMULATIVE_LAYOUT_SHIFT_SCORE", "cls")] {
            guard let m = metrics[k] as? [String: Any], let p = m["percentile"] as? Double else { continue }
            field[name] = ["p75": name == "cls" ? p / 100 : p, "cat": (m["category"] as? String ?? "").lowercased()]
        }
        if !field.isEmpty { out["field"] = field }
        return out
    }

    // MARK: the audit

    /// One pass over the site: never throws; nil only when the page itself could not be fetched at all.
    static func run(_ site: String) async -> [String: Any]? {
        guard let u = URL(string: site), let host = u.host else { return nil }
        let delegate = CertProbe()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: u, timeoutInterval: 20)
        req.setValue("Mozilla/5.0 (Macintosh) Deckhand-SEO/1.0 (+https://openbarx.com/)", forHTTPHeaderField: "User-Agent")
        let t0 = Date()
        guard let (data, resp) = try? await session.data(for: req), let http = resp as? HTTPURLResponse else { return nil }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        let html = String(decoding: data.prefix(2_000_000), as: UTF8.self)
        var checks: [[String: Any]] = []
        func add(_ id: String, _ label: String, _ state: String, _ detail: String = "") { checks.append(["id": id, "label": label, "state": state, "detail": detail]) }

        add("status", "Page answers", http.statusCode == 200 ? "ok" : "fail", "HTTP \(http.statusCode)")
        add("speed", "Server response", ms < 800 ? "ok" : ms < 1800 ? "warn" : "fail", "\(ms) ms")
        let head = html.range(of: "</head>", options: .caseInsensitive).map { String(html[..<$0.upperBound]) } ?? String(html.prefix(200_000))
        let title = first(#"<title[^>]*>([\s\S]*?)</title>"#, head).map(clean)
        if let t = title, !t.isEmpty { add("title", "Title", (10...65).contains(t.count) ? "ok" : "warn", "\(t.count) characters") } else { add("title", "Title", "fail", "missing") }
        let desc = meta("description", head)
        if let d = desc, !d.isEmpty { add("description", "Meta description", (50...160).contains(d.count) ? "ok" : "warn", "\(d.count) characters") } else { add("description", "Meta description", "fail", "missing") }
        let h1 = count(#"<h1[\s>]"#, html)
        add("h1", "One H1 heading", h1 == 1 ? "ok" : h1 == 0 ? "fail" : "warn", h1 == 1 ? "" : "\(h1) found")
        let robotsMeta = (meta("robots", head) ?? "").lowercased()
        add("indexable", "Can be indexed", robotsMeta.contains("noindex") ? "fail" : "ok", robotsMeta.contains("noindex") ? "noindex" : "")
        add("canonical", "Canonical link", first(#"<link[^>]+rel=["']?canonical["']?[^>]*>"#, head) != nil ? "ok" : "warn", "")
        add("lang", "Language set", first(#"<html[^>]+lang=["']?[a-zA-Z-]+"#, html) != nil ? "ok" : "warn", "")
        add("viewport", "Mobile viewport", meta("viewport", head) != nil ? "ok" : "fail", "")
        add("social", "Social preview", meta("og:title", head, attr: "property") != nil && meta("og:image", head, attr: "property") != nil ? "ok" : "warn", "")
        add("https", "HTTPS", u.scheme == "https" ? "ok" : "fail", "")
        if u.scheme == "https" {
            var plain = URLComponents(url: u, resolvingAgainstBaseURL: false)!; plain.scheme = "http"
            if let pu = plain.url, let (_, pr) = try? await session.data(for: URLRequest(url: pu, timeoutInterval: 15)) {
                add("redirect", "http goes to https", pr.url?.scheme == "https" ? "ok" : "warn", "")
            }
        }
        if let days = delegate.daysLeft { add("cert", "Certificate", days > 14 ? "ok" : days > 0 ? "warn" : "fail", "\(days) days left") }
        // robots.txt and the sitemap
        var root = URLComponents(); root.scheme = u.scheme; root.host = host; root.port = u.port
        var sitemapURL = root.url!.appendingPathComponent("sitemap.xml")
        if let (rd, rr) = try? await session.data(from: root.url!.appendingPathComponent("robots.txt")), (rr as? HTTPURLResponse)?.statusCode == 200 {
            let txt = String(decoding: rd.prefix(200_000), as: UTF8.self)
            let blocksAll = blocksEverything(txt)
            add("robots", "robots.txt", blocksAll ? "fail" : "ok", blocksAll ? "blocks every crawler" : "")
            if let line = txt.split(whereSeparator: \.isNewline).first(where: { $0.lowercased().hasPrefix("sitemap:") }),
               let su = URL(string: line.dropFirst(8).trimmingCharacters(in: .whitespaces)) { sitemapURL = su }
        } else { add("robots", "robots.txt", "warn", "missing") }
        if let (sd, sr) = try? await session.data(from: sitemapURL), (sr as? HTTPURLResponse)?.statusCode == 200 {
            let n = count("<loc>", String(decoding: sd.prefix(5_000_000), as: UTF8.self))
            add("sitemap", "Sitemap", n > 0 ? "ok" : "warn", n > 0 ? "\(n) addresses" : "empty")
        } else { add("sitemap", "Sitemap", "warn", "not found") }

        let order = ["fail": 0, "warn": 1, "ok": 2]
        let failed = checks.filter { $0["state"] as? String == "fail" }.count, warned = checks.filter { $0["state"] as? String == "warn" }.count
        return ["at": Int(Date().timeIntervalSince1970), "status": http.statusCode, "ms": ms, "title": title ?? "",
                "checks": checks.sorted { (order[$0["state"] as! String] ?? 3) < (order[$1["state"] as! String] ?? 3) },
                "ok": checks.count - failed - warned, "warn": warned, "fail": failed, "certDays": delegate.daysLeft as Any]
    }

    static func blocksEverything(_ robots: String) -> Bool {
        var applies = false
        for raw in robots.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: "#").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            if line.hasPrefix("user-agent:") { applies = line.dropFirst(11).trimmingCharacters(in: .whitespaces) == "*" }
            else if applies, line.hasPrefix("disallow:"), line.dropFirst(9).trimmingCharacters(in: .whitespaces) == "/" { return true }
        }
        return false
    }

    static func first(_ pattern: String, _ s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        let r = m.numberOfRanges > 1 ? m.range(at: 1) : m.range
        return Range(r, in: s).map { String(s[$0]) }
    }
    static func count(_ pattern: String, _ s: String) -> Int {
        (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))?.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s)) ?? 0
    }
    /// The content of `<meta name="…" content="…">`, in either attribute order.
    static func meta(_ name: String, _ head: String, attr: String = "name") -> String? {
        let n = NSRegularExpression.escapedPattern(for: name)
        return first(#"<meta[^>]+\#(attr)=["']\#(n)["'][^>]+content=["']([^"']*)["']"#, head)
            ?? first(#"<meta[^>]+content=["']([^"']*)["'][^>]+\#(attr)=["']\#(n)["']"#, head)
    }
    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
}

/// Notes how many days the server's certificate is still valid; trust itself is left to the system.
private final class CertProbe: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var days: Int?
    var daysLeft: Int? { lock.withLock { days } }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust,
           let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
           let values = SecCertificateCopyValues(leaf, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [CFString: Any],
           let entry = values[kSecOIDX509V1ValidityNotAfter] as? [CFString: Any], let v = entry[kSecPropertyKeyValue] as? NSNumber {
            let notAfter = Date(timeIntervalSinceReferenceDate: v.doubleValue)
            lock.withLock { if days == nil { days = Int(notAfter.timeIntervalSinceNow / 86400) } }
        }
        return (.performDefaultHandling, nil)
    }
}
