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

    private static let cardIDs = ["SENSE_TEMP", "SENSE_HUM", "SENSE_LUX", "SENSE_PRESENCE", "SENSE_SOUND"]

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    tile("Temperature", reader.reading?.temperatureC.map { String(format: "%.1f °C", $0) } ?? "—", "thermometer.medium")
                    tile("Humidity", reader.reading?.humidity.map { String(format: "%.0f %%", $0) } ?? "—", "humidity")
                    tile("Light", reader.reading?.lux.map { "\($0) lux" } ?? "—", "sun.max")
                }
                .frame(maxWidth: .infinity)
                if let u = reader.updated { StatusLabel("Read at \(u.formatted(date: .omitted, time: .standard)), every 5 s while this page is open.", .info) }
                else if reader.reading == nil, !reader.busy { StatusLabel("No reply yet. Tap the bar's screen to wake the sensor.", .attention) }
            } header: {
                Text("At your desk")
            }
            Section {
                let onPage = Self.cardIDs.filter { settings.coreCards.contains($0) }
                ForEach(Self.cardIDs, id: \.self) { id in
                    LabeledContent(AppSettings.coreCard(id)?.title ?? id) {
                        Text(settings.coreCards.contains(id) ? "On the Deckhand page" : "Not on the page").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    if onPage.count < Self.cardIDs.count {
                        Button("Add All to the Deckhand Page") {
                            for id in Self.cardIDs where !settings.coreCards.contains(id) { settings.coreCards.append(id) }
                        }
                    }
                    Button("Open CoreBar") { model.nav = .coreBarPage }
                }
            } header: {
                Text("Cards on the bar")
            } footer: {
                Footnote("Presence and sound level are shown by the bar only; this Mac cannot read them.")
            }
        }
        .formStyle(.grouped)
        .navigationSubtitle("Temperature, humidity and light")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { reader.start(model: model, serial: module.serial) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(reader.busy)
                    .keyboardShortcut("r", modifiers: .command).help("Ask the SenseCube for a fresh reading (⌘R)")
            }
        }
        .onAppear { reader.start(model: model, serial: module.serial) }
        .onDisappear { reader.stop() }
    }

    private func tile(_ label: String, _ value: String, _ icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title2).foregroundStyle(Color.accentColor)
            Text(value).font(.title3).bold().monospacedDigit()
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .frame(minWidth: 110)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}
