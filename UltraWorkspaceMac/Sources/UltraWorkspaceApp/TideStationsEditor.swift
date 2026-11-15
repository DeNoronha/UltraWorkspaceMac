import SwiftUI

/// Apps → Tide: which Rijkswaterstaat gauges the bar shows (up to four, left to right), picked from the live
/// catalogue, and the location for the almanac. Saved to tide.json; the bar gets the list with its config.
struct TideSettings: View {
    @State private var stations: [TideStation] = TideStations.load()
    @State private var adding = false
    @State private var saveError: String?

    @State private var pendingRemove: TideStation?

    var body: some View {
        Section {
            ReorderableRows(items: stations, id: \.id, move: move) { _, s in
                HStack(spacing: 10) {
                    Image(systemName: s.tide ? "water.waves" : "arrow.up.and.down").foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.name)
                        Text(s.tide ? "Tide gauge" : "River gauge").font(.callout).foregroundStyle(.secondary).help(s.code)
                    }
                    Spacer()
                    RemoveMark(title: s.name) { pendingRemove = s }.disabled(stations.count == 1)
                }
            }
            HStack {
                Button("Add Gauge…") { adding = true }.disabled(stations.count >= TideStations.maxStations)
                Spacer()
                Button("Default Set") { save(TideStations.defaults) }.disabled(stations == TideStations.defaults)
            }
            if let saveError { StatusLabel(saveError, .failed) }
        } header: {
            Text("Gauges")
        } footer: {
            Footnote("Up to four, left to right on the bar. Drag to reorder. Rijkswaterstaat's open data, no key.")
        }
        .sheet(isPresented: $adding) {
            TideStationPicker(taken: Set(stations.map(\.code))) { s in save(stations + [s]) }
        }
        .confirmationDialog("Remove \(pendingRemove?.name ?? "this gauge")?", isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let s = pendingRemove { save(stations.filter { $0.id != s.id }) }; pendingRemove = nil }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        } message: { Text("The bar stops showing it within a few seconds.") }
        Section {
            LocationSummaryRow()
        } header: {
            Text("Almanac")
        } footer: {
            Footnote("Sunrise, sunset and the moon are computed on the bar for this location.")
        }
    }

    private func move(_ from: IndexSet, _ to: Int) { var next = stations; next.move(fromOffsets: from, toOffset: to); save(next) }

    private func save(_ next: [TideStation]) {
        do { try TideStations.save(next); stations = TideStations.load(); saveError = nil }
        catch { saveError = "Could not save: \(error.localizedDescription)" }
    }
}

/// The searchable list of live gauges; a click adds one.
private struct TideStationPicker: View {
    let taken: Set<String>
    let onPick: (TideStation) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var all: [TideStations.Entry] = []
    @State private var query = ""
    @State private var tideOnly = false
    @State private var loading = true
    @State private var error: String?

    private var shown: [TideStations.Entry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return all.filter { e in
            !taken.contains(e.code) && (!tideOnly || e.tide)
                && (q.isEmpty || e.name.localizedCaseInsensitiveContains(q) || e.code.localizedCaseInsensitiveContains(q))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a gauge").font(.title3.bold())
            HStack {
                TextField("Search", text: $query, prompt: Text("Search, e.g. Vlissingen, Lobith, IJmuiden")).textFieldStyle(.roundedBorder)
                Toggle("With tide only", isOn: $tideOnly).toggleStyle(.checkbox)
            }
            Group {
                if loading { ProgressView("Loading the gauges from Rijkswaterstaat…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let error { StatusLabel(error, .failed).frame(maxWidth: .infinity, maxHeight: .infinity) }
                else {
                    List(shown) { e in
                        Button { onPick(e.station); dismiss() } label: {
                            HStack {
                                Image(systemName: e.tide ? "water.waves" : "arrow.up.and.down").foregroundStyle(.secondary).frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(e.name)
                                    Text(e.code).font(.callout).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let v = e.level { Text("\(v > 0 ? "+" : "")\(v) cm NAP").monospacedDigit().foregroundStyle(.secondary) }
                                if let t = e.at { Text(t.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(minHeight: 340)
            HStack {
                Text(loading ? "" : "\(shown.count) of \(all.count) gauges that reported in the last two days").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20).frame(width: 620, height: 520)
        .task {
            do { all = try await TideStations.catalogue() } catch { self.error = "Could not load the gauges: \(error.localizedDescription)" }
            loading = false
        }
    }
}
