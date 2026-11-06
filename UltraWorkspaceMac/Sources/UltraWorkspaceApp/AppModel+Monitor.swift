import Foundation
import UltraBarKit

/// The bar's Monitor app (android/DeckhandMonitor) opens a full-screen page that this Mac serves:
/// `GET /monitor` (the page) and `GET /monitor/stats.json` (one sample per second). The app finds
/// the page through a UDP beacon this Mac sends every 5 s while the Monitor is on (2026-11-04).
extension AppModel {
    nonisolated static let monitorPackage = "nl.denoronha.deckhand.monitor"

    func startMonitor(settings: AppSettings) {
        monitorTask?.cancel(); monitorTask = nil
        guard settings.monitorServe else { if MonitorServer.shared.isRunning { MonitorServer.shared.stop() }; barPages.stop(); monitorURL = nil; return }
        let sys = SystemStats(), net = NetworkStats()
        _ = sys.sample(); _ = net.sample()
        let host = Host.current().localizedName ?? "Mac"
        let page = Self.monitorPage
        barPages.start(model: self, settings: settings)
        let pages = barPages
        MonitorServer.shared.setActionRoute { [weak self] path in
            guard let self else { return nil }
            return pages.action(path, model: self)
        }
        MonitorServer.shared.setRoute { [weak self] path in
            switch path {
            case "/", "/monitor", "/monitor/": return .html(page)
            case "/monitor/stats.json":
                let s = sys.sample(), n = net.sample()
                return .json(["cpu": Int(s.cpuPercent.rounded()), "mem": Int(s.memPercent.rounded()),
                              "memUsedGB": (s.memUsedGB * 10).rounded() / 10, "memTotalGB": (s.memTotalGB * 10).rounded() / 10,
                              "down": Int(n.downBytesPerSec), "up": Int(n.upBytesPerSec),
                              "disk": Self.diskUsedPercent(), "host": host, "t": Int(Date().timeIntervalSince1970)])
            default:
                guard let self else { return nil }
                return pages.route(path, model: self)
            }
        }
        do { try MonitorServer.shared.start() } catch { monitorError = "\(error)"; say("Monitor page could not start: \(error)"); return }
        monitorError = nil
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let peer = self.ipForSelected()
                // Actions (Music, Linear) come from the selected bar only; the pages stay readable on the LAN
                // unless Settings → "Serve the pages only to the bar" is on (then GET is peer-checked too).
                MonitorServer.shared.setActionPeers(Set([peer].compactMap { $0 }))
                MonitorServer.shared.setPagesOnlyForPeers(settings.pagesOnlyForBar)
                let url = MonitorServer.shared.url(reachableFrom: peer ?? "192.168.255.255")
                if url != self.monitorURL { self.monitorURL = url }
                if let url { MonitorBeacon.send(url: url, base: String(url.dropLast("/monitor".count)), to: peer) }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        say("Monitor page is on — the bar's Monitor app finds it by itself.")
    }

    var monitorInstalled: Bool { barApps.contains { $0.packageName == Self.monitorPackage } }

    /// The bar apps (android/DeckhandMonitor flavors): page id, label, bundled APK name. Order = order on the Apps page.
    static let barAppPages: [(page: String, label: String, apk: String)] = [
        ("monitor", "Monitor", "DeckhandMonitor"), ("claude", "Claude", "DeckhandClaude"), ("crypto", "Crypto", "DeckhandCrypto"),
        ("weather", "Weather", "DeckhandWeather"), ("music", "Music", "DeckhandMusic"), ("calendar", "Calendar", "DeckhandCalendar"),
        ("flights", "Flights", "DeckhandFlights"), ("sky", "Sun & Moon", "DeckhandSky"), ("news", "Headlines", "DeckhandNews"),
        ("verse", "Verse", "DeckhandVerse"), ("tasks", "Tasks", "DeckhandTasks")]

    /// APKs shipped inside Deckhand.app (packaging/make-app.sh copies dist/bar-apps) or next to the dev build.
    static func bundledAPK(_ name: String) -> URL? {
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("bar-apps/\(name).apk"),
                          URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist/bar-apps/\(name).apk")]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func barAppVersion(_ page: String) -> String? { barApps.first { $0.packageName == BarPages.package(for: page) }?.versionName }
    /// Version of the APKs shipped with this build — keep in step with android/DeckhandMonitor/app/build.gradle.kts.
    nonisolated static let barAppsVersion = "2.0"
    /// The bar's copy is older than the one shipped with Deckhand.
    func barAppNeedsUpdate(_ page: String) -> Bool {
        guard let v = barAppVersion(page) else { return false }
        let a = v.split(separator: ".").map { Int($0) ?? 0 }, b = Self.barAppsVersion.split(separator: ".").map { Int($0) ?? 0 }
        return a.lexicographicallyPrecedes(b)
    }
    func barAppIconURL(_ page: String) -> URL? { barApps.first { $0.packageName == BarPages.package(for: page) }?.iconUrl.flatMap(URL.init) }

    /// Install (or update) one bar app over ADB — Deckhand's own `adb install -r` of the bundled APK.
    func installBarApp(_ page: String) { Task { _ = await performInstallBarApp(page); refreshAppStore() } }

    /// Update several, one after the other.
    func updateBarApps(_ pages: [String]) {
        guard !pages.isEmpty else { return }
        Task { for p in pages { _ = await performInstallBarApp(p) }; refreshAppStore() }
    }

    @discardableResult
    func performInstallBarApp(_ page: String) async -> Bool {
        func fail(_ msg: String) -> Bool { barAppError = msg; say(msg); return false }
        guard let entry = Self.barAppPages.first(where: { $0.page == page }), let apk = Self.bundledAPK(entry.apk) else { return fail("No APK for \(page) in this build.") }
        guard let adb = AdbBridge.find() else { return fail("adb not found — brew install --cask android-platform-tools.") }
        guard let ip = ipForSelected() else { return fail("No CoreBar selected.") }
        barAppBusy = page; defer { barAppBusy = nil }
        let bridge = AdbBridge(path: adb, ip: ip)
        guard await bridge.connect() else {
            return fail("The bar refuses ADB on \(ip):5555 — Wi-Fi ADB is off (after a reboot unless made persistent, or after PC-LINK was plugged into a computer). Switch WiFi ADB on in the bar's Developer options, then Settings → Debug bridge: Keep on after reboots.")
        }
        let out = await bridge.install(apkPath: apk.path)
        let ok = out.contains("Success")
        if ok {
            barAppError = nil
            barPages.repushConfig()   // a freshly installed on-bar app gets its settings within 10 s
            say("\(entry.label) \(Self.barAppsVersion) is on the bar — add its card on the CoreBar page if it is not there yet.")
        } else {
            _ = fail("Install of \(entry.label) failed: \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return ok
    }

    /// Remove one of Deckhand's apps from the bar (`adb uninstall`). Its card disappears from the bar's page.
    func uninstallBarApp(_ page: String) {
        guard barAppBusy == nil, let entry = Self.barAppPages.first(where: { $0.page == page }) else { return }
        guard let adb = AdbBridge.find() else { barAppError = "adb not found — brew install --cask android-platform-tools."; return }
        guard let ip = ipForSelected() else { return }
        barAppBusy = page
        Task {
            defer { barAppBusy = nil }
            let bridge = AdbBridge(path: adb, ip: ip)
            guard await bridge.connect() else { barAppError = "The bar refuses ADB on \(ip):5555 — Settings → Debug bridge."; say(barAppError!); return }
            let out = await bridge.uninstall(package: BarPages.package(for: page))
            if out.contains("Success") { barAppError = nil; say("\(entry.label) removed from the bar.") }
            else { barAppError = "Could not remove \(entry.label): \(out.trimmingCharacters(in: .whitespacesAndNewlines))"; say(barAppError!) }
            refreshAppStore()
        }
    }

    /// Full-screen page for the 1424×280 bar: a moving CPU area chart, memory and disk bars, network
    /// up/down sparkline, clock. Plain canvas, no libraries; polls stats.json once a second.
    /// Lives in `Resources/pages/monitor.html`, served through the `BarPages` resource cache.
    nonisolated static var monitorPage: String { BarPages.html("monitor") }
}
