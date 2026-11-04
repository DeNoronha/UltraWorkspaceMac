import SwiftUI
import UltraBarKit

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header("Settings", "This bar, connection help and what is set on the bar itself.")
            Divider()

            Form {
                Section("CoreBar") {
                    if let bar = model.selectedCoreBar {
                        LabeledContent("Name", value: bar.name)
                        LabeledContent("Serial") { Text(bar.serialNo).textSelection(.enabled) }
                        LabeledContent("Address", value: model.ipForSelected() ?? bar.lastIp)
                    } else {
                        Text("No CoreBar selected.").foregroundStyle(.secondary)
                    }
                }

                Section("Bar screen") {
                    Toggle("Keep the screen on while someone is at the desk (via ADB)", isOn: $settings.presenceWake)
                        .onChange(of: settings.presenceWake) { on in on ? model.startPresence(settings: settings) : model.stopPresence(settings: settings) }
                    Stepper("Switch off after \(settings.presenceSleepMinutes) min without anyone", value: $settings.presenceSleepMinutes, in: 1...120)
                        .disabled(!settings.presenceWake)
                    LabeledContent("Status") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(model.presenceStatus)
                            if let on = model.barScreenOn { Text("Bar screen: \(on ? "on" : "off")").foregroundStyle(.secondary) }
                            if let t = model.lastPresenceAt { Text("Last movement \(Int(Date().timeIntervalSince(t))) s ago").foregroundStyle(.secondary) }
                        }.font(.callout)
                    }
                    Text("Uses the SenseCube's presence sensor through the bar's debug bridge: the bar needs \"Wi-Fi ADB\" on in its Developer options and adb on this Mac (brew install --cask android-platform-tools). The bar's own protocol cannot wake its screen; without this, the bar's Screen timeout setting (max 5 min or never) decides.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                Section("Connecting") {
                    ConnectionHelp()
                }

                Section("On the CoreBar itself") {
                    note("Time & timezone", "Set on the CoreBar (Settings → Time), kept by NTP. The protocol has no set-time command.")
                    note("Wi-Fi", "Managed on the CoreBar. The protocol can list nearby networks but cannot join one, so Wi-Fi onboarding stays on the device.")
                    note("Bluetooth", "Managed on the CoreBar (module mesh and PC-wake).")
                }

                Section("About") {
                    Text("Deckhand — independent, community software for UltraBar X. Not affiliated with Sanytron.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Widgets and their settings live in the Widgets section; pick which ones show per device on the VivoCube / CoreBar pages.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }

    private func note(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).fontWeight(.medium)
            Text(body).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
