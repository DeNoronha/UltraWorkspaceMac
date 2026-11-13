import SwiftUI
import UniformTypeIdentifiers

/// Apps → Cask: the Whiskystats key, the credit budget and the bottles. The bottles are kept in `cask.json` in
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

    var body: some View {
        Panel("Cask settings", footer: "A Whiskystats membership with Data API credits; the key is under your account settings on whiskystats.com. It is kept in a user-only file on this Mac and only sent to data.api.whiskystats.com; the bar asks Deckhand for the prices.") {
            HStack {
                SecureField("Whiskystats API key", text: $model.whiskystatsKey).frame(width: 320)
                    .onSubmit { Task { await feed.checkCredits() } }
                if let e = feed.lastError { Text(e).font(.caption).foregroundStyle(.orange).lineLimit(2) }
                else if model.whiskystatsKey.isEmpty { Text("No key yet.").font(.caption).foregroundStyle(.secondary) }
                else if let b = feed.busy { Text("Fetching \(b)…").font(.caption).foregroundStyle(.secondary) }
                else { Text("Saved.").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .task(id: model.whiskystatsKey) {   // free; after typing stops, not per keystroke
            try? await Task.sleep(nanoseconds: 800_000_000)
            if !Task.isCancelled { await feed.checkCredits() }
        }
        creditsPanel
        bottlesPanel
            .sheet(item: $editing) { t in
                CaskBottleEditor(feed: feed, bottle: t.bottle) { saved in
                    var next = feed.bottles
                    if let i = next.firstIndex(where: { $0.id == saved.id }) { next[i] = saved } else { next.append(saved) }
                    save(next)
                    if feed.cache.entries[saved.whiskyId]?.pricing == nil { feed.refreshNow(saved.whiskyId) }
                }
            }
    }

    private var creditsPanel: some View {
        let n = Set(feed.bottles.map(\.whiskyId)).count, days = feed.refreshDays()
        let per = WhiskyStats.Cost.pricing + (feed.lotsOn ? WhiskyStats.Cost.lots : 0)
        let month = Int((Double(n * per) * 30 / Double(days)).rounded())
        return Panel("Credits", footer: "Whiskystats charges per call: auction prices 10 credits, the lots coming up at auction 7, a search 1, the balance nothing. Deckhand caches everything on this Mac, refreshes one bottle at a time while Cask is on the bar, spreads the refreshes over the month and never spends the last \(CaskFeed.reserve) credits of a cycle.") {
            if let c = feed.cache.credits {
                let left = max(0, c.limit - c.usage)
                HStack(spacing: 10) {
                    ProgressView(value: Double(min(c.usage, c.limit)), total: Double(max(1, c.limit))).frame(width: 180)
                    Text("\(c.usage) of \(c.limit) used · \(left) left").monospacedDigit()
                    if let cy = c.cycle { Text("until \(CaskFeed.shortDate(cy))").font(.caption).foregroundStyle(.secondary) }
                }
            } else {
                Text(model.whiskystatsKey.isEmpty ? "Add the key to see your credits." : "Credits not read yet.").font(.caption).foregroundStyle(.secondary)
            }
            Text(n == 0 ? "No bottles yet: nothing is spent." : "Each bottle is refreshed every \(days) days: about \(month) credits a month for \(n) bottle\(n == 1 ? "" : "s").")
                .font(.callout)
            Toggle("Also fetch the lots coming up at auction (7 credits per bottle per refresh)", isOn: Binding(get: { feed.lotsOn }, set: { feed.setLots($0) }))
            if let note = feed.note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var bottlesPanel: some View {
        Panel("Bottles", footer: "Market value is Whiskystats' 90-day average of auction buyer prices (hammer plus fees), worldwide, in euros; a bottle without trades of its own uses its bottle group's. What you paid and when is optional and stays on this Mac. The list is cask.json in Deckhand's Application Support folder; a hand edit is picked up within a minute.") {
            if let e = feed.fileError { Text(e).font(.caption).foregroundStyle(.orange) }
            if feed.bottles.isEmpty { Text("No bottles yet. Add one by searching Whiskystats or with its Whiskybase ID.").font(.caption).foregroundStyle(.secondary) }
            ForEach(feed.bottles) { b in
                let e = feed.cache.entries[b.whiskyId]
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(b.name).lineLimit(1)
                        Text(Self.summary(b, e)).font(.caption).foregroundStyle(e?.error != nil ? .orange : .secondary).lineLimit(1)
                    }
                    Spacer()
                    if feed.busy == b.whiskyId { ProgressView().controlSize(.small) }
                    Button { feed.refreshNow(b.whiskyId) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
                        .disabled(feed.busy != nil || model.whiskystatsKey.isEmpty)
                        .help("Fetch this bottle's prices now (\(WhiskyStats.Cost.pricing + (feed.lotsOn ? WhiskyStats.Cost.lots : 0)) credits)")
                    Button("Edit…") { editing = EditTarget(bottle: b) }
                    Button { save(feed.bottles.filter { $0.id != b.id }) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Remove this bottle")
                }
            }
            HStack {
                Button { editing = EditTarget(bottle: nil) } label: { Label("Add bottle", systemImage: "plus") }.disabled(model.whiskystatsKey.isEmpty)
                Button { importing = true } label: { Label("Import Whiskystats export…", systemImage: "square.and.arrow.down") }
                Button { NSWorkspace.shared.activateFileViewerSelecting([CaskFeed.bottlesURL]) } label: { Label("Show cask.json", systemImage: "doc.text") }
                    .buttonStyle(.borderless).disabled(!FileManager.default.fileExists(atPath: CaskFeed.bottlesURL.path))
                if let saveError { Text(saveError).font(.caption).foregroundStyle(.orange) }
            }
            if let importNote { Text(importNote).font(.caption).foregroundStyle(.secondary) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "xlsx") ?? .data, .commaSeparatedText]) { r in
            guard case .success(let url) = r else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { pendingImport = try CaskImport.read(url); importNote = nil } catch { importNote = error.localizedDescription }
        }
        .confirmationDialog(importTitle, isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }), titleVisibility: .visible) {
            Button("Replace the list") {
                guard let r = pendingImport else { return }
                save(CaskImport.merge(r.bottles, into: feed.bottles))
                let n = Set(r.bottles.map(\.whiskyId)).subtracting(feed.cache.entries.compactMap { $0.value.pricing == nil ? nil : $0.key }).count
                importNote = "Imported \(r.bottles.count) bottles (\(r.total) in total)" + (r.skipped > 0 ? ", \(r.skipped) rows without a Whiskybase ID skipped" : "") + (n > 0 ? ". \(n) still need prices: fetched one by one while Cask is on the bar, \(WhiskyStats.Cost.pricing) credits each." : ".")
                pendingImport = nil
            }
            Button("Cancel", role: .cancel) { pendingImport = nil }
        } message: {
            Text("The export is your whole collection, so it replaces the \(feed.bottles.count) bottle\(feed.bottles.count == 1 ? "" : "s") in Cask now. Prices already fetched are kept for bottles that stay. Nothing is sent to Whiskystats until prices are fetched.")
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
                Text("Find on Whiskystats").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Name, e.g. Lagavulin 16 — or a Whiskybase ID or link", text: $query).onSubmit(search)
                    Button(WhiskyStats.whiskyID(from: query) != nil ? "Look up (1 credit)" : "Search (1 credit)", action: search)
                        .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)
                }
                if let searchNote { Text(searchNote).font(.caption).foregroundStyle(.secondary) }
                if !hits.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(hits.prefix(40)) { h in
                                Button { pick(h) } label: {
                                    HStack(spacing: 8) {
                                        Text(h.whiskyId).font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
                                        Text(h.name).lineLimit(1)
                                        if h.whiskyId.hasPrefix("BG") { Text("group").font(.caption2).foregroundStyle(.secondary) }
                                        Spacer()
                                    }.contentShape(Rectangle()).padding(.vertical, 2)
                                        .background(bottle.whiskyId == h.whiskyId ? Color.accentColor.opacity(0.2) : .clear)
                                }.buttonStyle(.plain)
                            }
                        }
                    }.frame(height: 180)
                    Text("Same name, different ID: different bottlings or labels. A group (BG) covers bottlings that only differ in details; pick one from Whiskybase if you know it, else the group.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            Form {
                TextField("Whisky ID", text: $bottle.whiskyId)
                TextField("Name on the bar", text: $bottle.name)
                Stepper("Bottles: \(bottle.quantity)", value: $bottle.quantity, in: 1...999)
                TextField("Paid per bottle (€, optional)", value: $bottle.price, format: .number)
                Toggle("Bought on", isOn: $hasDate)
                if hasDate { DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: .date) }
            }
            if isNew { Text("Adding fetches the bottle's prices once (\(WhiskyStats.Cost.pricing + (feed.lotsOn ? WhiskyStats.Cost.lots : 0)) credits).").font(.caption).foregroundStyle(.secondary) }
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
