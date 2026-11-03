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
            }
            else { self.say("Could not read the cube's Wi-Fi setting.") }
            await self.refreshDeviceState()
            // Remember credentials only when the cube is actually connected with them — a typo read back
            // from the cube must not become a one-click button.
            if let w, !w.password.isEmpty, !self.cubeOffline {
                if w.isCoreBarHotspot { Store.shared.setHotspot(serial: bar.serialNo, ssid: w.ssid, password: w.password) }
                Store.shared.rememberNetwork(serial: bar.serialNo, ssid: w.ssid, password: w.password)
            }
        }
    }

    /// Join the VivoCube to a Wi-Fi network. The password is sent to the cube
    /// only; Deckhand does not store it.
    func setVivoWiFi(serial: String, ssid: String, password: String) {
        guard let bar = selectedCoreBar, let session = session(for: bar) else { return }
        let w = CoreBarSession.ModuleWiFi(ssid: ssid.trimmingCharacters(in: .whitespaces), password: password)
        guard !w.ssid.isEmpty else { say("Enter the Wi-Fi name."); return }
        isWorking = true
        say("Sending Wi-Fi “\(w.ssid)” to the cube…")
        Task {
            defer { self.isWorking = false }
            let code = await session.writeModuleWiFi(serial: serial, w)
            if code == 200 {
                self.say("The cube accepted the Wi-Fi settings and is reconnecting (about 20 s).")
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                self.refreshVivoWiFi(serial: serial)
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if !self.cubeOffline { self.say("The cube is on “\(w.ssid)”.") }
                else { self.say("The cube is \(self.cubeWiFiLabel) on “\(w.ssid)” — wrong password (\(w.password.count) characters sent), a 5 GHz-only network, or it needs another minute.") }
            } else {
                self.say("The cube did not accept the Wi-Fi settings. Is it attached and awake?")
            }
        }
    }
}
