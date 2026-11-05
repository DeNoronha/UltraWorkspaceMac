import Foundation
import UltraBarKit

/// What Settings → Debug bridge shows: is adb on the Mac, does the bar answer on Wi-Fi, will it after a reboot, is it on USB.
struct AdbStatus: Sendable {
    var adbPath: String?
    var wifi: Bool? = nil          // nil = not checked yet
    var persistent: Bool? = nil
    /// The bar answers on 5555 but has not accepted this Mac yet (its screen shows "Allow debugging?").
    var unauthorized = false
    var usbSerials: [String] = []
    var checkedAt: Date?
    var message: String?
}

extension AppModel {
    /// Refresh the status: adb present, `adb connect ip:5555`, persist property, USB devices.
    func checkAdb() {
        guard !adbBusy else { return }
        adbBusy = true
        Task {
            defer { adbBusy = false }
            var st = AdbStatus(adbPath: AdbBridge.find(), checkedAt: Date())
            guard let adb = st.adbPath else { st.message = "adb is not installed on this Mac: brew install --cask android-platform-tools"; adbStatus = st; return }
            st.usbSerials = await AdbBridge.usbSerials(adb: adb)
            if let ip = ipForSelected() {
                let b = AdbBridge(path: adb, ip: ip)
                st.wifi = await b.connect()
                if st.wifi == true {
                    let state = await b.state()
                    st.unauthorized = state.contains("unauthorized")
                    if !st.unauthorized { st.persistent = await b.isPersistent() }
                }
            } else {
                st.message = "No CoreBar selected."
            }
            adbStatus = st
        }
    }

    /// The USB trick: `adb tcpip 5555` on the bar attached over USB, then connect over Wi-Fi.
    func enableWifiAdbOverUSB() {
        guard !adbBusy, let adb = AdbBridge.find() else { return }
        guard let serial = adbStatus.usbSerials.first else { say("Plug the bar into this Mac over USB first (and accept the debugging prompt on the bar)."); return }
        adbBusy = true
        Task {
            defer { adbBusy = false }
            let out = await AdbBridge.enableTcpip(adb: adb, usbSerial: serial)
            if out.contains("restarting in TCP mode") {
                say("Wi-Fi ADB is on (until the bar's next reboot) — connecting over Wi-Fi…")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                adbBusy = false; checkAdb()
            } else {
                say("adb tcpip failed: \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
    }

    /// Make the bar keep Wi-Fi ADB on across reboots (`persist.adb.tcp.port=5555`, verified 2026-11-04 on launcher 1.0.9).
    func makeWifiAdbPersistent() {
        guard !adbBusy, let adb = AdbBridge.find(), let ip = ipForSelected() else { return }
        adbBusy = true
        Task {
            defer { adbBusy = false }
            let b = AdbBridge(path: adb, ip: ip)
            guard await b.connect() else { say("The bar refuses ADB on \(ip):5555 — turn Wi-Fi ADB on first (over USB, or in the bar's Developer options)."); return }
            if await b.makePersistent() {
                say("Wi-Fi ADB now stays on after a reboot.")
                adbStatus.persistent = true; adbStatus.wifi = true
            } else {
                say("The bar did not accept the setting (setprop persist.adb.tcp.port).")
            }
        }
    }
}
