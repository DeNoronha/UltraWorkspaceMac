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
                self.say(w.isCoreBarHotspot ? "VivoCube is on the CoreBar's own hotspot (\(w.ssid)) — uploads depend on that hotspot being up."
                                            : "VivoCube is on Wi-Fi “\(w.ssid)”.")
            } else { self.say("Could not read the VivoCube's Wi-Fi setting.") }
        }
    }

    /// Join the VivoCube to a Wi-Fi network. The password is sent to the cube
    /// only; Deckhand does not store it.
    func setVivoWiFi(serial: String, ssid: String, password: String) {
        guard let bar = selectedCoreBar, let session = session(for: bar) else { return }
        let w = CoreBarSession.ModuleWiFi(ssid: ssid.trimmingCharacters(in: .whitespaces), password: password)
        guard !w.ssid.isEmpty else { say("Enter the Wi-Fi name."); return }
        isWorking = true
        say("Sending Wi-Fi “\(w.ssid)” to the VivoCube…")
        Task {
            defer { self.isWorking = false }
            let code = await session.writeModuleWiFi(serial: serial, w)
            if code == 200 {
                self.say("VivoCube accepted the Wi-Fi settings — it reconnects on its own (allow ~20 s). Uploads then go over your network instead of the CoreBar hotspot.")
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                self.refreshVivoWiFi(serial: serial)
            } else {
                self.say("VivoCube did not accept the Wi-Fi settings (code \(code.map(String.init) ?? "none")).")
            }
        }
    }
}
