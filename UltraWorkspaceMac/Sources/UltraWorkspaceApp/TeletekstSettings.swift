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

    var body: some View {
        Panel("Pages", footer: "The bar shows each page in the classic teletext colours, split into two columns, and turns to the next one after the interval; tap the right half for the next page, the left half for the previous. With stories on, an index page is followed by the pages it links to (on 101: the news stories, 104 and up). The bar fetches the pages itself from NOS (teletekst-data.nos.nl, no key) while Teletekst is open: an index page at most every 2 minutes, a story every 10.") {
            ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                HStack(spacing: 10) {
                    Text(e.page).font(.system(.body, design: .monospaced).bold()).foregroundStyle(.yellow).frame(width: 36, alignment: .leading)
                    Text(Self.name(e.page) ?? "Page \(e.page)").frame(minWidth: 120, alignment: .leading)
                    Toggle("and its stories", isOn: Binding(get: { e.stories }, set: { v in var next = entries; next[i].stories = v; save(next) }))
                        .toggleStyle(.checkbox).help("Follow the page with the pages it links to")
                    Spacer()
                    Button { move(i, -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).disabled(i == 0).help("Earlier in the rotation")
                    Button { move(i, 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).disabled(i == entries.count - 1).help("Later in the rotation")
                    Button { var next = entries; next.remove(at: i); save(next) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).disabled(entries.count == 1).help("Remove this page")
                }
            }
            HStack {
                TextField("Page, e.g. 103", text: $newPage).frame(width: 110).onSubmit(add)
                Button("Add", action: add).disabled(!canAdd)
                Menu("Quick add") {
                    ForEach(Self.known.filter { k in !entries.contains { $0.page == k.page } }, id: \.page) { k in
                        Button("\(k.page)  \(k.name)") { save(entries + [TeletekstEntry(page: k.page, stories: false)]) }
                    }
                }.fixedSize().disabled(entries.count >= TeletekstPages.maxEntries)
                Button("Default set") { save(TeletekstPages.defaults) }.buttonStyle(.borderless).disabled(entries == TeletekstPages.defaults)
                if let saveError { Text(saveError).font(.caption).foregroundStyle(.orange) }
                else if !newPage.isEmpty && !TeletekstPages.isValid(newPage) { Text("A page from 100 to 899.").font(.caption).foregroundStyle(.secondary) }
            }
        }
        Panel("Rotation") {
            HStack {
                Stepper("\(interval) s per page", value: Binding(get: { interval }, set: { v in interval = v; save(entries) }), in: TeletekstPages.intervalRange, step: 2)
                Text("A long story with subpages gets this time per subpage.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var canAdd: Bool { TeletekstPages.isValid(newPage) && !entries.contains { $0.page == newPage } && entries.count < TeletekstPages.maxEntries }
    private func add() {
        guard canAdd else { return }
        save(entries + [TeletekstEntry(page: newPage, stories: false)]); newPage = ""
    }
    private func move(_ i: Int, _ d: Int) { var next = entries; next.swapAt(i, i + d); save(next) }
    private func save(_ next: [TeletekstEntry]) {
        do { try TeletekstPages.save(next, interval: interval); let l = TeletekstPages.load(); entries = l.entries; interval = l.interval; saveError = nil }
        catch { saveError = "Could not save: \(error.localizedDescription)" }
    }
}
