import Foundation

/// The user's open Linear issues, through Linear's GraphQL API with a personal API key
/// (Linear → Settings → Security & access → Personal API keys). Read-only: one query.
public enum LinearTasks {
    public struct Issue: Sendable {
        /// Linear's internal id (UUID), needed to change the issue.
        public var id: String
        public var identifier: String
        public var title: String
        /// 0 none, 1 urgent, 2 high, 3 medium, 4 low (Linear's scale).
        public var priority: Int
        public var priorityLabel: String
        public var dueDate: String?      // yyyy-MM-dd
        public var state: String
        public var stateType: String     // triage, backlog, unstarted, started, completed, canceled
        public var stateColor: String
        public var project: String?
        public var team: String
        public var url: String
    }

    public struct Result: Sendable { public var me: String; public var issues: [Issue] }

    static let query = """
    query Deckhand { viewer { name assignedIssues(first: 50, filter: { state: { type: { nin: ["completed", "canceled"] } } }, orderBy: updatedAt) {
      nodes { id identifier title priority priorityLabel dueDate url state { name type color } project { name } team { key } } } } }
    """

    /// One GraphQL call; returns the `data` object or throws Linear's first error message.
    static func call(apiKey: String, query: String, variables: [String: Any] = [:]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.linear.app/graphql")!)
        req.httpMethod = "POST"; req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 400 {
            throw NSError(domain: "Linear", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Linear rejected the API key (HTTP \(http.statusCode))."])
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw URLError(.cannotParseResponse) }
        if let errors = obj["errors"] as? [[String: Any]], let msg = errors.first?["message"] as? String {
            throw NSError(domain: "Linear", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return (obj["data"] as? [String: Any]) ?? [:]
    }

    /// Mark an issue done: move it to its team's first "completed" workflow state (Linear's own Done).
    public static func complete(apiKey: String, issueID: String) async throws {
        let q = """
        query DeckhandStates($id: String!) { issue(id: $id) { team { states(filter: { type: { eq: "completed" } }) { nodes { id name position } } } } }
        """
        let d = try await call(apiKey: apiKey, query: q, variables: ["id": issueID])
        let nodes = ((((d["issue"] as? [String: Any])?["team"] as? [String: Any])?["states"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        guard let state = nodes.min(by: { (($0["position"] as? Double) ?? 0) < (($1["position"] as? Double) ?? 0) }), let stateID = state["id"] as? String else {
            throw NSError(domain: "Linear", code: 2, userInfo: [NSLocalizedDescriptionKey: "The issue's team has no \"completed\" state."])
        }
        let m = "mutation DeckhandDone($id: String!, $state: String!) { issueUpdate(id: $id, input: { stateId: $state }) { success } }"
        let r = try await call(apiKey: apiKey, query: m, variables: ["id": issueID, "state": stateID])
        guard ((r["issueUpdate"] as? [String: Any])?["success"] as? Bool) == true else {
            throw NSError(domain: "Linear", code: 3, userInfo: [NSLocalizedDescriptionKey: "Linear did not accept the change."])
        }
    }

    public static func fetch(apiKey: String) async throws -> Result {
        let obj = try await call(apiKey: apiKey, query: query)
        let viewer = obj["viewer"] as? [String: Any]
        let nodes = ((viewer?["assignedIssues"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        let issues = nodes.map { n -> Issue in
            let st = n["state"] as? [String: Any]
            return Issue(id: (n["id"] as? String) ?? "", identifier: (n["identifier"] as? String) ?? "", title: (n["title"] as? String) ?? "",
                         priority: (n["priority"] as? Int) ?? 0, priorityLabel: (n["priorityLabel"] as? String) ?? "",
                         dueDate: n["dueDate"] as? String, state: (st?["name"] as? String) ?? "", stateType: (st?["type"] as? String) ?? "",
                         stateColor: (st?["color"] as? String) ?? "#8b94a6", project: (n["project"] as? [String: Any])?["name"] as? String,
                         team: ((n["team"] as? [String: Any])?["key"] as? String) ?? "", url: (n["url"] as? String) ?? "")
        }
        return Result(me: (viewer?["name"] as? String) ?? "", issues: sorted(issues))
    }

    /// Started work first, then by priority (urgent first; "no priority" last), then by due date.
    public static func sorted(_ issues: [Issue]) -> [Issue] {
        func rank(_ p: Int) -> Int { p == 0 ? 5 : p }
        return issues.sorted {
            if ($0.stateType == "started") != ($1.stateType == "started") { return $0.stateType == "started" }
            if rank($0.priority) != rank($1.priority) { return rank($0.priority) < rank($1.priority) }
            return ($0.dueDate ?? "9999") < ($1.dueDate ?? "9999")
        }
    }
}
