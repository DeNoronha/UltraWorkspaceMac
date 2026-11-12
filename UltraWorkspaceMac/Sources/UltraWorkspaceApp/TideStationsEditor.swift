import SwiftUI

/// Apps → Tide: which Rijkswaterstaat gauges the bar shows (up to four, left to right), picked from the live
/// catalogue, and the location for the almanac. Saved to tide.json; the bar gets the list with its config.
struct TideSettings: View {
    @State private var stations: [TideStation] = TideStations.load()
    @State private var adding = false
    @State private var saveError: String?

    var body: some View {
        Panel("Gauges", footer: "Up to four, from Rijkswaterstaat's open water data (no key). The bar fetches the levels itself every 10 minutes while Tide is open, and the astronomical tide once a day. A gauge with a tide shows its next high and low water; a river gauge shows its level and trend.") {
            ForEach(Array(stations.enumerated()), id: \.element.id) { i, s in
                HStack(spacing: 10) {
                    Image(systemName: s.tide ? "water.waves" : "arrow.up.and.down").foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.name)
                        Text(s.tide ? "tide · \(s.code)" : "river gauge · \(s.code)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { move(i, -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).disabled(i == 0).help("Move left on the bar")
                    Button { move(i, 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).disabled(i == stations.count - 1).help("Move right on the bar")
                    Button { var next = stations; next.remove(at: i); save(next) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).disabled(stations.count == 1).help("Remove this gauge")
                }
            }
            HStack {
                Button { adding = true } label: { Label("Add gauge…", systemImage: "plus") }.disabled(stations.count >= TideStations.maxStations)
                Button("Default set") { save(TideStations.defaults) }.buttonStyle(.borderless).disabled(stations == TideStations.defaults)
                if let saveError { Text(saveError).font(.caption).foregroundStyle(.orange) }
            }
        }
        .sheet(isPresented: $adding) {
            TideStationPicker(taken: Set(stations.map(\.code))) { s in save(stations + [s]) }
        }
        LocationPanel()
        Text("Sunrise, sunset, day length and the moon are computed on the bar for this location.").font(.caption).foregroundStyle(.secondary)
    }

    private func move(_ i: Int, _ d: Int) { var next = stations; next.swapAt(i, i + d); save(next) }
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
                TextField("Search, e.g. Vlissingen, Lobith, IJmuiden", text: $query).textFieldStyle(.roundedBorder)
                Toggle("With tide only", isOn: $tideOnly).toggleStyle(.checkbox)
            }
            Group {
                if loading { ProgressView("Loading the gauges from Rijkswaterstaat…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let error { Text(error).foregroundStyle(.orange).frame(maxWidth: .infinity, maxHeight: .infinity) }
                else {
                    List(shown) { e in
                        Button { onPick(e.station); dismiss() } label: {
                            HStack {
                                Image(systemName: e.tide ? "water.waves" : "arrow.up.and.down").foregroundStyle(.secondary).frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(e.name)
                                    Text(e.code).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let v = e.level { Text("\(v > 0 ? "+" : "")\(v) cm NAP").monospacedDigit().foregroundStyle(.secondary) }
                                if let t = e.at { Text(t.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.tertiary) }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(minHeight: 340)
            HStack {
                Text(loading ? "" : "\(shown.count) of \(all.count) gauges that reported in the last two days").font(.caption).foregroundStyle(.secondary)
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
