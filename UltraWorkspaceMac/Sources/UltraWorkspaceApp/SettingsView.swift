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
                    weatherSection
                    unitsSection
                    deviceSection
                    deviceSideSection
                }
                .padding()
            }
        }
        .frame(width: 520, height: 560)
    }

    // MARK: Weather & location

    private var weatherSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Weather & location", systemImage: "cloud.sun").font(.headline)
            Text("Used when UltraWorkspace renders its own weather card for a VivoCube (via Open-Meteo, no API key needed).")
                .font(.caption).foregroundStyle(.secondary)

            Picker("Location", selection: $settings.locationMode) {
                Text("Same as this Mac").tag(AppSettings.LocationMode.auto)
                Text("Manual").tag(AppSettings.LocationMode.manual)
            }
            .pickerStyle(.radioGroup)

            if settings.locationMode == .manual {
                HStack {
                    TextField("City (e.g. Amsterdam)", text: $settings.manualCity).frame(width: 220)
                }
                HStack {
                    TextField("Latitude", text: $settings.manualLat).frame(width: 110)
                    TextField("Longitude", text: $settings.manualLon).frame(width: 110)
                    Text("optional, overrides city").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Timezone: \(settings.macTimeZone)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var unitsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Units & clock", systemImage: "ruler").font(.headline)
            Picker("Units", selection: $settings.units) {
                Text("Metric (°C, km/h)").tag(AppSettings.Units.metric)
                Text("Imperial (°F, mph)").tag(AppSettings.Units.imperial)
            }.pickerStyle(.segmented).frame(width: 320)
            Toggle("24-hour clock", isOn: $settings.clock24h).toggleStyle(.switch)
        }
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

    // Honest status for things the device owns rather than the app.
    private var deviceSideSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("On the CoreBar itself", systemImage: "gearshape.2").font(.headline)
            note("Time & timezone", "Set on the CoreBar (Settings → Time) and kept by NTP. If the clock is wrong, check the CoreBar has internet and the right timezone — the PC protocol has no set-time command.")
            note("Wi-Fi", "Managed on the CoreBar. A protocol Wi-Fi scan (act 1633) exists and is on the roadmap for in-app switching.")
            note("Bluetooth", "Managed on the CoreBar (used for module mesh and PC-wake).")
        }
    }

    private func note(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).fontWeight(.medium)
            Text(body).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
