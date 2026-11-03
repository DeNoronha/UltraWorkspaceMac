import Foundation
import UltraBarKit

@MainActor
extension AppModel {
    /// Read which network the VivoCube is joined to (property 7).
    func refreshVivoWiFi(serial: String) {
        guard let bar = selectedCoreBar, let session = session(for: bar) else { return }
        Task {
            let w = await session.readModuleWiFi(serial: serial)
            self.vivoWiFi[serial] = w
            if let w {
                WireLog.shared.event("cube wifi: \(w.ssid)\(w.isCoreBarHotspot ? " (CoreBar hotspot)" : "")")
                if w.isCoreBarHotspot, !w.password.isEmpty { Store.shared.setHotspot(serial: bar.serialNo, ssid: w.ssid, password: w.password) }
                if !w.password.isEmpty { Store.shared.rememberNetwork(serial: bar.serialNo, ssid: w.ssid, password: w.password) }
            }
            else { self.say("Could not read the cube's Wi-Fi setting.") }
            await self.refreshDeviceState()
        }
    }

    /// Join the VivoCube to a Wi-Fi network. The password is sent to the cube
    /// only; Deckhand does not store it.
    func setVivoWiFi(serial: String, ssid: String, password: String) {
        guard let bar = selectedCoreBar, let session = session(for: bar) else { return }
        let w = CoreBarSession.ModuleWiFi(ssid: ssid.trimmingCharacters(in: .whitespaces), password: password)
        guard !w.ssid.isEmpty else { say("Enter the Wi-Fi name."); return }
        if w.isCoreBarHotspot, !w.password.isEmpty { Store.shared.setHotspot(serial: bar.serialNo, ssid: w.ssid, password: w.password) }
        if !w.password.isEmpty { Store.shared.rememberNetwork(serial: bar.serialNo, ssid: w.ssid, password: w.password) }
        isWorking = true
        say("Sending Wi-Fi “\(w.ssid)” to the cube…")
        Task {
            defer { self.isWorking = false }
            let code = await session.writeModuleWiFi(serial: serial, w)
            if code == 200 {
                self.say("The cube accepted the Wi-Fi settings and is reconnecting (about 20 s).")
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                self.refreshVivoWiFi(serial: serial)
            } else {
                self.say("The cube did not accept the Wi-Fi settings. Is it attached and awake?")
            }
        }
    }
}
