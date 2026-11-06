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
            // A sub-agent transcript (`subagents/`) always ends with the agent's final report, an
            // assistant turn without a tool call: it would count as "waiting for you" for 15 minutes.
            guard url.pathExtension == "jsonl", !url.path.contains("/subagents/"),
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

    /// Per-transcript tally: how far the file was read and what it contributed to today's tokens.
    private struct Tally { var offset: UInt64; var tokens: Int }
    private final class TallyBox: @unchecked Sendable {
        let lock = NSLock()
        var tallies: [String: Tally] = [:]
        var day: Date?
    }
    private static let box = TallyBox()

    /// Tokens used today and sessions active recently. Incremental since 2026-11-04: each transcript is
    /// read only past the point it was read before (the whole file once, then just what was appended),
    /// and only lines stamped today count. Before that, every pass re-read every file touched today —
    /// hundreds of MB every 2 s — which kept Deckhand at 30 % CPU, starved the Swift thread pool (the
    /// bar's GET_VOLUME waited over a second) and made the app's own window unresponsive.
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

        let box = Self.box
        box.lock.lock(); defer { box.lock.unlock() }
        if box.day != startOfDay { box.tallies = [:]; box.day = startOfDay }
        for case let url as URL in en {
            guard url.pathExtension == "jsonl" else { continue }
            anyFile = true
            let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mod = vals?.contentModificationDate ?? .distantPast
            // Sub-agent transcripts count towards today's tokens (real usage) but are not sessions.
            if !url.path.contains("/subagents/"), now.timeIntervalSince(mod) <= activeWindow { active += 1 }
            guard mod >= startOfDay else { continue }
            let size = UInt64(vals?.fileSize ?? 0)
            var t = box.tallies[url.path] ?? Tally(offset: 0, tokens: 0)
            if size < t.offset { t = Tally(offset: 0, tokens: 0) }   // rewritten or truncated: start over
            if size > t.offset {
                let (consumed, added) = tallyTokens(url, from: t.offset, since: startOfDay)
                t.offset += consumed; t.tokens += added
            }
            box.tallies[url.path] = t
            tokens += t.tokens
        }
        return Snapshot(activeSessions: active, todayTokens: tokens, hasData: anyFile, waitingForInput: waitingSessions())
    }

    /// Read `url` from `offset` in chunks, line by line; sum the usage of lines stamped on or after
    /// `since` (lines without a timestamp count). Returns the bytes consumed up to the last complete
    /// line (a partial last line is read again next time) and the tokens added.
    private static func tallyTokens(_ url: URL, from offset: UInt64, since: Date) -> (consumed: UInt64, tokens: Int) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return (0, 0) }
        defer { try? h.close() }
        guard (try? h.seek(toOffset: offset)) != nil else { return (0, 0) }
        var consumed: UInt64 = 0
        var tokens = 0
        var rest = Data()
        let needle = Data("\"usage\"".utf8)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter(); isoPlain.formatOptions = [.withInternetDateTime]
        while let chunk = try? h.read(upToCount: 4_000_000), !chunk.isEmpty {
            rest.append(chunk)
            var lineStart = rest.startIndex
            while let nl = rest[lineStart...].firstIndex(of: 10) {
                let line = rest[lineStart..<nl]
                consumed += UInt64(nl - lineStart + 1)
                lineStart = nl + 1
                guard line.range(of: needle) != nil,
                      let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let u = findUsage(obj) else { continue }
                if let ts = obj["timestamp"] as? String, let d = iso.date(from: ts) ?? isoPlain.date(from: ts), d < since { continue }
                // Exclude cache_read (cheap, counted every turn — would dwarf the rest).
                tokens += (u["input_tokens"] as? Int ?? 0) + (u["output_tokens"] as? Int ?? 0) + (u["cache_creation_input_tokens"] as? Int ?? 0)
            }
            rest = Data(rest[lineStart...])
        }
        return (consumed, tokens)
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
        public var project: String     // the session's own name (`/rename`, as in cmux) if it has one, else the cwd's last path component
        public var title: String       // Claude's title for the session, else the first user prompt, trimmed
        public var state: State
        public var lastAt: Date
        public var lastText: String    // last assistant text, trimmed
    }

    /// Session names per transcript: the newest `custom-title` (the name given with `/rename`, which cmux shows too)
    /// and `ai-title`. Found once by scanning the whole file, then kept up to date from each tail read.
    private static let titleLock = NSLock()
    nonisolated(unsafe) private static var titles: [String: (custom: String, ai: String)] = [:]

    private static func titleLines(_ text: Substring, into t: inout (custom: String, ai: String)) {
        for line in text.split(separator: "\n") where line.contains("-title\"") {
            guard let obj = parse(line) else { continue }
            if (obj["type"] as? String) == "custom-title", let v = obj["customTitle"] as? String, !v.isEmpty { t.custom = v }
            if (obj["type"] as? String) == "ai-title", let v = obj["aiTitle"] as? String, !v.isEmpty { t.ai = v }
        }
    }

    /// Sessions with a real message (yours or Claude's) within `window`, newest first. Reads the first 8 KB (cwd +
    /// first prompt) and the last 64 KB (state, last text, time of the last real message) of each transcript; the
    /// file's modification time alone is not enough, because idle sessions keep getting `system` entries.
    /// Sub-agent transcripts (in `subagents/`) are skipped.
    public static func sessions(window: TimeInterval = 3600) -> [Session] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let now = Date()
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter(); isoPlain.formatOptions = [.withInternetDateTime]
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
            let id = url.deletingPathExtension().lastPathComponent
            let tailText = String(decoding: tailData, as: UTF8.self)
            titleLock.lock(); var names = titles[id]; titleLock.unlock()
            if names == nil, let whole = try? String(contentsOf: url, encoding: .utf8) {
                var t = (custom: "", ai: ""); titleLines(Substring(whole), into: &t); names = t
            } else if var t = names { titleLines(Substring(tailText), into: &t); names = t }
            titleLock.lock(); titles[id] = names; titleLock.unlock()
            var state = Session.State.working, last = "", lastAt: Date?
            for line in tailText.split(separator: "\n").reversed() {
                guard let obj = parse(line), let type = obj["type"] as? String else { continue }
                if cwd.isEmpty, let c = obj["cwd"] as? String { cwd = c }
                if lastAt == nil, type == "user" || type == "assistant", let ts = obj["timestamp"] as? String {
                    lastAt = iso.date(from: ts) ?? isoPlain.date(from: ts)
                }
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
            let at = lastAt ?? mod
            guard now.timeIntervalSince(at) <= window else { continue }
            let folder = cwd.isEmpty ? url.deletingLastPathComponent().lastPathComponent.split(separator: "-").last.map(String.init) ?? "?" : (cwd as NSString).lastPathComponent
            let name = names?.custom ?? "", ai = names?.ai ?? ""
            out.append(Session(id: id, project: name.isEmpty ? folder : name, title: trim(ai.isEmpty ? title : ai, 70),
                               state: state, lastAt: at, lastText: trim(last, 140)))
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
