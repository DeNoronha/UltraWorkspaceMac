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
                if let list = try? await session.listApps() { self.barApps = list }
                for a in apps { if let st = try? await session.appStatus(package: a.package) { self.appStatus[a.package] = st } }
            } catch {
                self.appStoreError = "The marketplace did not answer: \(error.localizedDescription)"
            }
        }
    }

    /// Install (or update) from the marketplace; the bar fetches the package itself. Polls the status
    /// for up to a minute so the row flips to "Installed" and the Open <app> card appears.
    func installApp(_ package: String, name: String) {
        guard let bar = selectedCoreBar, let session = session(for: bar), appBusy == nil else { return }
        appBusy = package
        Task {
            defer { self.appBusy = nil }
            do {
                _ = try await session.installApp(package: package)
                say("Bar: installing \(name)…")
                for _ in 0..<20 {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    if let st = try? await session.appStatus(package: package) {
                        self.appStatus[package] = st
                        if st.installed, st.versionCode >= (self.storeApps.first { $0.package == package }?.versionCode ?? 0) { break }
                    }
                }
                if self.appStatus[package]?.installed == true {
                    say("Bar: \(name) installed (\(self.appStatus[package]?.versionName ?? "")).")
                    if let list = try? await session.listApps() { self.barApps = list }
                } else {
                    self.appStoreError = "\(name) did not report as installed within a minute. The bar installs one app at a time and needs internet access for the download."
                }
            } catch { self.appStoreError = "Install failed: \(FriendlyError.text(error))" }
        }
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
