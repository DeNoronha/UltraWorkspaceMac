import SwiftUI

/// Apps → Teletekst: the NOS Teletekst pages the bar rotates through (in order, up to eight), whether an index page
/// brings its stories along, and the seconds per page. Saved to teletekst.json; the bar gets it with its config.
struct TeletekstSettings: View {
    @State private var entries: [TeletekstEntry] = TeletekstPages.load().entries
    @State private var interval: Int = TeletekstPages.load().interval
    @State private var newPage = ""
    @State private var saveError: String?

    /// Well-known NOS pages, for the names in the list and the quick-add menu (checked on teletekst-data.nos.nl, Nov 2026).
    nonisolated static let known: [(page: String, name: String)] = [
        ("101", "News index"), ("102", "Domestic news"), ("103", "Foreign news"), ("500", "Finance"),
        ("601", "Sport"), ("702", "Weather forecast"), ("730", "Traffic"), ("801", "Football"),
    ]
    private static func name(_ p: String) -> String? { known.first { $0.page == p }?.name }

    @State private var pendingRemove: TeletekstEntry?

    var body: some View {
        Section {
            ReorderableRows(items: entries, id: \.id, move: move) { i, e in
                HStack(spacing: 10) {
                    Text(e.page).font(.body.monospacedDigit().bold()).frame(width: 36, alignment: .leading)
                    Text(Self.name(e.page) ?? "Page \(e.page)")
                    Spacer()
                    Toggle("With its stories", isOn: Binding(get: { e.stories }, set: { v in var next = entries; next[i].stories = v; save(next) }))
                        .toggleStyle(.checkbox).help("Follow the page with the pages it links to")
                    RemoveMark(title: "page \(e.page)") { pendingRemove = e }.disabled(entries.count == 1)
                }
            }
            HStack {
                TextField("Page", text: $newPage, prompt: Text("100–899")).frame(maxWidth: 160).onSubmit(add)
                Button("Add", action: add).disabled(!canAdd)
                Menu("Quick Add") {
                    ForEach(Self.known.filter { k in !entries.contains { $0.page == k.page } }, id: \.page) { k in
                        Button("\(k.page)  \(k.name)") { save(entries + [TeletekstEntry(page: k.page, stories: false)]) }
                    }
                }.fixedSize().disabled(entries.count >= TeletekstPages.maxEntries)
                Spacer()
                Button("Default Set") { save(TeletekstPages.defaults) }.disabled(entries == TeletekstPages.defaults)
            }
            if let saveError { StatusLabel(saveError, .failed) }
            else if !newPage.isEmpty && !TeletekstPages.isValid(newPage) { StatusLabel("A page from 100 to 899.", .info) }
            DetailsDisclosure(text: "The bar shows each page in the teletext colours, two columns at a time, and turns to the next after the interval; tap the right half for the next page, the left half for the previous. With stories on, an index page is followed by the pages it links to. The bar fetches the pages itself from NOS (no key): an index page at most every 2 minutes, a story every 10.")
        } header: {
            Text("Teletekst pages")
        } footer: {
            Footnote("Up to \(TeletekstPages.maxEntries), in this order. Drag to reorder.")
        }
        .confirmationDialog("Remove page \(pendingRemove?.page ?? "")?", isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let e = pendingRemove { save(entries.filter { $0.id != e.id }) }; pendingRemove = nil }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        } message: { Text("The bar stops showing it within a few seconds.") }
        Section {
            Stepper(value: Binding(get: { interval }, set: { v in interval = v; save(entries) }), in: TeletekstPages.intervalRange, step: 2) {
                LabeledContent("Per page", value: "\(interval) s")
            }
        } header: {
            Text("Rotation")
        } footer: {
            Footnote("A long story with subpages gets this time per subpage.")
        }
    }

    private var canAdd: Bool { TeletekstPages.isValid(newPage) && !entries.contains { $0.page == newPage } && entries.count < TeletekstPages.maxEntries }
    private func add() {
        guard canAdd else { return }
        save(entries + [TeletekstEntry(page: newPage, stories: false)]); newPage = ""
    }
    private func move(_ from: IndexSet, _ to: Int) { var next = entries; next.move(fromOffsets: from, toOffset: to); save(next) }

    private func save(_ next: [TeletekstEntry]) {
        do { try TeletekstPages.save(next, interval: interval); let l = TeletekstPages.load(); entries = l.entries; interval = l.interval; saveError = nil }
        catch { saveError = "Could not save: \(error.localizedDescription)" }
    }
}
