import Foundation
import UltraBarKit

/// The Jira Board bar app's data: one board's columns and cards, read on this Mac from the user's Atlassian site with
/// their e-mail and API token (HTTP Basic), so the token never reaches the bar; the app asks for `/jira/data.json`.
///
///  - Who: `GET /rest/api/3/myself` (account id and name), once per sign-in.
///  - Boards for the picker: `GET /rest/agile/1.0/board`, pages of 50 (at most 200 boards), every 6 hours and when
///    Apps → Jira Board opens.
///  - Columns: `GET /rest/agile/1.0/board/{id}/configuration`, every 30 minutes.
///  - Cards: `GET /rest/agile/1.0/board/{id}/issue`, pages of 100 (at most 300), every 2 minutes: on a scrum board the
///    open sprint's issues, on a kanban board everything not done plus what was updated in the last 14 days, so the
///    Done column stays short.
///
/// Read only: Deckhand never changes anything in Jira. A refused sign-in stops the loop until the e-mail, token or
/// site changes. Nothing runs while the app is not on the bar, nobody asked in the last ten minutes and the settings
/// are closed. Kept in memory only.
@MainActor
final class JiraFeed: ObservableObject {
    @Published var email: String = Store.shared.loadSecret(name: "jira-email") ?? "" {
        didSet { Store.shared.saveSecret(email.trimmingCharacters(in: .whitespacesAndNewlines), name: "jira-email", debounce: true); signedOut() }
    }
    @Published var token: String = Store.shared.loadSecret(name: "jira-token") ?? "" {
        didSet { Store.shared.saveSecret(token.trimmingCharacters(in: .whitespacesAndNewlines), name: "jira-token", debounce: true); signedOut() }
    }
    @Published private(set) var lastError: String?
    @Published private(set) var updatedAt: Date?
    /// The signed-in user's name, for the settings ("Signed in as …").
    @Published private(set) var displayName: String?
    /// The boards the user can see, for the picker.
    @Published private(set) var boards: [Board] = []
    @Published private(set) var columnCount = 0

    struct Board: Identifiable, Hashable { let id: Int; let name: String; let project: String; let type: String }

    var hasToken: Bool { !email.trimmingCharacters(in: .whitespaces).isEmpty && !token.trimmingCharacters(in: .whitespaces).isEmpty }

    private var site: () -> String = { "" }
    private var board: () -> Int = { 0 }
    private var onlyMine: () -> Bool = { false }
    private var accountId: String?
    private var boardsAt = Date.distantPast
    private var boardsHost = ""
    private var configAt = Date.distantPast
    private var boardName = ""
    private var boardType = ""
    private var columnsConfig: [[String: Any]] = []
    private var issues: [[String: Any]] = []
    private var issuesAt = Date.distantPast
    private var lastQuery = ""
    private var lastHost = ""
    /// Jira said 401: no more requests with these credentials.
    private var rejected = false
    /// The board that answered 404: not asked again until another is chosen.
    private var missingBoard = 0
    private var retryAt: Date?
    /// Refresh Now, new credentials, or the settings asking for the board list.
    private var forced = false
    private var wantBoards = false
    private var loop: Task<Void, Never>?
    private let wake = WakeSignal()

    var host: String? { JiraBoard.host(site()) }
    var configured: Bool { hasToken && host != nil }

    func start(site: @escaping @MainActor () -> String, board: @escaping @MainActor () -> Int, onlyMine: @escaping @MainActor () -> Bool,
               wanted: @escaping @MainActor () -> Bool) {
        self.site = site; self.board = board; self.onlyMine = onlyMine
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Credentials being typed or pasted: wait until they have not changed for 1.5 s before trying them,
                // so a half-typed e-mail or token is not sent (and a run of refusals does not lock the account).
                while self.forced, !Task.isCancelled { self.forced = false; try? await Task.sleep(for: .seconds(1.5)) }
                let h = self.host ?? ""
                if h != self.lastHost { self.lastHost = h; self.resetSignIn() }
                let query = "\(h)/\(board())"
                if query != self.lastQuery { self.lastQuery = query; self.resetBoard() }
                let usable = self.configured && !self.rejected && (self.retryAt ?? .distantPast) <= Date()
                let active = usable && wanted()
                if usable && (self.wantBoards || (active && Date().timeIntervalSince(self.boardsAt) >= 6 * 3600)) { await self.loadBoards() }
                self.wantBoards = false
                if active, board() > 0, board() != self.missingBoard { await self.refresh(board: board()) }
                var wait: Double = active ? 120 : 600
                if let r = self.retryAt, r > Date() { wait = max(30, r.timeIntervalSinceNow + 5) }
                await self.wake.wait(wait) {
                    self.forced || self.wantBoards || "\(self.host ?? "")/\(board())" != self.lastQuery
                        || (self.configured && !self.rejected && wanted()) != active
                }
            }
        }
    }
    func stop() { loop?.cancel(); loop = nil }
    func poke() { wake.signal() }
    func refreshNow() { rejected = false; retryAt = nil; missingBoard = 0; configAt = .distantPast; issuesAt = .distantPast; wantBoards = true; forced = true; wake.signal() }
    /// Apps → Jira Board opened: read the boards for the picker (and who is signed in), even when the app is not on the bar.
    func settingsOpened() { guard configured, Date().timeIntervalSince(boardsAt) > 60 || boardsHost != (host ?? "") else { return }; wantBoards = true; wake.signal() }

    /// New credentials (only typed in Apps → Jira Board): sign in again and read the boards for the picker, also when the
    /// app is not on the bar yet.
    private func signedOut() { resetSignIn(); resetBoard(); forced = true; wantBoards = true; wake.signal() }
    private func resetSignIn() {
        accountId = nil; displayName = nil; boards = []; boardsAt = .distantPast; boardsHost = ""
        rejected = false; retryAt = nil; lastError = nil; updatedAt = nil
    }
    private func resetBoard() {
        configAt = .distantPast; boardName = ""; boardType = ""; columnsConfig = []; issues = []; issuesAt = .distantPast
        columnCount = 0; missingBoard = 0; updatedAt = nil; if !rejected { lastError = nil }
    }

    // MARK: refresh

    private struct Failure: Error { let message: String }

    private func refresh(board id: Int) async {
        do {
            if accountId == nil { try await loadMe() }
            if Date().timeIntervalSince(configAt) >= 1800 {
                let c = try await getJSON("/rest/agile/1.0/board/\(id)/configuration", board: true)
                boardName = (c["name"] as? String) ?? ""
                if let t = c["type"] as? String { boardType = t } else if let b = boards.first(where: { $0.id == id }) { boardType = b.type }
                columnsConfig = ((c["columnConfig"] as? [String: Any])?["columns"] as? [[String: Any]]) ?? []
                columnCount = columnsConfig.filter { !(($0["statuses"] as? [Any]) ?? []).isEmpty }.count
                configAt = Date()
            }
            let jql = boardType == "scrum" ? "sprint in openSprints()" : "statusCategory != Done OR updated >= -14d"
            var all: [[String: Any]] = []
            var startAt = 0
            while all.count < 300 {
                guard !Task.isCancelled else { return }
                var c = URLComponents()
                c.queryItems = [URLQueryItem(name: "maxResults", value: "100"), URLQueryItem(name: "startAt", value: String(startAt)),
                                URLQueryItem(name: "fields", value: "summary,status,assignee,priority,issuetype,updated,duedate"),
                                URLQueryItem(name: "jql", value: jql)]
                let j = try await getJSON("/rest/agile/1.0/board/\(id)/issue?" + (c.percentEncodedQuery ?? ""), board: true)
                let page = (j["issues"] as? [[String: Any]]) ?? []
                all += page
                startAt += page.count
                let total = (j["total"] as? NSNumber)?.intValue ?? 0
                if page.isEmpty || startAt >= total { break }
            }
            issues = all; issuesAt = Date(); lastError = nil; updatedAt = Date()
        } catch let f as Failure {
            lastError = f.message
        } catch {
            lastError = "Jira: \(error.localizedDescription)"
        }
    }

    private func loadMe() async throws {
        let me = try await getJSON("/rest/api/3/myself", board: false)
        accountId = (me["accountId"] as? String) ?? ""
        displayName = me["displayName"] as? String
    }

    private func loadBoards() async {
        do {
            if accountId == nil { try await loadMe() }
            var found: [Board] = []
            var startAt = 0
            while found.count < 200 {
                let j = try await getJSON("/rest/agile/1.0/board?maxResults=50&startAt=\(startAt)", board: false)
                let page = (j["values"] as? [[String: Any]]) ?? []
                found += page.compactMap { b in
                    guard let id = (b["id"] as? NSNumber)?.intValue else { return nil }
                    return Board(id: id, name: (b["name"] as? String) ?? "Board \(id)",
                                 project: ((b["location"] as? [String: Any])?["projectKey"] as? String) ?? "", type: (b["type"] as? String) ?? "")
                }
                startAt += page.count
                if page.isEmpty || (j["isLast"] as? Bool) ?? true { break }
            }
            boards = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            boardsAt = Date(); boardsHost = host ?? ""
            if board() == 0 || lastError?.hasPrefix("Jira didn't accept") == true { lastError = nil }
        } catch let f as Failure {
            lastError = f.message
        } catch {
            lastError = "Jira: \(error.localizedDescription)"
        }
    }

    private func getJSON(_ path: String, board: Bool) async throws -> [String: Any] {
        guard let host, let url = URL(string: "https://\(host)\(path)") else { throw Failure(message: "Enter your Atlassian site, such as yourcompany.atlassian.net.") }
        var req = URLRequest(url: url, timeoutInterval: 20)
        let creds = email.trimmingCharacters(in: .whitespacesAndNewlines) + ":" + token.trimmingCharacters(in: .whitespacesAndNewlines)
        req.setValue("Basic " + Data(creds.utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw Failure(message: "Jira answered without a status.") }
        switch http.statusCode {
        case 200:
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        case 401:
            rejected = true
            throw Failure(message: "Jira didn't accept the e-mail and token.")
        case 404 where board:
            missingBoard = self.board()
            throw Failure(message: "This board no longer exists. Choose another under Apps → Jira Board.")
        case 403 where board:
            missingBoard = self.board()
            throw Failure(message: "Your account may not see this board. Choose another under Apps → Jira Board.")
        case 404:
            throw Failure(message: "No Jira found at \(host). Check the site.")
        case 429:
            let after = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 300
            retryAt = Date().addingTimeInterval(after)
            throw Failure(message: "Jira asked Deckhand to slow down. It tries again in a few minutes.")
        default:
            throw Failure(message: "Jira answered \(http.statusCode). Deckhand tries again in a few minutes.")
        }
    }

    // MARK: what the bar gets

    private func columns() -> [JiraBoard.Column] {
        JiraBoard.columns(config: columnsConfig, issues: issues, me: accountId ?? "", onlyMine: onlyMine())
    }

    func snapshot() -> [String: Any] {
        var out: [String: Any] = ["configured": configured && board() > 0, "hasToken": hasToken, "hasSite": host != nil, "hasBoard": board() > 0,
                                  "onlyMine": onlyMine(), "at": Int(Date().timeIntervalSince1970)]
        if let e = lastError { out["error"] = e }
        if let n = displayName { out["me"] = JiraBoard.initials(n) }
        guard configured, board() > 0, updatedAt != nil else { return out }
        out["board"] = ["name": boardName]
        out["columns"] = columns().map { col -> [String: Any] in
            ["name": col.name, "count": col.count, "mine": col.mine, "done": col.done,
             "cards": col.cards.map { ["key": $0.key, "summary": $0.summary, "mine": $0.mine, "who": $0.who, "prio": $0.priority, "type": $0.type] }]
        }
        if let u = updatedAt { out["updated"] = Int(u.timeIntervalSince1970) }
        return out
    }

    /// Deckhand Home's line: the user's cards waiting for review, else in progress, else how many are open.
    func homeLine() -> (line: String, tone: String)? {
        guard configured, board() > 0, updatedAt != nil else { return nil }
        let cols = JiraBoard.columns(config: columnsConfig, issues: issues, me: accountId ?? "")
        let review = cols.filter { !$0.done && $0.name.lowercased().contains("review") }.reduce(0) { $0 + $1.mine }
        if review > 0 { return ("\(review) waiting for review", "live") }
        let doing = cols.enumerated().filter { $0.offset > 0 && !$0.element.done }.reduce(0) { $0 + $1.element.mine }
        if doing > 0 { return ("\(doing) of yours in progress", "") }
        let open = cols.filter { !$0.done }.reduce(0) { $0 + $1.count }
        return (open == 1 ? "1 card open" : "\(open) cards open", "")
    }
}
