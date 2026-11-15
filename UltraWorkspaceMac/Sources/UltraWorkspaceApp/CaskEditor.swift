import SwiftUI
import UniformTypeIdentifiers

/// Apps → Whisky Portfolio: the Whiskystats key, the credit budget and the bottles. The bottles are kept in `cask.json` in
/// Deckhand's Application Support folder (user-only), never anywhere else; Whiskystats only sees Whisky IDs.
struct CaskSettings: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var feed: CaskFeed
    @State private var editing: EditTarget?
    @State private var saveError: String?
    @State private var importing = false
    @State private var pendingImport: CaskImport.Result?
    @State private var importNote: String?

    struct EditTarget: Identifiable { let id = UUID(); let bottle: CaskBottle?; }

    @State private var pendingRemove: CaskBottle?

    var body: some View {
        Section {
            SecureField("Whiskystats key", text: $model.whiskystatsKey)
                .onSubmit { Task { await feed.checkCredits() } }
            if let e = feed.lastError { StatusLabel(e, .failed) }
            else if model.whiskystatsKey.isEmpty { StatusLabel("No key yet.", .info) }
            else if let b = feed.busy { BusyLabel("Fetching \(b)…") }
        } header: {
            Text("Whiskystats")
        } footer: {
            Footnote("Needs a Whiskystats membership with Data API credits. Kept in this Mac's Keychain.")
        }
        .task(id: model.whiskystatsKey) {   // free; after typing stops, not per keystroke
            try? await Task.sleep(nanoseconds: 800_000_000)
            if !Task.isCancelled { await feed.checkCredits() }
        }
        creditsSection
        bottlesSection
            .sheet(item: $editing) { t in
                CaskBottleEditor(feed: feed, bottle: t.bottle) { saved in
                    var next = feed.bottles
                    if let i = next.firstIndex(where: { $0.id == saved.id }) { next[i] = saved } else { next.append(saved) }
                    save(next)
                    if feed.cache.entries[saved.whiskyId]?.pricing == nil { feed.refreshNow(saved.whiskyId) }
                }
            }
    }

    private var creditsSection: some View {
        let n = Set(feed.bottles.map(\.whiskyId)).count, days = feed.refreshDays()
        let per = WhiskyStats.Cost.pricing + (feed.lotsOn ? WhiskyStats.Cost.lots : 0)
        let month = Int((Double(n * per) * 30 / Double(days)).rounded())
        return Section {
            if let c = feed.cache.credits {
                let left = max(0, c.limit - c.usage)
                LabeledContent("Used") {
                    HStack(spacing: 10) {
                        ProgressView(value: Double(min(c.usage, c.limit)), total: Double(max(1, c.limit))).frame(maxWidth: 160)
                        Text("\(c.usage) of \(c.limit) · \(left) left" + (c.cycle.map { " until \(CaskFeed.shortDate($0))" } ?? "")).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            } else {
                StatusLabel(model.whiskystatsKey.isEmpty ? "Add the key to see your credits." : "Credits not read yet.", .info)
            }
            Text(n == 0 ? "No bottles yet: nothing is spent." : "Each bottle is refreshed every \(days) days: about \(month) credits a month for \(n) bottle\(n == 1 ? "" : "s").")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Also fetch upcoming auction lots (\(WhiskyStats.Cost.lots) credits a bottle)", isOn: Binding(get: { feed.lotsOn }, set: { feed.setLots($0) }))
            if let note = feed.note { StatusLabel(note, .info) }
        } header: {
            Text("Credits")
        } footer: {
            Footnote("Prices cost \(WhiskyStats.Cost.pricing) credits, a search 1. Refreshes are spread over the month so the credits last.")
        }
    }

    private var bottlesSection: some View {
        Section {
            if let e = feed.fileError { StatusLabel(e, .failed) }
            if feed.bottles.isEmpty { Text("No bottles yet. Add one by searching Whiskystats or with its Whiskybase ID.").foregroundStyle(.secondary) }
            ForEach(feed.bottles) { b in
                let e = feed.cache.entries[b.whiskyId]
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(b.name).lineLimit(1)
                        Text(Self.summary(b, e)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if feed.busy == b.whiskyId { ProgressView().controlSize(.small) }
                    if e?.error != nil { Image(systemName: StatusKind.failed.symbol).foregroundStyle(.red).accessibilityLabel("Price fetch failed") }
                    Menu {
                        Button("Fetch Prices Now (\(WhiskyStats.Cost.pricing + (feed.lotsOn ? WhiskyStats.Cost.lots : 0)) credits)") { feed.refreshNow(b.whiskyId) }
                            .disabled(feed.busy != nil || model.whiskystatsKey.isEmpty)
                        Button("Edit…") { editing = EditTarget(bottle: b) }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Actions for \(b.name)")
                    RemoveMark(title: b.name) { pendingRemove = b }
                }
            }
            HStack {
                Button("Add Bottle…") { editing = EditTarget(bottle: nil) }.disabled(model.whiskystatsKey.isEmpty)
                Button("Import Whiskystats Export…") { importing = true }
                Spacer()
                Button("Show cask.json") { NSWorkspace.shared.activateFileViewerSelecting([CaskFeed.bottlesURL]) }
                    .disabled(!FileManager.default.fileExists(atPath: CaskFeed.bottlesURL.path))
            }
            let todo = feed.unpriced.count
            if let b = feed.batch {
                LabeledContent("Fetching prices") {
                    HStack {
                        ProgressView(value: Double(b.done), total: Double(max(1, b.total))).frame(maxWidth: 120)
                        Text("\(b.done) of \(b.total)").monospacedDigit()
                    }
                }
            } else if todo > 0 {
                Button("Fetch Prices for \(todo) Without (\(todo * (WhiskyStats.Cost.pricing + (feed.lotsOn ? WhiskyStats.Cost.lots : 0))) credits)") { feed.fetchUnpriced() }
                    .disabled(model.whiskystatsKey.isEmpty || feed.busy != nil)
            }
            if let saveError { StatusLabel(saveError, .failed) }
            if let importNote { StatusLabel(importNote, .info) }
            DetailsDisclosure(text: "Market value is Whiskystats' 90-day average of auction buyer prices (hammer plus fees), worldwide, in euros; a bottle without trades of its own uses its bottle group's. What you paid and when is optional; it stays on this Mac and is shown only on your own bar. The list is cask.json in Deckhand's Application Support folder; a hand edit is picked up within a minute.")
        } header: {
            Text("Bottles")
        } footer: {
            Footnote("What you paid stays on this Mac. Whiskystats only sees the bottle IDs.")
        }
        .confirmationDialog("Remove \(pendingRemove?.name ?? "this bottle")?", isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let b = pendingRemove { save(feed.bottles.filter { $0.id != b.id }) }; pendingRemove = nil }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        } message: { Text("The bottle, with what you paid and when, is deleted from Whisky Portfolio.") }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "xlsx") ?? .data, .commaSeparatedText]) { r in
            guard case .success(let url) = r else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { pendingImport = try CaskImport.read(url); importNote = nil } catch { importNote = error.localizedDescription }
        }
        .confirmationDialog(importTitle, isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }), titleVisibility: .visible) {
            Button("Replace the List") {
                guard let r = pendingImport else { return }
                save(CaskImport.merge(r.bottles, into: feed.bottles))
                let n = Set(r.bottles.map(\.whiskyId)).subtracting(feed.cache.entries.compactMap { $0.value.pricing == nil ? nil : $0.key }).count
                importNote = "Imported \(r.bottles.count) bottles (\(r.total) in total)" + (r.skipped > 0 ? ", \(r.skipped) rows without a Whiskybase ID skipped" : "") + (n > 0 ? ". \(n) still need prices: press Fetch Prices, or they come one by one while Whisky Portfolio is on the bar, \(WhiskyStats.Cost.pricing) credits each." : ".")
                pendingImport = nil
            }
            Button("Cancel", role: .cancel) { pendingImport = nil }
        } message: {
            Text("The export is your whole collection, so it replaces the \(feed.bottles.count) bottle\(feed.bottles.count == 1 ? "" : "s") in Whisky Portfolio now. Prices already fetched are kept for bottles that stay. Nothing is sent to Whiskystats until prices are fetched.")
        }
    }

    private var importTitle: String {
        guard let r = pendingImport else { return "" }
        return "Import \(r.bottles.count) different bottles, \(r.total) in total?"
    }

    static func summary(_ b: CaskBottle, _ e: CaskFeed.Entry?) -> String {
        var parts = [b.whiskyId, "\(b.quantity)×"]
        if let p = b.price { parts.append("paid \(euro(p))") }
        if let v = e?.pricing?.marketValue ?? e?.pricing?.latestAvg { parts.append("worth \(euro(v))") }
        if let at = e?.pricedAt { parts.append("prices of \(at.formatted(.dateTime.day().month(.abbreviated)))") }
        if let err = e?.error { parts.append(err) } else if e?.pricing == nil { parts.append("no prices yet") }
        return parts.joined(separator: " · ")
    }
    static func euro(_ v: Double) -> String { v.formatted(.currency(code: "EUR").precision(.fractionLength(0))) }

    private func save(_ next: [CaskBottle]) {
        do { try feed.saveBottles(next); saveError = nil } catch { saveError = "Could not save: \(error.localizedDescription)" }
    }
}

/// One bottle: found by a search (1 credit) or by its Whiskybase ID, with how many, what was paid and when.
private struct CaskBottleEditor: View {
    @ObservedObject var feed: CaskFeed
    let isNew: Bool
    let onSave: (CaskBottle) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var bottle: CaskBottle
    @State private var hasDate: Bool
    @State private var date: Date
    @State private var query = ""
    @State private var hits: [WhiskyStats.Hit] = []
    @State private var searching = false
    @State private var searchNote: String?

    init(feed: CaskFeed, bottle: CaskBottle?, onSave: @escaping (CaskBottle) -> Void) {
        self.feed = feed; self.isNew = bottle == nil; self.onSave = onSave
        let b = bottle ?? CaskBottle(whiskyId: "", name: "")
        _bottle = State(initialValue: b)
        let d = b.bought.flatMap { CaskFeed.day.date(from: $0) }
        _hasDate = State(initialValue: d != nil)
        _date = State(initialValue: d ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "Add a bottle" : "Edit \(bottle.name)").font(.title3.bold())
            VStack(alignment: .leading, spacing: 4) {
                Text("Find on Whiskystats").font(.callout).foregroundStyle(.secondary)
                HStack {
                    TextField("Search", text: $query, prompt: Text("Name, e.g. Lagavulin 16, or a Whiskybase ID or link")).onSubmit(search)
                    Button(WhiskyStats.whiskyID(from: query) != nil ? "Look up (1 credit)" : "Search (1 credit)", action: search)
                        .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)
                }
                if let searchNote { Text(searchNote).font(.callout).foregroundStyle(.secondary) }
                if !hits.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(hits.prefix(40)) { h in
                                Button { pick(h) } label: {
                                    HStack(spacing: 8) {
                                        Text(h.whiskyId).font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
                                        Text(h.name).lineLimit(1)
                                        if h.whiskyId.hasPrefix("BG") { Text("Group").font(.caption).foregroundStyle(.secondary) }
                                        Spacer()
                                    }.contentShape(Rectangle()).padding(.vertical, 2)
                                        .background(bottle.whiskyId == h.whiskyId ? Color.accentColor.opacity(0.2) : .clear)
                                }.buttonStyle(.plain)
                            }
                        }
                    }.frame(height: 180)
                    Text("Same name, different ID: different bottlings or labels. A group (BG) covers bottlings that only differ in details; pick one from Whiskybase if you know it, else the group.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            Form {
                TextField("Whisky ID", text: $bottle.whiskyId, prompt: Text("WB12345 or BG…"))
                TextField("Name on the bar", text: $bottle.name)
                Stepper("Bottles: \(bottle.quantity)", value: $bottle.quantity, in: 1...999)
                TextField("Paid per bottle (€)", value: $bottle.price, format: .number, prompt: Text("Optional"))
                Toggle("Bought on", isOn: $hasDate)
                if hasDate { DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: .date) }
            }
            if isNew { Text("Adding fetches the bottle's prices once (\(WhiskyStats.Cost.pricing + (feed.lotsOn ? WhiskyStats.Cost.lots : 0)) credits).").font(.callout).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { onSave(finished()); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(WhiskyStats.whiskyID(from: bottle.whiskyId) == nil || bottle.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 620)
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !searching else { return }
        let asID = WhiskyStats.whiskyID(from: q)
        searching = true; searchNote = nil
        Task { @MainActor in
            defer { searching = false }
            do {
                let found = try await feed.search(asID ?? q)
                if let asID, let exact = found.first(where: { $0.whiskyId == asID }) { hits = [exact]; pick(exact) }
                else { hits = found }
                searchNote = hits.isEmpty ? (asID != nil ? "Whiskystats does not know \(asID!)." : "Nothing found. Try fewer words: distillery and age or edition.") : nil
            } catch { hits = []; searchNote = error.localizedDescription }
        }
    }

    private func pick(_ h: WhiskyStats.Hit) {
        bottle.whiskyId = h.whiskyId
        bottle.name = Self.barName(h.name)
    }

    /// Whiskystats' names are long ("Lagavulin Islay Single Malt Scotch Whisky 16-year-old (700ml)"): the bar
    /// gets them without the category and the standard bottle size, and the name stays editable.
    static func barName(_ s: String) -> String {
        var n = s
        for cut in [" Single Malt Scotch Whisky", " Blended Malt Scotch Whisky", " Single Malt Whisky", " (700ml)"] { n = n.replacingOccurrences(of: cut, with: "") }
        return n.replacingOccurrences(of: "-year-old", with: " years").trimmingCharacters(in: .whitespaces)
    }

    private func finished() -> CaskBottle {
        var b = bottle
        b.whiskyId = WhiskyStats.whiskyID(from: b.whiskyId) ?? b.whiskyId
        b.name = b.name.trimmingCharacters(in: .whitespaces)
        b.bought = hasDate ? CaskFeed.day.string(from: date) : nil
        if let p = b.price, p <= 0 { b.price = nil }
        return b
    }
}
