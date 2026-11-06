import Foundation
import UltraBarKit

/// Apps page: the vendor marketplace (install / update) and the apps on the bar (uninstall).
extension AppModel {
    func refreshAppStore() {
        guard let bar = selectedCoreBar, let session = session(for: bar) else { return }
        Task {
            do {
                let apps = try await BarAppStore.fetch()
                self.storeApps = apps
                self.appStoreError = nil
                do { self.storeScreensavers = try await BarAppStore.fetch(appType: BarAppStore.screensaversType) }
                catch { self.appStoreError = "The screensaver catalogue did not answer: \(error.localizedDescription)" }
                if let list = try? await session.listApps() { self.barApps = list }
                self.refreshTurnedOffApps()
                if let c = try? await session.readScreensaver() { self.screensaver = c }
                for a in apps + self.storeScreensavers { if let st = try? await session.appStatus(package: a.package) { self.appStatus[a.package] = st } }
            } catch {
                self.appStoreError = "The marketplace did not answer: \(error.localizedDescription)"
            }
        }
    }

    /// Install (or update) from the marketplace; the bar fetches the package itself. Polls the status
    /// for up to a minute so the row flips to "Installed" and the Open <app> card appears.
    func installApp(_ package: String, name: String) {
        guard appBusy == nil else { return }
        Task { _ = await self.performInstall(package, name: name) }
    }

    /// Update everything the marketplace has a newer version of, one after another (the bar
    /// installs one app at a time).
    func updateAll(_ items: [(package: String, name: String)]) {
        guard appBusy == nil, !items.isEmpty else { return }
        Task {
            var done = 0
            for it in items { if await self.performInstall(it.package, name: it.name) { done += 1 } }
            say("Bar: \(done) of \(items.count) app\(items.count == 1 ? "" : "s") updated.")
        }
    }

    /// Installed marketplace apps and screensavers for which the catalogue has a higher versionCode.
    var marketUpdates: [(package: String, name: String)] {
        barApps.compactMap { a in marketUpdate(for: a.packageName).map { _ in (a.packageName, a.appName) } }
    }
    /// The catalogue entry when the bar's copy is older than the marketplace lists — unless an earlier update
    /// showed that the entry's file is the old version anyway (see `staleCatalogue`).
    func marketUpdate(for package: String) -> BarAppStore.StoreApp? {
        guard let s = (storeApps + storeScreensavers).first(where: { $0.package == package }) else { return nil }
        let code = appStatus[package]?.versionCode ?? 0
        guard code > 0, s.versionCode > code, staleCatalogue[package] != s.versionCode else { return nil }
        return s
    }
    /// "marketplace lists 1.0.1, its file is 1.0.0" for an entry the vendor has not fixed yet.
    func staleCatalogueNote(_ package: String) -> String? {
        guard let s = (storeApps + storeScreensavers).first(where: { $0.package == package }), staleCatalogue[package] == s.versionCode,
              let st = appStatus[package] else { return nil }
        return "marketplace lists \(s.versionName), its file is \(st.versionName)"
    }
    /// Deckhand apps on the bar older than the APKs shipped with this build.
    var deckhandUpdates: [String] { Self.barAppPages.map(\.page).filter { barAppNeedsUpdate($0) } }
    var updatesAvailable: Int { marketUpdates.count + deckhandUpdates.count }
    /// Names of everything Update all would touch, marketplace first.
    var updateNames: [String] { marketUpdates.map(\.name) + deckhandUpdates.map { p in Self.barAppPages.first { $0.page == p }?.label ?? p } }
    var updateAllHelp: String {
        updatesAvailable == 0 ? "Everything is up to date." : "Updates one after another: " + (marketUpdates.map(\.name) + deckhandUpdates.map { p in Self.barAppPages.first { $0.page == p }?.label ?? p }).joined(separator: ", ")
    }
    /// Marketplace updates (the bar does them) and Deckhand's own (over ADB), one after another.
    func updateEverything() { updateAll(marketUpdates); updateBarApps(deckhandUpdates) }

    /// One install/update; polls the status for up to a minute. Returns true when the bar reports it installed.
    @discardableResult
    func performInstall(_ package: String, name: String) async -> Bool {
        guard let bar = selectedCoreBar, let session = session(for: bar) else { return false }
        appBusy = package
        defer { appBusy = nil }
        do {
            let isScreensaver = storeScreensavers.contains { $0.package == package } && !storeApps.contains { $0.package == package }
            _ = try await session.installApp(package: package, appType: isScreensaver ? BarAppStore.screensaversType : BarAppStore.appsType)
            say("Bar: installing \(name)…")
            let store = (storeApps + storeScreensavers).first { $0.package == package }
            let want = store?.versionCode ?? 0, before = appStatus[package]?.versionCode ?? 0
            for _ in 0..<20 {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                if let st = try? await session.appStatus(package: package) {
                    appStatus[package] = st
                    if st.installed, st.versionCode >= want { break }
                }
            }
            if let st = appStatus[package], st.installed, st.versionCode >= want {
                say("Bar: \(name) installed (\(st.versionName)).")
                if let list = try? await session.listApps() { barApps = list }
                return true
            }
            if let st = appStatus[package], let store, st.installed, st.versionCode == before, before > 0 {
                // The bar downloaded and installed the file, and it is the version that was already there: the
                // vendor's catalogue entry claims a newer version than the file it points to. Stop offering it.
                staleCatalogue[package] = want
                appStoreError = "\(name): the marketplace lists \(store.versionName), but the file it serves is still \(st.versionName), so the bar installed that again. There is nothing newer to get until the vendor fixes the entry."
            } else {
                appStoreError = "\(name) did not report as installed within a minute. The bar installs one app at a time and needs internet access for the download."
            }
        } catch { appStoreError = "Install failed: \(FriendlyError.text(error))" }
        return false
    }

    func uninstallApp(_ package: String, name: String) {
        guard let bar = selectedCoreBar, let session = session(for: bar), appBusy == nil else { return }
        appBusy = package
        Task {
            defer { self.appBusy = nil }
            do {
                let ok = try await session.uninstallApp(package: package)
                if let st = try? await session.appStatus(package: package) { self.appStatus[package] = st }
                if let list = try? await session.listApps() { self.barApps = list }
                say(ok ? "Bar: \(name) removed." : "Bar: could not remove \(name).")
                if ok { self.appStoreError = nil } else { self.appStoreError = "The bar refused to remove \(name)." }
            } catch { self.appStoreError = "Uninstall failed: \(FriendlyError.text(error))" }
        }
    }
}

// MARK: Turning firmware apps off (2026-11-06)

/// Firmware apps cannot be removed, but Android can turn them off (`pm disable-user`): they disappear from the bar
/// until they are turned on again, and nothing of them runs. The launcher, the module hub, the keyboard, Android's own
/// packages and Deckhand's apps are never offered, so the bar cannot be broken this way.
@MainActor
extension AppModel {
    private static let turnedOffNamesKey = "turnedOffAppNames"

    static func canTurnOff(_ package: String) -> Bool {
        let keep: Set<String> = ["com.ultrabar.launch", "com.ultrabar.hub", "com.ultrabar.inputmethod"]
        return !keep.contains(package) && !package.hasPrefix(BarPages.packagePrefix)
            && !package.hasPrefix("android") && !package.hasPrefix("com.android.") && !package.hasPrefix("com.google.")
            && package.range(of: #"^[A-Za-z0-9_.]+$"#, options: .regularExpression) != nil
    }

    /// The name an app had when it was turned off (the bar no longer lists it while it is off).
    func turnedOffName(_ package: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: Self.turnedOffNamesKey) as? [String: String])?[package]
    }

    /// Read which packages Android has turned off (`pm list packages -d`).
    func refreshTurnedOffApps() {
        guard let adb = AdbBridge.find(), let ip = ipForSelected() else { return }
        Task {
            let bridge = AdbBridge(path: adb, ip: ip)
            guard await bridge.connect() else { return }
            let out = await bridge.shell("pm list packages -d")
            turnedOffApps = Set(out.split(separator: "\n").compactMap { l in
                l.hasPrefix("package:") ? String(l.dropFirst(8)).trimmingCharacters(in: .whitespaces) : nil
            }.filter(Self.canTurnOff))
        }
    }

    func setAppTurnedOn(_ package: String, name: String, _ on: Bool) {
        guard Self.canTurnOff(package), appBusy == nil, let adb = AdbBridge.find(), let ip = ipForSelected() else { return }
        appBusy = package
        Task {
            defer { appBusy = nil }
            let bridge = AdbBridge(path: adb, ip: ip)
            guard await bridge.connect() else { say("The bar refuses ADB on \(ip):5555 — Settings → Debug bridge."); return }
            let out = await bridge.shell(on ? "pm enable \(package)" : "pm disable-user --user 0 \(package)")
            var names = (UserDefaults.standard.dictionary(forKey: Self.turnedOffNamesKey) as? [String: String]) ?? [:]
            if on { names[package] = nil } else { names[package] = name }
            UserDefaults.standard.set(names, forKey: Self.turnedOffNamesKey)
            if out.contains(on ? "enabled" : "disabled") {
                if on { turnedOffApps.remove(package) } else { turnedOffApps.insert(package) }
                say(on ? "\(name) is turned on again." : "\(name) is turned off on the bar.")
            } else {
                say("The bar did not \(on ? "turn on" : "turn off") \(name): \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            if let session = selectedCoreBar.flatMap(session(for:)), let list = try? await session.listApps() { barApps = list }
        }
    }
}
