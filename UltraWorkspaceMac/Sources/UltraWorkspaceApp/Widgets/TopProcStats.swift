import Foundation

/// Reads the top CPU-consuming processes via the system `/bin/ps` binary.
/// No helper app, no sudo — `/bin/ps` is a built-in system tool.
enum TopProcStats {
    struct Proc: Sendable {
        var name: String
        var cpu: Double  // percent
    }

    /// Returns the top `n` processes by CPU usage (descending).
    /// Defensive: returns [] on any error.
    static func top(_ n: Int = 3) -> [Proc] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        // -A: all processes; -c: comm without full path/args; -e: environment off (kept per spec);
        // -o pcpu,comm: columns; -r: sort by CPU usage.
        proc.arguments = ["-Aceo", "pcpu,comm", "-r"]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()

        do {
            try proc.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var result: [Proc] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Split off the first whitespace-delimited token (%CPU); the rest is the name.
            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }

            let cpuToken = String(parts[0])
            let name = String(parts[1]).trimmingCharacters(in: .whitespaces)

            // Skip the header line ("%CPU COMM") — first token won't parse as a Double.
            guard let cpu = Double(cpuToken) else { continue }
            if name.isEmpty { continue }

            result.append(Proc(name: name, cpu: cpu))
            if result.count >= n { break }
        }
        return result
    }
}
