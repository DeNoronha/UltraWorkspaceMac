import Foundation

/// The cmux workspaces that are open, with the names you gave them, so the Claude bar app can show every open
/// session under the name you see in cmux ("Deckhand for UltrabarX") instead of its folder ("UltraWorkspace").
/// Read with cmux's own CLI at its fixed path inside the app bundle (never `PATH`), at most every 30 s; empty when
/// cmux is not installed or not running, and the Claude app then falls back to the sessions of the last hour.
enum CmuxNames {
    struct Workspace: Sendable { let directory: String; let title: String?; let ref: String }
    static let cli = "/Applications/cmux.app/Contents/Resources/bin/cmux"
    nonisolated(unsafe) private static var cache: (at: Date, list: [Workspace]) = (.distantPast, [])
    private static let lock = NSLock()

    /// The open workspaces in cmux's order (every window), each directory once.
    static func workspaces() -> [Workspace] {
        lock.lock(); let c = cache; lock.unlock()
        if Date().timeIntervalSince(c.at) < 30 { return c.list }
        let list = read()
        lock.lock(); cache = (Date(), list); lock.unlock()
        return list
    }

    nonisolated(unsafe) private static var statusCache: (at: Date, byDir: [String: String]) = (.distantPast, [:])

    /// What cmux's sidebar says about Claude Code in each workspace, by directory: "running", "waiting" or "idle"
    /// (`cmux sidebar-state`, the `claude_code=` line). Read at most every 5 s, about 150 ms per workspace.
    static func claudeStatus() -> [String: String] {
        lock.lock(); let c = statusCache; lock.unlock()
        if Date().timeIntervalSince(c.at) < 5 { return c.byDir }
        var out: [String: String] = [:]
        for w in workspaces() where !w.ref.isEmpty {
            guard let data = run(["sidebar-state", "--workspace", w.ref]) else { continue }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("claude_code=") else { continue }
                let value = t.dropFirst("claude_code=".count).split(separator: " ").first.map { $0.lowercased() } ?? ""
                if ["running", "waiting", "idle"].contains(value) { out[w.directory] = value }
            }
        }
        lock.lock(); statusCache = (Date(), out); lock.unlock()
        return out
    }

    /// Custom workspace titles by directory.
    static func byDirectory() -> [String: String] {
        var out: [String: String] = [:]
        for w in workspaces() { if let t = w.title, out[w.directory] == nil { out[w.directory] = t } }
        return out
    }

    private static func read() -> [Workspace] {
        guard FileManager.default.isExecutableFile(atPath: cli) else { return [] }
        var out: [Workspace] = [], seen = Set<String>()
        for window in windows() {
            guard let data = run(["workspace", "list", "--window", window, "--json"]),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = obj["workspaces"] as? [[String: Any]] else { continue }
            for w in list {
                guard let dir = w["current_directory"] as? String, !dir.isEmpty, seen.insert(dir).inserted else { continue }
                let title = (w["has_custom_title"] as? Bool) == true ? (w["custom_title"] as? String).flatMap { $0.isEmpty ? nil : $0 } : nil
                out.append(Workspace(directory: dir, title: title, ref: (w["ref"] as? String) ?? ""))
            }
        }
        return out
    }

    /// Window ids from `cmux list-windows` ("* 0: <uuid> selected_workspace=… workspaces=7").
    private static func windows() -> [String] {
        guard let data = run(["list-windows"]) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            line.split(separator: " ").first { $0.count == 36 && $0.filter { $0 == "-" }.count == 4 }.map(String.init)
        }
    }

    private static func run(_ args: [String]) -> Data? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: cli); p.arguments = args
        var env = ProcessInfo.processInfo.environment; env["CMUX_QUIET"] = "1"; p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning, Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return p.terminationStatus == 0 ? data : nil
    }
}
