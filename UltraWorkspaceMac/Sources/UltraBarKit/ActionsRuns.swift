import Foundation

/// The pure parts of the GitHub Actions bar app: one repository's `GET /repos/{owner}/{repo}/actions/runs` answer →
/// runs, the runs of all repositories newest first, and what each workflow's newest run says.
public enum ActionsRuns {
    public enum State: String, Sendable {
        case passing, failing, running, cancelled, skipped
        /// How much it matters, for a repository's dot: a failure outweighs a running run, which outweighs the rest.
        public var weight: Int { switch self { case .failing: 4; case .running: 3; case .cancelled: 2; case .passing: 1; case .skipped: 0 } }
    }

    public struct Run: Equatable, Sendable {
        public var repo: String
        public var workflow: String
        public var workflowID: Int
        public var title: String
        public var status: String
        public var conclusion: String?
        public var branch: String
        public var event: String
        public var started: Date
        public var updated: Date
        public var attempt: Int
        public var url: String

        public init(repo: String, workflow: String, workflowID: Int = 0, title: String, status: String, conclusion: String?, branch: String,
                    event: String, started: Date, updated: Date, attempt: Int = 1, url: String = "") {
            self.repo = repo; self.workflow = workflow; self.workflowID = workflowID; self.title = title; self.status = status
            self.conclusion = conclusion; self.branch = branch; self.event = event; self.started = started; self.updated = updated
            self.attempt = attempt; self.url = url
        }

        /// GitHub's status and conclusion in one word. A run that has not completed is running, whether it is queued,
        /// waiting for an approval or in progress; a completed one needs attention when it failed, timed out, could
        /// not start or waits for an action.
        public var state: State {
            guard status == "completed" else { return .running }
            switch conclusion ?? "" {
            case "failure", "timed_out", "startup_failure", "action_required": return .failing
            case "cancelled": return .cancelled
            case "skipped", "stale": return .skipped
            default: return .passing     // success, neutral
            }
        }
        /// How long a completed run took (its last update minus its start); nil while it runs.
        public var duration: TimeInterval? { state == .running ? nil : max(0, updated.timeIntervalSince(started)) }
    }

    /// The runs in one repository's answer (`workflow_runs`), named after `repo` ("owner/name").
    public static func parse(_ json: [String: Any], repo: String) -> [Run] {
        let iso = ISO8601DateFormatter()
        func date(_ v: Any?) -> Date? { (v as? String).flatMap { iso.date(from: $0) } }
        return ((json["workflow_runs"] as? [[String: Any]]) ?? []).compactMap { r in
            guard let created = date(r["created_at"]) else { return nil }
            let started = date(r["run_started_at"]) ?? created
            let title = (r["display_title"] as? String) ?? ((r["head_commit"] as? [String: Any])?["message"] as? String) ?? ""
            return Run(repo: repo, workflow: (r["name"] as? String) ?? "Workflow", workflowID: (r["workflow_id"] as? NSNumber)?.intValue ?? 0,
                       title: title.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "",
                       status: (r["status"] as? String) ?? "", conclusion: r["conclusion"] as? String,
                       branch: (r["head_branch"] as? String) ?? "", event: (r["event"] as? String) ?? "",
                       started: started, updated: date(r["updated_at"]) ?? started,
                       attempt: (r["run_attempt"] as? NSNumber)?.intValue ?? 1, url: (r["html_url"] as? String) ?? "")
        }
    }

    /// All repositories' runs, newest start first.
    public static func merge(_ runs: [Run]) -> [Run] {
        runs.sorted { $0.started != $1.started ? $0.started > $1.started : $0.repo < $1.repo }
    }

    /// Each workflow's newest run (per repository), newest first. Skipped runs say nothing about a workflow's health, so
    /// they count only when a workflow has nothing else.
    public static func latestPerWorkflow(_ runs: [Run]) -> [Run] {
        var best: [String: Run] = [:]
        for r in merge(runs) {
            let key = r.repo + "\u{1}" + (r.workflowID != 0 ? String(r.workflowID) : r.workflow)
            if let have = best[key] { if have.state == .skipped && r.state != .skipped { best[key] = r } }
            else { best[key] = r }
        }
        return merge(Array(best.values))
    }

    public struct Counts: Equatable, Sendable {
        public var passing = 0, failing = 0, running = 0, cancelled = 0, skipped = 0
        public init(passing: Int = 0, failing: Int = 0, running: Int = 0, cancelled: Int = 0, skipped: Int = 0) {
            self.passing = passing; self.failing = failing; self.running = running; self.cancelled = cancelled; self.skipped = skipped
        }
    }

    /// The states of each workflow's newest run, counted: a failure that was fixed by a later run no longer counts.
    public static func summary(_ runs: [Run]) -> Counts {
        var c = Counts()
        for r in latestPerWorkflow(runs) {
            switch r.state { case .passing: c.passing += 1; case .failing: c.failing += 1; case .running: c.running += 1
            case .cancelled: c.cancelled += 1; case .skipped: c.skipped += 1 }
        }
        return c
    }

    /// Per repository the worst state among its workflows' newest runs, worst first, then by name.
    public static func repoStates(_ runs: [Run]) -> [(repo: String, state: State)] {
        var worst: [String: State] = [:]
        for r in latestPerWorkflow(runs) where (worst[r.repo]?.weight ?? -1) < r.state.weight { worst[r.repo] = r.state }
        return worst.map { ($0.key, $0.value) }.sorted { $0.state.weight != $1.state.weight ? $0.state.weight > $1.state.weight : $0.repo < $1.repo }
    }

    /// The date for `created>=` in a runs request: `days` before `now`, in UTC.
    public static func since(days: Int, now: Date = Date()) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: now.addingTimeInterval(-Double(days) * 86400))
    }

    /// The next page's address in a `Link` header (`<…>; rel="next"`), if any.
    public static func nextLink(_ header: String?) -> URL? {
        guard let header else { return nil }
        for part in header.split(separator: ",") where part.contains("rel=\"next\"") {
            if let a = part.firstIndex(of: "<"), let b = part.firstIndex(of: ">"), a < b { return URL(string: String(part[part.index(after: a)..<b])) }
        }
        return nil
    }
}
