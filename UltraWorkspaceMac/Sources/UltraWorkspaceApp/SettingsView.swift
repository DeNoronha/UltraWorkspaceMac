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
                        Toggle("Keep the bar's screen on (experimental)", isOn: $settings.keepBarAwake)
                        Text("The bar switches its screen off after a few minutes; Deckhand cannot change that timeout (no such setting in the protocol). With this on, Deckhand re-selects the current page every 4 minutes, which is the only known way to wake the screen. Tell me whether it works.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("No CoreBar selected.").foregroundStyle(.secondary)
                    }
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
