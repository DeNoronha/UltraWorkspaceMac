import SwiftUI
import UltraBarKit

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Settings").font(.title2).bold()
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
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

                Section("Connecting") {
                    ConnectionHelp()
                }

                Section("On the CoreBar itself") {
                    note("Time & timezone", "Set on the CoreBar (Settings → Time), kept by NTP. The protocol has no set-time command.")
                    note("Wi-Fi", "Managed on the CoreBar. A protocol Wi-Fi scan exists and is on the roadmap for in-app switching.")
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
        .frame(width: 540, height: 540)
    }

    private func note(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).fontWeight(.medium)
            Text(body).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
