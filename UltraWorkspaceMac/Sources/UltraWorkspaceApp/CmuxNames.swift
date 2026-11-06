import Foundation

/// The names you gave your cmux workspaces, by working directory, so the Claude bar app can show a session under
/// the name you see in cmux ("Deckhand for UltrabarX") instead of its folder ("UltraWorkspace"). Read with cmux's
/// own CLI at its fixed path inside the app bundle (never `PATH`), at most every 30 s; empty when cmux is not
/// installed or not running. Only workspaces with a custom title count.
enum CmuxNames {
    static let cli = "/Applications/cmux.app/Contents/Resources/bin/cmux"
    nonisolated(unsafe) private static var cache: (at: Date, names: [String: String]) = (.distantPast, [:])
    private static let lock = NSLock()

    static func byDirectory() -> [String: String] {
        lock.lock(); let c = cache; lock.unlock()
        if Date().timeIntervalSince(c.at) < 30 { return c.names }
        let names = read()
        lock.lock(); cache = (Date(), names); lock.unlock()
        return names
    }

    private static func read() -> [String: String] {
        guard FileManager.default.isExecutableFile(atPath: cli) else { return [:] }
        var out: [String: String] = [:]
        for window in windows() {
            guard let data = run(["workspace", "list", "--window", window, "--json"]),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = obj["workspaces"] as? [[String: Any]] else { continue }
            for w in list where (w["has_custom_title"] as? Bool) == true {
                if let dir = w["current_directory"] as? String, let title = w["custom_title"] as? String, !title.isEmpty, out[dir] == nil {
                    out[dir] = title
                }
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
