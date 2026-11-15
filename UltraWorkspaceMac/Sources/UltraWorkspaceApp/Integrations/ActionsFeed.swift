import Foundation
import UltraBarKit

/// The GitHub Actions bar app's data: the user's workflow runs of the last days, read on this Mac with the user's own
/// fine-grained token (Actions: read-only), so the token never reaches the bar; the app asks for `/actions/data.json`.
///
///  - Repositories: `GET /user/repos` (owner, collaborator and organisation member; up to three pages of 100), every
///    30 minutes. Kept: not archived, not a fork unless asked, pushed to within the chosen days plus 30; at most 30.
///  - Runs: `GET /repos/{owner}/{repo}/actions/runs?created=>=…` per kept repository, one request at a time, with the
///    repository's last ETag so an unchanged answer is a 304 (which GitHub does not count against the rate limit).
///    Every 60 seconds while a run is queued or running, else every 3 minutes.
///
/// A refused token stops the loop until the token changes; an exhausted rate limit waits until GitHub's reset time.
/// Nothing runs while the app is not on the bar and nobody asked in the last ten minutes. Kept in memory only.
@MainActor
final class ActionsFeed: ObservableObject {
    @Published var token: String = Store.shared.loadSecret(name: "github-actions-token") ?? "" {
        didSet {
            Store.shared.saveSecret(token.trimmingCharacters(in: .whitespacesAndNewlines), name: "github-actions-token", debounce: true)
            repos = []; reposAt = .distantPast; runs = [:]; etags = [:]; lastError = nil; updatedAt = nil; rejected = false; forced = true; wake.signal()
        }
    }
    @Published private(set) var lastError: String?
    @Published private(set) var updatedAt: Date?
    /// Repositories watched, for the settings ("9 repositories · updated 1 min ago").
    @Published private(set) var repoCount = 0

    var hasToken: Bool { !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var days: () -> Int = { 7 }
    private var forks: () -> Bool = { false }
    private var lastQuery = ""
    private var repos: [String] = []
    private var reposAt = Date.distantPast
    private var runs: [String: [ActionsRuns.Run]] = [:]
    private var etags: [String: String] = [:]
    private var rateUntil: Date?
    /// GitHub said 401: no more requests with this token.
    private var rejected = false
    /// Refresh Now or a new token: read again without waiting for the interval.
    private var forced = false
    private var loop: Task<Void, Never>?
    private let wake = WakeSignal()

    func start(days: @escaping @MainActor () -> Int, forks: @escaping @MainActor () -> Bool, wanted: @escaping @MainActor () -> Bool) {
        self.days = days; self.forks = forks
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let query = "\(days())/\(forks())"
                if query != self.lastQuery { self.lastQuery = query; self.reposAt = .distantPast; self.runs = [:]; self.etags = [:] }
                // A token being typed or pasted: let it settle before trying it.
                if self.forced { try? await Task.sleep(for: .seconds(1.5)) }
                self.forced = false
                let active = self.hasToken && !self.rejected && wanted()
                if active, (self.rateUntil ?? .distantPast) <= Date() { await self.refresh() }
                var wait: Double = active ? (self.anyRunning ? 60 : 180) : 600
                if active, let r = self.rateUntil, r > Date() { wait = max(30, r.timeIntervalSinceNow + 5) }
                await self.wake.wait(wait) { self.forced || "\(days())/\(forks())" != self.lastQuery || (self.hasToken && !self.rejected && wanted()) != active }
            }
        }
    }
    func stop() { loop?.cancel(); loop = nil }
    func poke() { wake.signal() }
    func refreshNow() { reposAt = .distantPast; etags = [:]; rejected = false; rateUntil = nil; forced = true; wake.signal() }

    private var anyRunning: Bool { runs.values.contains { $0.contains { $0.state == .running } } }

    // MARK: refresh

    private struct Failure: Error { let message: String }

    private func refresh() async {
        do {
            if Date().timeIntervalSince(reposAt) >= 1800 { try await loadRepos() }
            let since = ActionsRuns.since(days: days())
            var refused = 0
            for repo in repos {
                guard !Task.isCancelled else { return }
                var c = URLComponents(string: "https://api.github.com/repos/\(repo)/actions/runs")!
                c.queryItems = [URLQueryItem(name: "per_page", value: "10"), URLQueryItem(name: "created", value: ">=" + since)]
                guard let url = c.url else { continue }
                let (data, http) = try await get(url, etag: etags[repo])
                switch http.statusCode {
                case 304: continue
                case 200:
                    let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                    runs[repo] = ActionsRuns.parse(j, repo: repo)
                    if let e = http.value(forHTTPHeaderField: "ETag") { etags[repo] = e }
                case 404:
                    runs[repo] = nil; etags[repo] = nil      // gone, or no access to this one: leave it out
                case 403 where http.value(forHTTPHeaderField: "X-RateLimit-Remaining") != "0":
                    // Not this one (an organisation that does not allow fine-grained tokens, say): the others still count.
                    runs[repo] = nil; etags[repo] = nil; refused += 1
                default:
                    try fail(http)
                }
            }
            if refused > 0, refused == repos.count { try fail(403) }
            lastError = nil; updatedAt = Date()
        } catch let f as Failure {
            lastError = f.message
        } catch {
            lastError = "GitHub: \(error.localizedDescription)"
        }
    }

    private func loadRepos() async throws {
        var next = URL(string: "https://api.github.com/user/repos?per_page=100&sort=pushed&affiliation=owner,collaborator,organization_member")
        var all: [[String: Any]] = []
        var pages = 0
        while let url = next, pages < 3 {
            let (data, http) = try await get(url, etag: nil)
            guard http.statusCode == 200 else { try fail(http) }
            all += (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            next = ActionsRuns.nextLink(http.value(forHTTPHeaderField: "Link")); pages += 1
        }
        let iso = ISO8601DateFormatter()
        let cutoff = Date().addingTimeInterval(-Double(days() + 30) * 86400)
        let kept = all.compactMap { r -> (String, Date)? in
            guard let name = r["full_name"] as? String, r["archived"] as? Bool != true, forks() || r["fork"] as? Bool != true,
                  let pushed = (r["pushed_at"] as? String).flatMap({ iso.date(from: $0) }), pushed >= cutoff else { return nil }
            return (name, pushed)
        }.sorted { $0.1 > $1.1 }.prefix(30).map(\.0)
        repos = kept; reposAt = Date(); repoCount = kept.count
        let keep = Set(kept)
        runs = runs.filter { keep.contains($0.key) }; etags = etags.filter { keep.contains($0.key) }
    }

    private func get(_ url: URL, etag: String?) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Bearer " + token.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        // Our own ETags decide; URLSession's cache would turn a 304 into a 200 with old data.
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw Failure(message: "GitHub answered without a status.") }
        return (data, http)
    }

    /// A refusal → the message for the settings, and what to do about it.
    private func fail(_ http: HTTPURLResponse) throws -> Never { try fail(http.statusCode, http) }
    private func fail(_ code: Int, _ http: HTTPURLResponse? = nil) throws -> Never {
        let remaining = http?.value(forHTTPHeaderField: "X-RateLimit-Remaining")
        switch code {
        case 401:
            rejected = true
            throw Failure(message: "GitHub didn't accept the token. Check it hasn't expired.")
        case 403 where remaining == "0", 429:
            let reset = http?.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
            let retry = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init).map { Date().addingTimeInterval($0) }
            let until = reset ?? retry ?? Date().addingTimeInterval(300)
            rateUntil = until
            throw Failure(message: "GitHub's rate limit is used up. Deckhand waits until \(until.formatted(date: .omitted, time: .shortened)).")
        case 403:
            throw Failure(message: "The token may not read Actions. Give it Actions read-only access.")
        default:
            throw Failure(message: "GitHub answered \(code). Deckhand tries again in a few minutes.")
        }
    }

    // MARK: what the bar gets

    func snapshot() -> [String: Any] {
        var out: [String: Any] = ["hasToken": hasToken, "days": days(), "at": Int(Date().timeIntervalSince1970)]
        if let e = lastError { out["error"] = e }
        guard hasToken, updatedAt != nil else { return out }
        let all = runs.values.flatMap { $0 }
        let c = ActionsRuns.summary(all)
        out["counts"] = ["passing": c.passing, "failing": c.failing, "running": c.running, "cancelled": c.cancelled]
        out["repoCount"] = repoCount
        out["repos"] = ActionsRuns.repoStates(all).map { ["name": short($0.repo), "state": $0.state.rawValue] }
        out["runs"] = ActionsRuns.merge(all).prefix(30).map { r -> [String: Any] in
            var d: [String: Any] = ["repo": short(r.repo), "full": r.repo, "workflow": r.workflow, "title": r.title, "branch": r.branch,
                                    "event": r.event, "state": r.state.rawValue, "status": r.status, "started": Int(r.started.timeIntervalSince1970),
                                    "attempt": r.attempt, "url": r.url.replacingOccurrences(of: "https://", with: "")]
            if let x = r.conclusion { d["conclusion"] = x }
            if let x = r.duration { d["duration"] = Int(x) }
            return d
        }
        if let u = updatedAt { out["updated"] = Int(u.timeIntervalSince1970) }
        return out
    }

    /// "owner/name" → "name": the bar has little room, and most people's repositories share one owner.
    private func short(_ full: String) -> String { full.split(separator: "/").last.map(String.init) ?? full }

    /// Deckhand Home's line: what is failing or running, else that everything passes.
    func homeLine() -> (line: String, tone: String)? {
        guard hasToken, updatedAt != nil else { return nil }
        let c = ActionsRuns.summary(runs.values.flatMap { $0 })
        if c.failing > 0 { return ("\(c.failing) failing", "down") }
        if c.running > 0 { return ("\(c.running) running", "live") }
        return (c.passing > 0 ? "All passing" : "No runs", "")
    }
}
