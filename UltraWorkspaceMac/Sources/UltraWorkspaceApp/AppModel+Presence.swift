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

    func startPresence(settings: AppSettings) {
        presenceTask?.cancel(); presenceTask = nil
        presenceLog?.terminate(); presenceLog = nil
        guard settings.presenceWake else { presenceStatus = "Off."; return }
        guard let adb = AdbBridge.find() else { presenceStatus = "adb not found — install android-platform-tools (brew)."; return }
        presenceTask = Task { [weak self] in
            var connectedTo: String?
            var parkedNever = false
            while !Task.isCancelled {
                guard let self else { return }
                guard let ip = self.ipForSelected() else { self.presenceStatus = "No bar selected."; try? await Task.sleep(nanoseconds: 15_000_000_000); continue }
                let bridge = AdbBridge(path: adb, ip: ip)
                // (Re)start the log tail when the bar's address changed or the logcat process died (the bar
                // rebooted, ADB dropped): a dead tail never reports presence again.
                if connectedTo != ip || !(self.presenceLog?.isRunning ?? false) {
                    guard await bridge.connect() else {
                        self.presenceStatus = "Bar refuses ADB — turn Wi-Fi ADB on in the bar's Developer options."
                        connectedTo = nil; try? await Task.sleep(nanoseconds: 30_000_000_000); continue
                    }
                    connectedTo = ip
                    self.presenceLog?.terminate()
                    self.presenceLog = bridge.tailLog(tag: Self.senseLogTag) { [weak self] line in
                        guard line.contains("onProximityTriggerSignalReport") else { return }
                        Task { @MainActor in self?.lastPresenceAt = Date() }
                    }
                }
                let minutes = max(1, settings.presenceSleepMinutes)
                let since = self.lastPresenceAt.map { Date().timeIntervalSince($0) }
                let present = (since ?? .infinity) < 90
                let awake = await bridge.shell("dumpsys power | grep -m1 mWakefulness=").contains("Awake")
                self.barScreenOn = awake
                if present {
                    if !awake { _ = await bridge.shell("input keyevent KEYCODE_WAKEUP"); self.say("Someone is at the desk — bar screen on.") }
                    if !parkedNever {
                        _ = await bridge.shell("settings put system screen_off_timeout \(Self.barScreenNeverMs)"); parkedNever = true
                    }
                    self.presenceStatus = "Someone is here — screen stays on."
                } else if let since, since > Double(minutes) * 60 {
                    if parkedNever || awake {
                        _ = await bridge.shell("settings put system screen_off_timeout \(minutes * 60_000)"); parkedNever = false
                    }
                    self.presenceStatus = "Nobody for \(Int(since / 60)) min — screen may sleep."
                } else {
                    self.presenceStatus = since == nil ? "Watching the SenseCube for presence…" : "Nobody for \(Int(since!)) s."
                }
                try? await Task.sleep(nanoseconds: 15_000_000_000)
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

    /// Whether the bar keeps Wi-Fi ADB on across reboots (`persist.adb.tcp.port`).
    func isPersistent() async -> Bool {
        (await shell("getprop persist.adb.tcp.port")).trimmingCharacters(in: .whitespacesAndNewlines) == "5555"
    }

    func makePersistent() async -> Bool {
        _ = await shell("setprop persist.adb.tcp.port 5555")
        return await isPersistent()
    }

    /// `adb logcat -s <tag>` as a long-running process; `onLine` runs on a background queue.
    func tailLog(tag: String, onLine: @escaping @Sendable (String) -> Void) -> Process? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-s", device, "logcat", "-T", "1", "-s", "\(tag):I"]
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
