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

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    deviceSection
                    ConnectionHelp()
                    deviceSideSection
                    aboutSection
                }
                .padding()
            }
        }
        .frame(width: 520, height: 460)
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("CoreBar", systemImage: "rectangle.on.rectangle.angled").font(.headline)
            if let bar = model.selectedCoreBar {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow { Text("Name").foregroundStyle(.secondary); Text(bar.name) }
                    GridRow { Text("Serial").foregroundStyle(.secondary); Text(bar.serialNo).textSelection(.enabled) }
                    GridRow { Text("Address").foregroundStyle(.secondary); Text(model.ipForSelected() ?? bar.lastIp) }
                }
                .font(.caption)
            } else {
                Text("No CoreBar selected.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var deviceSideSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("On the CoreBar itself", systemImage: "gearshape.2").font(.headline)
            note("Time & timezone", "Set on the CoreBar (Settings → Time), kept by NTP. The PC protocol has no set-time command.")
            note("Wi-Fi", "Managed on the CoreBar. A protocol Wi-Fi scan exists and is on the roadmap for in-app switching.")
            note("Bluetooth", "Managed on the CoreBar (module mesh and PC-wake).")
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("About", systemImage: "info.circle").font(.headline)
            Text("Deckhand — independent, community software for UltraBar X. Not affiliated with Sanytron.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Widgets and their settings live in the Widgets section; pick which ones show per device on the VivoCube / CoreBar pages.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func note(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).fontWeight(.medium)
            Text(body).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
