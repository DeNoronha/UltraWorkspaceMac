import Foundation
import UltraBarKit

/// Settings → Bar home screen: what the bar shows when nothing else is open. The bar's own launcher
/// (com.ultrabar.launch) is the home screen out of the box; Deckhand Home (android/DeckhandMonitor/home) is a
/// plain tile-per-app home for the 1424×280 strip. Either is chosen with `cmd package set-home-activity`
/// over the debug bridge, and the other keeps running underneath, so the choice is reversible in one press.
struct BarHomeStatus: Sendable {
    /// Deckhand Home as installed on the bar, nil when it is not.
    var installed: (name: String, code: Int)?
    /// The component the bar resolves for the HOME intent, e.g. `com.ultrabar.launch/.ui.activity.MainActivity`.
    var current: String?
    var checkedAt: Date?
    var message: String?

    var deckhandIsHome: Bool { current?.hasPrefix(AppModel.homePackage + "/") == true }
    var vendorIsHome: Bool { current?.hasPrefix(VendorRelease.launcherPackage + "/") == true }
    /// The bar's copy is older than the APK shipped with this build.
    var updateAvailable: Bool { installed.map { $0.code < AppModel.homeVersionCode } ?? false }
}

extension AppModel {
    nonisolated static let homePackage = "nl.denoronha.deckhand.home"
    nonisolated static let homeComponent = homePackage + "/.HomeActivity"
    nonisolated static let vendorHomeComponent = VendorRelease.launcherPackage + "/.ui.activity.MainActivity"
    /// Keep in step with android/DeckhandMonitor/home/build.gradle.kts.
    nonisolated static let homeVersion = "1.0"
    nonisolated static let homeVersionCode = 1

    private func homeBridge() async -> AdbBridge? {
        guard let adb = AdbBridge.find() else { barHome.message = "adb not found — brew install --cask android-platform-tools."; return nil }
        guard let ip = ipForSelected() else { barHome.message = "No CoreBar selected."; return nil }
        let b = AdbBridge(path: adb, ip: ip)
        guard await b.connect() else { barHome.message = "The bar refuses ADB on \(ip):5555 — Settings → Debug bridge."; return nil }
        return b
    }

    /// Read what the bar has: is Deckhand Home installed, and which app answers the HOME intent.
    func checkBarHome() {
        guard barHomeBusy == nil else { return }
        barHomeBusy = "Checking…"
        Task {
            defer { barHomeBusy = nil }
            var st = BarHomeStatus(checkedAt: Date())
            guard let b = await homeBridge() else { st.message = barHome.message; barHome = st; return }
            st.installed = await b.packageVersion(Self.homePackage)
            st.current = await b.currentHome()
            if st.current == nil { st.message = "The bar did not say which app is its home screen." }
            barHome = st
        }
    }

    /// `adb install -r` of the bundled DeckhandHome.apk, then re-check.
    func installBarHome() {
        guard barHomeBusy == nil, let apk = Self.bundledAPK("DeckhandHome") else { barHome.message = "No DeckhandHome.apk in this build."; return }
        barHomeBusy = "Installing Deckhand Home…"
        Task {
            defer { barHomeBusy = nil }
            guard let b = await homeBridge() else { return }
            let out = await b.install(apkPath: apk.path)
            guard out.contains("Success") else { barHome.message = "Install failed: \(out.trimmingCharacters(in: .whitespacesAndNewlines))"; say(barHome.message!); return }
            barHome.installed = await b.packageVersion(Self.homePackage)
            barHome.current = await b.currentHome()
            barHome.message = nil
            say("Deckhand Home \(Self.homeVersion) is on the bar. Press Use Deckhand Home to make it the bar's home screen.")
        }
    }

    /// Make Deckhand Home (or the bar's own launcher) the home screen and show it.
    func setBarHome(deckhand: Bool) {
        guard barHomeBusy == nil else { return }
        let component = deckhand ? Self.homeComponent : Self.vendorHomeComponent
        barHomeBusy = deckhand ? "Switching to Deckhand Home…" : "Switching to the bar's own home…"
        Task {
            defer { barHomeBusy = nil }
            guard let b = await homeBridge() else { return }
            let ok = await b.setHome(component)
            barHome.current = await b.currentHome()
            if ok, (deckhand ? barHome.deckhandIsHome : barHome.vendorIsHome) {
                barHome.message = nil
                say(deckhand ? "The bar now opens Deckhand Home. Its own launcher keeps running underneath." : "The bar is back on its own home screen.")
            } else {
                barHome.message = "The bar did not switch its home screen (cmd package set-home-activity)."
                say(barHome.message!)
            }
        }
    }
}

extension AdbBridge {
    /// The component that answers the HOME intent, from `cmd package resolve-activity`.
    func currentHome() async -> String? {
        let out = await shell("cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME")
        let lines = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return lines.last { $0.contains("/") && !$0.hasPrefix("priority") }
    }

    /// `cmd package set-home-activity <component>`, then bring the home screen to the front.
    func setHome(_ component: String) async -> Bool {
        let out = await shell("cmd package set-home-activity \(component)")
        guard out.contains("Success") else { return false }
        _ = await shell("am start -a android.intent.action.MAIN -c android.intent.category.HOME")
        return true
    }
}
