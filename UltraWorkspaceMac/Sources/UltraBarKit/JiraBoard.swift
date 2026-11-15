import Foundation

/// The pure parts of the Jira Board bar app: a board's column configuration (`GET /rest/agile/1.0/board/{id}/configuration`,
/// `columnConfig.columns`) and its issues (`GET /rest/agile/1.0/board/{id}/issue`, `issues`) → the columns the bar shows,
/// each with its number of cards and the top cards, the user's own first.
public enum JiraBoard {
    public struct Card: Equatable, Sendable {
        public var key: String
        public var summary: String
        public var mine: Bool
        /// The assignee's initials ("" when nobody is assigned).
        public var who: String
        public var priority: String
        public var type: String
        public var updated: Date
        public init(key: String, summary: String, mine: Bool, who: String, priority: String, type: String, updated: Date) {
            self.key = key; self.summary = summary; self.mine = mine; self.who = who; self.priority = priority; self.type = type; self.updated = updated
        }
    }

    public struct Column: Equatable, Sendable {
        public var name: String
        public var count: Int
        public var mine: Int
        /// The board's last column (Done, usually): only its count and newest cards matter.
        public var done: Bool
        public var cards: [Card]
        public init(name: String, count: Int, mine: Int, done: Bool, cards: [Card]) {
            self.name = name; self.count = count; self.mine = mine; self.done = done; self.cards = cards
        }
    }

    /// Cards kept per column, and for the done column.
    public static let topCards = 8
    public static let doneCards = 2

    /// Jira's priority names, most urgent first; another name (a custom scheme) sorts with Medium.
    public static func rank(_ priority: String) -> Int {
        switch priority.lowercased() {
        case "highest", "blocker": return 0
        case "high", "critical": return 1
        case "low", "minor": return 3
        case "lowest", "trivial": return 4
        default: return 2
        }
    }

    /// "Ada Lovelace" → "AL", "ada" → "A", "" → "".
    public static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "." }).filter { $0.first?.isLetter == true }
        guard let first = words.first?.first else { return "" }
        if words.count == 1 { return String(first).uppercased() }
        return (String(first) + String(words.last!.first!)).uppercased()
    }

    /// Jira's timestamps ("2026-11-14T10:22:33.123+0100"), with or without milliseconds.
    public static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ"] {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return ISO8601DateFormatter().date(from: s)
    }

    /// The columns of the board, in its order. A status that is on no column (not on the board) is left out, and so is a
    /// column without statuses. Cards: the user's own first, then by priority, then the most recently updated; at most
    /// `topCards`. The last column, when there are at least two, is the done column: its count and the `doneCards` newest.
    /// `onlyMine` keeps only the user's own cards, counts included.
    public static func columns(config: [[String: Any]], issues: [[String: Any]], me: String, onlyMine: Bool = false) -> [Column] {
        var names: [String] = []
        var columnOf: [String: Int] = [:]
        for col in config {
            let ids = ((col["statuses"] as? [[String: Any]]) ?? []).compactMap { s -> String? in
                if let id = s["id"] as? String { return id }
                return (s["id"] as? NSNumber)?.stringValue
            }
            guard !ids.isEmpty else { continue }
            for id in ids where columnOf[id] == nil { columnOf[id] = names.count }
            names.append((col["name"] as? String) ?? "Column")
        }
        var cards = Array(repeating: [Card](), count: names.count)
        for issue in issues {
            let f = (issue["fields"] as? [String: Any]) ?? [:]
            let status = (f["status"] as? [String: Any]) ?? [:]
            let sid = (status["id"] as? String) ?? (status["id"] as? NSNumber)?.stringValue ?? ""
            guard let i = columnOf[sid] else { continue }
            let assignee = f["assignee"] as? [String: Any]
            let mine = !me.isEmpty && (assignee?["accountId"] as? String) == me
            if onlyMine && !mine { continue }
            let summary = ((f["summary"] as? String) ?? "").split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            cards[i].append(Card(key: (issue["key"] as? String) ?? "", summary: summary, mine: mine,
                                 who: initials((assignee?["displayName"] as? String) ?? ""),
                                 priority: ((f["priority"] as? [String: Any])?["name"] as? String) ?? "",
                                 type: ((f["issuetype"] as? [String: Any])?["name"] as? String) ?? "",
                                 updated: date(f["updated"]) ?? .distantPast))
        }
        return names.indices.map { i in
            let all = cards[i]
            let done = names.count >= 2 && i == names.count - 1
            let sorted = done
                ? all.sorted { $0.updated != $1.updated ? $0.updated > $1.updated : $0.key < $1.key }
                : all.sorted { a, b in
                    if a.mine != b.mine { return a.mine }
                    let ra = rank(a.priority), rb = rank(b.priority)
                    if ra != rb { return ra < rb }
                    if a.updated != b.updated { return a.updated > b.updated }
                    return a.key < b.key
                }
            return Column(name: names[i], count: all.count, mine: all.filter(\.mine).count, done: done,
                          cards: Array(sorted.prefix(done ? doneCards : topCards)))
        }
    }

    /// What the user typed as the site → the host Deckhand talks to ("https://acme.atlassian.net/jira/…" → "acme.atlassian.net"),
    /// or nil when it is not a plain host name under atlassian.net (Jira Cloud's API is always there): the e-mail and
    /// token never go to a half-typed or mistyped address.
    public static func host(_ site: String) -> String? {
        var s = site.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for p in ["https://", "http://"] where s.hasPrefix(p) { s = String(s.dropFirst(p.count)) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard s.hasSuffix(".atlassian.net"), s.count > ".atlassian.net".count, !s.hasPrefix("."), !s.hasPrefix("-"), !s.contains(".."),
              s.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return s
    }
}
