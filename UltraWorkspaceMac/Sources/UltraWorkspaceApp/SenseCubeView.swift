import SwiftUI
import UltraBarKit

@MainActor final class SenseReader: ObservableObject {
    @Published var reading: CoreBarSession.SenseReading?
    @Published var updated: Date?
    @Published var busy = false
    private var task: Task<Void, Never>?
    func start(model: AppModel, serial: String) {
        stop()
        task = Task { [weak self] in
            while !Task.isCancelled {
                if let bar = model.selectedCoreBar, let session = model.session(for: bar) {
                    await MainActor.run { self?.busy = true }
                    let r = await session.readSenseCube(serial: serial)
                    await MainActor.run { self?.reading = r; self?.updated = Date(); self?.busy = false }
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
    func stop() { task?.cancel(); task = nil }
}

struct SenseCubeView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    let module: AttachedModule
    @StateObject private var reader = SenseReader()

    var body: some View {
        VStack(spacing: 0) {
            Header("SenseCube", "Temperature, humidity and light at your desk.") {
                Button { reader.start(model: model, serial: module.serial) } label: { Label("Read now", systemImage: "arrow.clockwise") }.disabled(reader.busy)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        tile("Temperature", reader.reading?.temperatureC.map { String(format: "%.1f °C", $0) } ?? "—", "thermometer.medium", .orange)
                        tile("Humidity", reader.reading?.humidity.map { String(format: "%.0f %%", $0) } ?? "—", "humidity.fill", .teal)
                        tile("Light", reader.reading?.lux.map { "\($0) lux" } ?? "—", "sun.max.fill", .yellow)
                    }
                    if let u = reader.updated { Text("Read \(u, style: .time) · every 5 s while this page is open").font(.caption).foregroundStyle(.secondary) }
                    else if reader.reading == nil, !reader.busy { Text("No reply yet — tap the bar's screen to wake the sensor.").font(.caption).foregroundStyle(.orange) }
                    Panel("On the bar", footer: "Presence, sound and vibration are only available on the bar itself.") {
                        let onPage = settings.coreCards.contains("SENSE_TEMP") || settings.coreCards.contains("SENSE_HUM")
                        HStack {
                            Text(onPage ? "Temperature / humidity cards are on the CoreBar page." : "Show these on the bar: add the Temperature or Humidity card to the CoreBar page.")
                            Spacer()
                            Button(onPage ? "CoreBar page" : "Add cards…") {
                                if !onPage { if !settings.coreCards.contains("SENSE_TEMP") { settings.coreCards.append("SENSE_TEMP") }; if !settings.coreCards.contains("SENSE_HUM") { settings.coreCards.append("SENSE_HUM") } }
                                model.nav = .coreBarPage
                            }
                        }
                    }
                }.padding(20)
            }
        }
        .onAppear { reader.start(model: model, serial: module.serial) }
        .onDisappear { reader.stop() }
    }

    private func tile(_ label: String, _ value: String, _ icon: String, _ color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 26)).foregroundStyle(color)
            Text(value).font(.title3).bold().monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 120, height: 110)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.4)))
        .accessibilityElement(children: .combine)
    }
}
