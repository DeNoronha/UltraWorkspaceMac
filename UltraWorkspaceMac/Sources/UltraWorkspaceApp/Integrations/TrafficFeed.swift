import Foundation
import AppKit
import Darwin
import UltraBarKit

/// The Traffic bar app's data: this Mac's network traffic, in the spirit of Sniffnet but without capturing packets.
/// While the app is on the bar Deckhand reads the interface counters every 5 seconds (the rate chart) and runs macOS's
/// own `nettop` every 10 seconds for the bytes per app and per connection (no root, no packet contents), then names the
/// remote hosts with reverse DNS on this Mac's resolver and the services by port. Nothing leaves the Mac except those
/// lookups; the app asks for `/traffic/data.json`. Kept in memory only, for at most the chosen window.
@MainActor
final class TrafficFeed: ObservableObject {
    @Published private(set) var lastError: String?
    @Published private(set) var updatedAt: Date?

    private struct Bucket { let at: Date; var hosts: [String: (UInt64, UInt64)]; var services: [String: (UInt64, UInt64)]; var programs: [String: (UInt64, UInt64)] }
    private let stats = NetworkStats()
    private var rates: [(at: Date, down: Double, up: Double)] = []
    private var buckets: [Bucket] = []
    private var prevConns: [String: (UInt64, UInt64)]?
    private var connHost: [String: String] = [:]
    private var names: [String: String] = [:]          // ip → domain (or the ip when it has no name)
    private var resolving: Set<String> = []
    private var appNames: [Int: String] = [:]
    private var tick = 0
    private var window: () -> Int = { 10 }
    private var loop: Task<Void, Never>?
    private let wake = WakeSignal()

    func start(window: @escaping @MainActor () -> Int, wanted: @escaping @MainActor () -> Bool) {
        self.window = window
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let active = wanted()
                if active { await self.step() } else { self.reset() }
                await self.wake.wait(active ? 5 : 600) { wanted() != active }
            }
        }
    }
    func stop() { loop?.cancel(); loop = nil }
    func poke() { wake.signal() }

    /// Off the bar: forget the samples, so the next start does not count the time in between as one burst.
    private func reset() {
        guard prevConns != nil || !rates.isEmpty else { return }
        prevConns = nil; rates = []; buckets = []; _ = stats.sample(); tick = 0
    }

    private func step() async {
        let now = Date()
        let s = stats.sample()
        if tick > 0 { rates.append((now, s.downBytesPerSec, s.upBytesPerSec)) }
        let keep = Double(max(1, window()) * 60)
        rates.removeAll { now.timeIntervalSince($0.at) > keep }
        if tick % 2 == 0 { await sampleNettop(now) }
        buckets.removeAll { now.timeIntervalSince($0.at) > keep }
        tick += 1
        updatedAt = now
    }

    private func sampleNettop(_ now: Date) async {
        let text = await Task.detached(priority: .utility) { Self.runNettop() }.value
        guard let text else { lastError = "nettop did not answer."; return }
        lastError = nil
        let procs = Traffic.parse(text)
        // Everything is counted per connection, apps included: a process's own counter covers its whole life, and
        // nettop lists a process only while it has sockets, so one that comes back would count everything at once.
        // Loopback (this Mac talking to itself) is left out, as a capture on the network interface would.
        var conns: [String: (UInt64, UInt64)] = [:]
        var connService: [String: String] = [:], connPid: [String: Traffic.Process] = [:]
        for p in procs {
            for c in p.connections where !Traffic.isLoopback(c.remoteIP) {
                let k = "\(p.pid) " + c.key
                conns[k] = (c.bytesIn, c.bytesOut)
                connHost[k] = c.remoteIP
                connPid[k] = p
                connService[k] = Traffic.service(local: c.localPort, remote: c.remotePort, name: Self.serviceName, proto: c.proto)
            }
        }
        defer { prevConns = conns; connHost = connHost.filter { conns[$0.key] != nil } }
        guard let pc = prevConns else { return }     // the first sample is the baseline
        var b = Bucket(at: now, hosts: [:], services: [:], programs: [:])
        for (k, d) in Traffic.delta(conns, previous: pc) {
            if let ip = connHost[k] { b.hosts[ip, default: (0, 0)].0 += d.0; b.hosts[ip, default: (0, 0)].1 += d.1 }
            let svc = connService[k] ?? "?"
            b.services[svc, default: (0, 0)].0 += d.0; b.services[svc, default: (0, 0)].1 += d.1
            if let p = connPid[k] {
                let name = appName(p)
                b.programs[name, default: (0, 0)].0 += d.0; b.programs[name, default: (0, 0)].1 += d.1
            }
        }
        buckets.append(b)
        resolve(Array(b.hosts.keys))
    }

    nonisolated private static func runNettop() -> String? {
        let p = Foundation.Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        p.arguments = ["-L", "1", "-x", "-n", "-J", "bytes_in,bytes_out"]
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }

    nonisolated private static func serviceName(_ port: Int, _ proto: String) -> String? {
        guard let s = getservbyport(Int32(UInt16(port).bigEndian), proto), let n = s.pointee.s_name else { return nil }
        return String(cString: n)
    }

    /// The app a process belongs to: the running app's name, else the outermost .app in its path (Chrome's helpers →
    /// Google Chrome), else nettop's (shortened) name.
    private func appName(_ p: Traffic.Process) -> String {
        if p.pid == 0 { return "macOS" }
        if let n = appNames[p.pid] { return n }
        var name = NSRunningApplication(processIdentifier: pid_t(p.pid))?.localizedName
        if name == nil {
            var buf = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(Int32(p.pid), &buf, UInt32(buf.count)) > 0 { name = Traffic.appName(path: String(cString: buf)) }
        }
        let n = name ?? p.name
        if appNames.count > 2000 { appNames.removeAll() }
        appNames[p.pid] = n
        return n
    }

    /// Reverse DNS for new hosts, a few at a time, on this Mac's own resolver; a host without a name keeps its address.
    private func resolve(_ ips: [String]) {
        let todo = ips.filter { names[$0] == nil && !resolving.contains($0) }.prefix(12)
        guard !todo.isEmpty else { return }
        resolving.formUnion(todo)
        Task.detached(priority: .utility) { [weak self] in
            var found: [String: String] = [:]
            for ip in todo { found[ip] = Self.reverse(ip).map(Traffic.domain) ?? ip }
            await MainActor.run { [found] in
                guard let self else { return }
                if self.names.count > 3000 { self.names.removeAll() }
                self.names.merge(found) { $1 }
                self.resolving.subtract(found.keys)
            }
        }
    }

    nonisolated private static func reverse(_ ip: String) -> String? {
        var hints = addrinfo(); hints.ai_flags = AI_NUMERICHOST
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(ip, nil, &hints, &res) == 0, let r = res else { return nil }
        defer { freeaddrinfo(res) }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(r.pointee.ai_addr, r.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NAMEREQD) == 0 else { return nil }
        return String(cString: host)
    }

    // MARK: what the bar gets

    func snapshot() -> [String: Any] {
        var out: [String: Any] = ["at": Int(Date().timeIntervalSince1970), "window": window()]
        if let e = lastError { out["error"] = e }
        guard !rates.isEmpty || !buckets.isEmpty else { out["warming"] = true; return out }
        if let r = rates.last { out["rate"] = ["down": r.down, "up": r.up] }
        out["chart"] = ["down": rates.map { Int($0.down) }, "up": rates.map { Int($0.up) }, "from": Int(rates.first?.at.timeIntervalSince1970 ?? 0)]
        func sum(_ pick: (Bucket) -> [String: (UInt64, UInt64)]) -> [(String, UInt64, UInt64)] {
            var t: [String: (UInt64, UInt64)] = [:]
            for b in buckets { for (k, v) in pick(b) { t[k, default: (0, 0)].0 += v.0; t[k, default: (0, 0)].1 += v.1 } }
            return t.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.1 + $0.2 > $1.1 + $1.2 }
        }
        // Hosts by name: several addresses of zoom.us are one line.
        var hosts: [String: (UInt64, UInt64, Bool)] = [:]
        for (ip, i, o) in sum(\.hosts) {
            let n = names[ip] ?? ip
            hosts[n, default: (0, 0, Traffic.isLocal(ip))].0 += i; hosts[n, default: (0, 0, Traffic.isLocal(ip))].1 += o
        }
        out["hosts"] = hosts.sorted { $0.value.0 + $0.value.1 > $1.value.0 + $1.value.1 }.prefix(8)
            .map { ["name": $0.key, "in": $0.value.0, "out": $0.value.1, "local": $0.value.2] }
        out["services"] = sum(\.services).prefix(8).map { ["name": $0.0, "in": $0.1, "out": $0.2] }
        out["programs"] = sum(\.programs).prefix(8).map { ["name": $0.0, "in": $0.1, "out": $0.2] }
        let totIn = rates.count > 1 ? zip(rates.dropFirst(), rates).reduce(0.0) { $0 + $1.0.down * $1.0.at.timeIntervalSince($1.1.at) } : 0
        let totOut = rates.count > 1 ? zip(rates.dropFirst(), rates).reduce(0.0) { $0 + $1.0.up * $1.0.at.timeIntervalSince($1.1.at) } : 0
        out["total"] = ["in": Int(totIn), "out": Int(totOut)]
        out["since"] = Int((rates.first?.at ?? Date()).timeIntervalSince1970)
        return out
    }

    /// Deckhand Home's line: the current rate down and up.
    func homeLine() -> (line: String, tone: String)? {
        guard let r = rates.last else { return nil }
        return ("↓ \(ByteFormat.perSec(r.down))  ↑ \(ByteFormat.perSec(r.up))", r.down + r.up > 1_000_000 ? "live" : "")
    }
}
