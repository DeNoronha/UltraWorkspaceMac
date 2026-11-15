import Foundation
import UltraBarKit

/// The bar apps' data API (bar apps 2.0). Every Deckhand app on the bar carries its own page; this Mac answers the
/// data requests of the ones that show what only it knows (`/monitor/stats.json`, one sample per second, and the
/// `BarPages` routes), serves `/config.json`, and sends the UDP beacon every 5 s that tells the apps where it is.
/// It runs as long as Deckhand runs and answers only the selected bar and this Mac itself.
extension AppModel {
    func startBarDataServer(settings: AppSettings) {
        barDataTask?.cancel(); barDataTask = nil
        let sys = SystemStats(), net = NetworkStats()
        _ = sys.sample(); _ = net.sample()
        let host = Host.current().localizedName ?? "Mac"
        barPages.start(model: self, settings: settings)
        let pages = barPages
        MonitorServer.shared.setActionRoute { [weak self] path in
            guard let self else { return nil }
            return pages.action(path, model: self)
        }
        MonitorServer.shared.setRoute { [weak self] path in
            if path == "/monitor/stats.json" {
                let s = sys.sample(), n = net.sample()
                return .json(["cpu": Int(s.cpuPercent.rounded()), "mem": Int(s.memPercent.rounded()),
                              "memUsedGB": (s.memUsedGB * 10).rounded() / 10, "memTotalGB": (s.memTotalGB * 10).rounded() / 10,
                              "down": Int(n.downBytesPerSec), "up": Int(n.upBytesPerSec),
                              "disk": Self.diskUsedPercent(), "host": host, "t": Int(Date().timeIntervalSince1970)])
            }
            guard let self else { return nil }
            if path == "/home/glance.json", case let r? = pages.route(path, model: self),
               var obj = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] {
                // Monitor's tile: this Mac's processor load, from the same sampler as the Monitor page.
                var apps = obj["apps"] as? [String: Any] ?? [:]
                apps["monitor"] = ["line": "CPU \(Int(sys.sample().cpuPercent.rounded()))%"]
                obj["apps"] = apps
                return .json(obj)
            }
            return pages.route(path, model: self)
        }
        MonitorServer.shared.setAllowedPeers(Set([ipForSelected()].compactMap { $0 }))
        MonitorServer.shared.setPeerKey(selectedSerial.map { Store.shared.barKey(serial: $0) })
        do { try MonitorServer.shared.start() } catch { barDataError = "\(error)"; say("The bar apps' data could not be served: \(error)"); return }
        barDataError = nil
        barDataTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Data and actions go to the selected bar only (and this Mac); picking another bar moves them within 5 s.
                let peer = self.ipForSelected()
                // The selected bar's data key (pushed to its apps over ADB by BarPages): required on every request
                // and used to sign the beacon, so another host on the LAN can neither read the data nor pose as this Mac.
                let key = self.selectedSerial.map { Store.shared.barKey(serial: $0) }
                MonitorServer.shared.setAllowedPeers(Set([peer].compactMap { $0 }))
                MonitorServer.shared.setPeerKey(key)
                let base = MonitorServer.shared.baseURL(reachableFrom: peer ?? "192.168.255.255")
                if base != self.barDataURL { self.barDataURL = base }
                if let base { MonitorBeacon.send(base: base, to: peer, key: key) }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// The bar apps (android/DeckhandMonitor flavors): page id, label, bundled APK name. Order = order on the Apps page.
    static let barAppPages: [(page: String, label: String, apk: String)] = [
        ("monitor", "Monitor", "DeckhandMonitor"), ("claude", "Claude", "DeckhandClaude"), ("crypto", "Crypto", "DeckhandCrypto"),
        ("weather", "Weather", "DeckhandWeather"), ("music", "Music", "DeckhandMusic"), ("calendar", "Calendar", "DeckhandCalendar"),
        ("flights", "Flights", "DeckhandFlights"), ("sky", "Sun & Moon", "DeckhandSky"), ("news", "Headlines", "DeckhandNews"),
        ("verse", "Verse", "DeckhandVerse"), ("tasks", "Tasks", "DeckhandTasks"), ("haven", "Haven", "DeckhandHaven"),
        ("tide", "Tide", "DeckhandTide"),
        ("strava", "Training", "DeckhandTraining"),
        ("cask", "Whisky Portfolio", "DeckhandCask"),
        ("schiphol", "Schiphol", "DeckhandSchiphol"),
        ("teletekst", "Teletekst", "DeckhandTeletekst"),
        ("earth", "Earth", "DeckhandEarth"),
        ("seo", "SEO", "DeckhandSEO"),
        ("portfolio", "Portfolio", "DeckhandPortfolio"),
        ("status", "Cloud Status", "DeckhandStatus"),
        ("actions", "GitHub Actions", "DeckhandActions"),
        ("jira", "Jira Board", "DeckhandJira")]

    /// APKs shipped inside Deckhand.app (packaging/make-app.sh copies dist/bar-apps) or next to the dev build.
    static func bundledAPK(_ name: String) -> URL? {
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("bar-apps/\(name).apk"),
                          URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist/bar-apps/\(name).apk")]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func barAppVersion(_ page: String) -> String? { barApps.first { $0.packageName == BarPages.package(for: page) }?.versionName }
    /// Version of the APKs shipped with this build — keep in step with android/DeckhandMonitor/app/build.gradle.kts.
    nonisolated static let barAppsVersion = "2.6"
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
            return fail("The bar does not accept the debug bridge: WiFi ADB is off, after a reboot or after PC‑LINK was plugged into a computer. Switch WiFi ADB on in the bar's Developer options, then press Keep On After Reboots in Settings → Debug Bridge.")
        }
        let out = await bridge.install(apkPath: apk.path)
        let ok = out.contains("Success")
        if ok {
            barAppError = nil
            barPages.repushConfig()   // a freshly installed on-bar app gets its settings within 10 s
            say("\(entry.label) \(Self.barAppsVersion) is on the bar — publish the Deckhand page on CoreBar to show its card there.")
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
            guard await bridge.connect() else { barAppError = "The bar does not accept the debug bridge. See Settings → Debug Bridge."; say(barAppError!); return }
            let out = await bridge.uninstall(package: BarPages.package(for: page))
            if out.contains("Success") { barAppError = nil; say("\(entry.label) removed from the bar.") }
            else { barAppError = "Could not remove \(entry.label): \(out.trimmingCharacters(in: .whitespacesAndNewlines))"; say(barAppError!) }
            refreshAppStore()
        }
    }
}
