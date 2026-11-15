import Foundation
import UltraBarKit

/// Presence-aware screen for the bar, over ADB (2026-11-04). The bar's own protocol has no way to wake
/// its screen or change its timeout, so this uses the Android debug bridge: the bar must have "Wi-Fi ADB"
/// on in Developer options and `adb` must be installed on the Mac (android-platform-tools). Deckhand then
/// follows the SenseCube's presence events in the bar's log: while someone is at the desk the screen
/// timeout is parked at "never" (and a dozing screen is woken); after N minutes without anyone the
/// timeout is set back to N minutes, which switches the screen off. Nothing else is touched.
extension AppModel {
    static let barScreenNeverMs = 2_147_483_647
    static let senseLogTag = "QLinkSenseCube++++++++++"

    /// Event-driven since 2026-11-15: the log tail's presence lines wake the loop, the switch-off time is one timed
    /// wake-up, and the bar's screen state (`dumpsys power`, an adb process and a shell on the bar each time) is read
    /// only when it matters (someone arrived, the timeout is due, right after a change) and otherwise every two
    /// minutes as a safety net. Before, all of that ran every 15 s, day and night.
    func startPresence(settings: AppSettings) {
        presenceTask?.cancel(); presenceTask = nil
        presenceLog?.terminate(); presenceLog = nil
        guard settings.presenceWake else { update(\.presenceStatus, "Off."); return }
        guard let adb = AdbBridge.find() else { update(\.presenceStatus, "adb not found — install android-platform-tools (brew)."); return }
        presenceTask = Task { [weak self] in
            // Tails a crash or a forced quit left behind (child processes outlive Deckhand), each one a reader on the bar.
            await AdbBridge.endOrphanedTails(adb: adb, tag: Self.senseLogTag)
            var connectedTo: String?
            var parkedNever = false
            var wasPresent = false
            var screenCheckedAt = Date.distantPast
            while !Task.isCancelled {
                guard let self else { return }
                guard let ip = self.ipForSelected() else { self.update(\.presenceStatus, "No bar selected."); await self.presenceWake.sleep(15); continue }
                let bridge = AdbBridge(path: adb, ip: ip)
                // (Re)start the log tail when the bar's address changed or the logcat process died (the bar
                // rebooted, ADB dropped): a dead tail never reports presence again. Its exit wakes this loop.
                if connectedTo != ip || !(self.presenceLog?.isRunning ?? false) {
                    guard await bridge.connect() else {
                        self.update(\.presenceStatus, "The bar refuses the debug bridge. Turn on WiFi ADB in the bar's Developer options.")
                        connectedTo = nil; await Task.relaxedSleep(30); continue
                    }
                    connectedTo = ip
                    self.presenceLog?.terminate()
                    self.presenceLog = bridge.tailLog(tag: Self.senseLogTag, onExit: { [weak self] in
                        Task { @MainActor in self?.presenceWake.signal() }
                    }) { [weak self] line in
                        guard line.contains("onProximityTriggerSignalReport") else { return }
                        Task { @MainActor in
                            guard let self else { return }
                            // Only an arrival needs the loop at once; further lines just move the time on.
                            let arrived = self.lastPresenceAt.map { Date().timeIntervalSince($0) >= 90 } ?? true
                            self.lastPresenceAt = Date()
                            if arrived { self.presenceWake.signal() }
                        }
                    }
                }
                let minutes = max(1, settings.presenceSleepMinutes)
                let since = self.lastPresenceAt.map { Date().timeIntervalSince($0) }
                let present = (since ?? .infinity) < 90
                let timedOut = since.map { $0 > Double(minutes) * 60 } ?? false
                let checkDue = Date().timeIntervalSince(screenCheckedAt) >= (present ? 15 : 120)
                var awake = self.barScreenOn ?? true
                if present != wasPresent || (timedOut && parkedNever) || checkDue || self.barScreenOn == nil {
                    awake = await bridge.shell("dumpsys power | grep -m1 mWakefulness=").contains("Awake")
                    screenCheckedAt = Date()
                    self.update(\.barScreenOn, awake)
                }
                wasPresent = present
                if present {
                    if !awake { _ = await bridge.shell("input keyevent KEYCODE_WAKEUP"); self.say("Someone is at the desk — bar screen on."); self.update(\.barScreenOn, true) }
                    if !parkedNever {
                        _ = await bridge.shell("settings put system screen_off_timeout \(Self.barScreenNeverMs)"); parkedNever = true
                    }
                    self.update(\.presenceStatus, "Someone is here — screen stays on.")
                } else if timedOut {
                    if parkedNever || awake {
                        _ = await bridge.shell("settings put system screen_off_timeout \(minutes * 60_000)"); parkedNever = false
                        screenCheckedAt = .distantPast   // read the screen again on the next round
                    }
                    self.update(\.presenceStatus, "Nobody for over \(minutes) min — screen may sleep.")
                } else {
                    self.update(\.presenceStatus, since == nil ? "Watching the SenseCube for presence…" : "Nobody here — the screen switches off after \(minutes) min without anyone.")
                }
                // Until the next thing that can change the picture: someone counts as gone 90 s after the last line,
                // the timeout is restored at the switch-off time, and the screen is re-read every 15 s / 2 min.
                var next = present ? 15.0 : 120.0
                if let since {
                    if present { next = min(next, 90 - since) }
                    else if !timedOut || parkedNever { next = min(next, Double(minutes) * 60 - since) }
                }
                await self.presenceWake.sleep(max(1, next))
            }
        }
    }

    /// Restore the plain timeout when the feature is switched off or the app quits.
    func stopPresence(settings: AppSettings) {
        presenceTask?.cancel(); presenceTask = nil
        presenceLog?.terminate(); presenceLog = nil
        guard let adb = AdbBridge.find(), let ip = ipForSelected() else { return }
        let minutes = max(1, settings.presenceSleepMinutes)
        Task.detached { _ = await AdbBridge(path: adb, ip: ip).shell("settings put system screen_off_timeout \(minutes * 60_000)") }
    }
}

/// Thin `adb` wrapper: one device (ip:5555), short commands with a timeout, and a streaming logcat.
struct AdbBridge {
    let path: String
    let ip: String
    var device: String { "\(ip):5555" }

    static func find() -> String? {
        for p in ["/opt/homebrew/bin/adb", "/usr/local/bin/adb", "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb"] where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    func connect() async -> Bool {
        let out = await run(["connect", device], timeout: 8)
        return out.contains("connected to")
    }

    /// `device` when the bar accepted this Mac, `unauthorized` while the bar still shows its "Allow debugging?" prompt, else an error text.
    func state() async -> String {
        await run(["-s", device, "get-state"], timeout: 8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func install(apkPath: String, timeout: TimeInterval = 120) async -> String {
        await run(["-s", device, "install", "-r", apkPath], timeout: timeout)
    }

    /// `versionName` and `versionCode` of a package on the bar, or nil when it is not installed.
    func packageVersion(_ package: String) async -> (name: String, code: Int)? {
        let out = await shell("dumpsys package \(package) | grep -E 'versionCode=|versionName='")
        guard let c = out.range(of: #"versionCode=(\d+)"#, options: .regularExpression),
              let n = out.range(of: #"versionName=(\S+)"#, options: .regularExpression) else { return nil }
        let code = Int(out[c].dropFirst("versionCode=".count)) ?? 0
        return (String(out[n].dropFirst("versionName=".count)), code)
    }

    func uninstall(package: String) async -> String {
        await run(["-s", device, "uninstall", package], timeout: 60)
    }

    func shell(_ cmd: String) async -> String {
        await run(["-s", device, "shell", cmd], timeout: 10)
    }

    /// Serials of devices attached over USB (anything `adb devices` lists that is not an ip:port).
    static func usbSerials(adb path: String) async -> [String] {
        let out = await AdbBridge(path: path, ip: "").run(["devices"], timeout: 8)
        return out.split(separator: "\n").dropFirst().compactMap { line -> String? in
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard parts.count >= 2, parts[1] == "device", !parts[0].contains(":") else { return nil }
            return String(parts[0])
        }
    }

    /// `adb tcpip 5555` on the USB-attached device: the bar's adbd restarts listening on Wi-Fi (until the next reboot).
    static func enableTcpip(adb path: String, usbSerial: String) async -> String {
        await AdbBridge(path: path, ip: "").run(["-s", usbSerial, "tcpip", "5555"], timeout: 15)
    }

    /// Whether the bar keeps Wi-Fi ADB on across reboots. Two settings, both needed (verified 2026-11-06):
    /// `persist.adb.tcp.port=5555` makes adbd listen on Wi-Fi, and USB debugging (`adb_enabled=1`) makes Android
    /// start adbd at boot at all. With USB debugging off, the bar's Developer-options "WiFi ADB" switch only starts
    /// adbd until the next reboot, even with the port property set.
    func isPersistent() async -> Bool {
        let out = await shell("getprop persist.adb.tcp.port; settings get global adb_enabled")
        let lines = out.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.count >= 2 && lines[0] == "5555" && lines[1] == "1"
    }

    func makePersistent() async -> Bool {
        _ = await shell("setprop persist.adb.tcp.port 5555")
        // Switching USB debugging on restarts adbd, which drops this connection: reconnect before checking.
        _ = await shell("settings put global adb_enabled 1")
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        _ = await connect()
        return await isPersistent()
    }

    /// `adb logcat -s <tag>` as a long-running process; `onLine` and `onExit` run on a background queue.
    func tailLog(tag: String, onExit: (@Sendable () -> Void)? = nil, onLine: @escaping @Sendable (String) -> Void) -> Process? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-s", device, "logcat", "-T", "1", "-s", "\(tag):I"]
        if let onExit { p.terminationHandler = { _ in onExit() } }
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        final class Buf: @unchecked Sendable { var rest = Data() }
        let buf = Buf()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            buf.rest.append(d)
            while let nl = buf.rest.firstIndex(of: 10) {
                onLine(String(decoding: buf.rest[..<nl], as: UTF8.self)); buf.rest.removeSubrange(...nl)
            }
        }
        do { try p.run() } catch { return nil }
        return p
    }

    /// Ends `adb … logcat … -s <tag>` processes whose parent is gone (parent pid 1): tails an earlier Deckhand left
    /// running when it crashed or was killed (a normal quit ends its own, `AppDelegate.applicationWillTerminate`).
    /// Each one kept a logcat reader running on the bar and a stream open in the adb server.
    static func endOrphanedTails(adb: String, tag: String) async {
        let killed = await Task.detached(priority: .utility) { () -> Int in
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-Ao", "pid=,ppid=,command="]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return 0 }
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); p.waitUntilExit()
            var n = 0
            for line in out.split(separator: "\n") {
                let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard f.count == 3, f[1] == "1", let pid = Int32(f[0]), f[2].hasPrefix(adb), f[2].contains("logcat -T 1 -s \(tag)") else { continue }
                if kill(pid, SIGTERM) == 0 { n += 1 }
            }
            return n
        }.value
        if killed > 0 { WireLog.shared.event("presence: ended \(killed) adb logcat tail\(killed == 1 ? "" : "s") left over from an earlier run") }
    }

    private func run(_ args: [String], timeout: TimeInterval) async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
                let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
                do { try p.run() } catch { cont.resume(returning: ""); return }
                let deadline = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); deadline.cancel()
                cont.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }
}
