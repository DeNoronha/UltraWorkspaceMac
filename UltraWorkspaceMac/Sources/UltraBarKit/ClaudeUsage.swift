import Foundation

/// Best-effort reader for Claude Code activity from `~/.claude/projects/*.jsonl`
/// transcripts: tokens used today and sessions active recently. Schema-tolerant.
public enum ClaudeUsage {
    public struct Snapshot: Sendable {
        public var activeSessions: Int
        public var todayTokens: Int
        public var hasData: Bool
        /// Sessions whose last turn is an assistant message with no pending tool call: they wait for you.
        public var waitingForInput: Int = 0
    }

    /// Count recently touched sessions that are waiting for the user (cheap: reads the tail of each file).
    public static func waitingSessions(window: TimeInterval = 900) -> Int {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return 0 }
        let now = Date()
        var waiting = 0
        for case let url as URL in en {
            guard url.pathExtension == "jsonl",
                  let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  now.timeIntervalSince(mod) <= window else { continue }
            if isWaiting(url) { waiting += 1 }
        }
        return waiting
    }

    private static func isWaiting(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let tailLen: UInt64 = 64_000
        try? h.seek(toOffset: size > tailLen ? size - tailLen : 0)
        guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { return false }
        // Last line that is a user or assistant turn decides.
        for line in text.split(separator: "\n").reversed() {
            guard let d = line.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            if type == "user" { return false }                      // the user (or a tool result) spoke last → agent is working
            if type == "assistant" {
                let msg = obj["message"] as? [String: Any]
                let content = msg?["content"] as? [[String: Any]] ?? []
                let pendingTool = content.contains { ($0["type"] as? String) == "tool_use" }
                return !pendingTool                                   // ended its turn → waiting for input
            }
        }
        return false
    }

    public static func snapshot(activeWindow: TimeInterval = 300) -> Snapshot {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent(".claude/projects", isDirectory: true)
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return Snapshot(activeSessions: 0, todayTokens: 0, hasData: false)
        }
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let now = Date()
        var active = 0
        var tokens = 0
        var anyFile = false
        var filesScanned = 0

        for case let url as URL in en {
            guard url.pathExtension == "jsonl" else { continue }
            anyFile = true
            let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mod = vals?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(mod) <= activeWindow { active += 1 }
            // Only tally tokens for files touched today, and cap work.
            guard mod >= startOfDay, filesScanned < 80, (vals?.fileSize ?? 0) < 50_000_000 else { continue }
            filesScanned += 1
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            content.enumerateLines { line, _ in
                guard line.contains("\"usage\""),
                      let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                if let u = findUsage(obj) {
                    // Exclude cache_read (cheap, counted every turn — would dwarf the rest).
                    tokens += (u["input_tokens"] as? Int ?? 0)
                        + (u["output_tokens"] as? Int ?? 0)
                        + (u["cache_creation_input_tokens"] as? Int ?? 0)
                }
            }
        }
        return Snapshot(activeSessions: active, todayTokens: tokens, hasData: anyFile, waitingForInput: waitingSessions())
    }

    private static func findUsage(_ obj: [String: Any]) -> [String: Any]? {
        if let u = obj["usage"] as? [String: Any] { return u }
        if let m = obj["message"] as? [String: Any], let u = m["usage"] as? [String: Any] { return u }
        return nil
    }

    /// One Claude Code session for the bar's Claude page (2026-11-04): which terminal needs you.
    public struct Session: Sendable, Identifiable {
        public enum State: String, Sendable { case working, waiting, question }
        public var id: String          // session file name
        public var project: String     // last path component of the session's cwd
        public var title: String       // first user prompt, trimmed
        public var state: State
        public var lastAt: Date
        public var lastText: String    // last assistant text, trimmed
    }

    /// Sessions touched within `window`, newest first. Reads the first 8 KB (cwd + first prompt) and the
    /// last 64 KB (state + last text) of each transcript; sub-agent transcripts (in `subagents/`) are skipped.
    public static func sessions(window: TimeInterval = 3600) -> [Session] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let now = Date()
        var out: [Session] = []
        for case let url as URL in en {
            guard url.pathExtension == "jsonl", !url.path.contains("/subagents/"),
                  let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  now.timeIntervalSince(mod) <= window else { continue }
            guard let h = try? FileHandle(forReadingFrom: url) else { continue }
            let headData = (try? h.read(upToCount: 8_000)) ?? Data()
            let size = (try? h.seekToEnd()) ?? 0
            try? h.seek(toOffset: size > 64_000 ? size - 64_000 : 0)
            let tailData = (try? h.readToEnd()) ?? Data()
            try? h.close()
            var cwd = "", title = ""
            for line in String(decoding: headData, as: UTF8.self).split(separator: "\n") {
                guard let obj = parse(line) else { continue }
                if cwd.isEmpty, let c = obj["cwd"] as? String { cwd = c }
                if title.isEmpty, (obj["type"] as? String) == "user", (obj["isMeta"] as? Bool) != true, let t = text(of: obj), !t.hasPrefix("<") { title = t }
                if !cwd.isEmpty, !title.isEmpty { break }
            }
            var state = Session.State.working, last = ""
            for line in String(decoding: tailData, as: UTF8.self).split(separator: "\n").reversed() {
                guard let obj = parse(line), let type = obj["type"] as? String else { continue }
                if cwd.isEmpty, let c = obj["cwd"] as? String { cwd = c }
                if type == "user" { state = .working; break }
                if type == "assistant" {
                    let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                    let tools = content.compactMap { ($0["type"] as? String) == "tool_use" ? $0["name"] as? String : nil }
                    if tools.contains("AskUserQuestion") { state = .question }
                    else if tools.isEmpty { state = .waiting }
                    else { state = .working }
                    last = content.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
                    break
                }
            }
            let project = cwd.isEmpty ? url.deletingLastPathComponent().lastPathComponent.split(separator: "-").last.map(String.init) ?? "?" : (cwd as NSString).lastPathComponent
            out.append(Session(id: url.deletingPathExtension().lastPathComponent, project: project, title: trim(title, 70),
                               state: state, lastAt: mod, lastText: trim(last, 140)))
        }
        return out.sorted { $0.lastAt > $1.lastAt }
    }

    private static func parse(_ line: Substring) -> [String: Any]? {
        guard let d = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }
    private static func text(of obj: [String: Any]) -> String? {
        let m = obj["message"] as? [String: Any]
        if let s = m?["content"] as? String { return s }
        if let arr = m?["content"] as? [[String: Any]] {
            let t = arr.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
            return t.isEmpty ? nil : t
        }
        return nil
    }
    private static func trim(_ s: String, _ n: Int) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return one.count > n ? String(one.prefix(n - 1)) + "…" : one
    }

    /// Compact token count, e.g. "1.2M", "840K".
    public static func shortTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1000) }
        return "\(n)"
    }
}
