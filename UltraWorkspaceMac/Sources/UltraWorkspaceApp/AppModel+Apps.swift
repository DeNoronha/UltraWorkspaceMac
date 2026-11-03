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
                do { self.storeScreensavers = try await BarAppStore.fetch(appType: BarAppStore.screensaversType) }
                catch { self.appStoreError = "The screensaver catalogue did not answer: \(error.localizedDescription)" }
                self.appStoreError = nil
                if let list = try? await session.listApps() { self.barApps = list }
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
            let want = (storeApps + storeScreensavers).first { $0.package == package }?.versionCode ?? 0
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
            appStoreError = "\(name) did not report as installed within a minute. The bar installs one app at a time and needs internet access for the download."
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
