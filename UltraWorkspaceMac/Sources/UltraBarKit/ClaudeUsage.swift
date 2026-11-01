import Foundation

/// Best-effort reader for Claude Code activity from `~/.claude/projects/*.jsonl`
/// transcripts: tokens used today and sessions active recently. Schema-tolerant.
public enum ClaudeUsage {
    public struct Snapshot: Sendable {
        public var activeSessions: Int
        public var todayTokens: Int
        public var hasData: Bool
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
        return Snapshot(activeSessions: active, todayTokens: tokens, hasData: anyFile)
    }

    private static func findUsage(_ obj: [String: Any]) -> [String: Any]? {
        if let u = obj["usage"] as? [String: Any] { return u }
        if let m = obj["message"] as? [String: Any], let u = m["usage"] as? [String: Any] { return u }
        return nil
    }

    /// Compact token count, e.g. "1.2M", "840K".
    public static func shortTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1000) }
        return "\(n)"
    }
}
