import SwiftUI
import UltraBarKit

/// CoreBar page: preview strip drawn from the card list, the list itself
/// (drag, remove, add), one Publish button, details in disclosures.
struct CoreBarPageView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @StateObject private var cover = PreviewModel()
    @StateObject private var ui = UI()
    private final class UI: ObservableObject { @Published var confirm = false; @Published var keyOpen = false; @Published var stripPage = 0 }

    var body: some View {
        VStack(spacing: 0) {
            Header("CoreBar", "A row of the bar's own cards; about \(AppSettings.coreCardsThatFit) fit, more scroll sideways.") {
                Button { publish() } label: { Label("Publish page", systemImage: "arrow.up.circle.fill").frame(minWidth: 120) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.isWorking || model.pageProgress.isRunning || settings.coreCards.isEmpty)
                    .help("Send these cards to the bar (⌘↩)")
            }
            DeviceStrip(kind: .bar)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ProgressRow(progress: model.pageProgress, lastAt: model.lastPagePublishedAt, idle: "Published", never: settings.deckhandPagePublished ? "Published before this session." : "Not sent yet.")
                    preview
                    onPage
                    Panel("Pages on the bar") { pagesOnBar }
                    Panel("Maintenance") { advanced }
                }.padding(20)
            }
        }
        .onAppear { reloadCover(); if model.corebarPages.isEmpty { model.refreshPages() } }
        .alert("Replace the bar's pages?", isPresented: $ui.confirm) {
            Button("Replace pages", role: .destructive) { model.publishDeckhandPage(settings: settings) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.foreignPages.isEmpty
                 ? "The bar will have two pages: its Standard page and the Deckhand page. The bar cannot send pages back, so pages made in the official app would be removed — none were found right now."
                 : "These pages were made in the official app and will be removed: \(model.foreignPages.map(\.name).joined(separator: ", ")). Re-deploy them from that app if you still need them.")
        }
    }

    private func publish() {
        if model.publishNeedsConfirmation(settings: settings) { ui.confirm = true } else { model.publishDeckhandPage(settings: settings) }
    }
    private func reloadCover() { cover.reload { guard let png = await model.renderPageCover(settings: settings) else { return nil }; return NSImage(data: png) } }


    // MARK: Preview strip

    private var preview: some View {
        let cards = settings.coreCards.compactMap(model.coreCard)
        // One screenful of the bar at a time (about 4 cards on the 1424 × 280 strip); the bar scrolls
        // sideways through the rest, so the preview pages through them the same way. A fixed width keeps
        // a long list from pushing the split view wider than the window (2026-11-03).
        let per = AppSettings.coreCardsThatFit
        let pages = max(1, Int((Double(cards.count) / Double(per)).rounded(.up)))
        let page = min(ui.stripPage, pages - 1)
        let shown = Array(cards.dropFirst(page * per).prefix(per))
        return Panel("Preview", footer: "Drawn from the list below — not read back from the bar.") {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black)
                HStack(spacing: 6) {
                    ForEach(shown, id: \.id) { c in
                        tile(c, cover: c.id == "TIME" ? cover.image : nil)
                            .frame(width: c.id == "TIME" ? 164 : 82, height: 82)
                    }
                    if cards.isEmpty { Text("No cards yet — use Add a card… below.").foregroundStyle(.secondary).padding(.leading, 12) }
                }.padding(8)
            }
            .frame(width: 8 + CGFloat(per) * 88 + 82 + 8, height: 98).clipped()
            if pages > 1 {
                HStack(spacing: 8) {
                    Button { ui.stripPage = max(0, page - 1) } label: { Image(systemName: "chevron.left") }.disabled(page == 0).accessibilityLabel("Previous screenful")
                    Text("Screenful \(page + 1) of \(pages) · the bar scrolls sideways through them").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Button { ui.stripPage = min(pages - 1, page + 1) } label: { Image(systemName: "chevron.right") }.disabled(page >= pages - 1).accessibilityLabel("Next screenful")
                }
            }
        }
    }

    private func tile(_ c: AppSettings.CoreCard, cover: NSImage?) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.13))
            if let cover {
                Image(nsImage: cover).resizable().interpolation(.high).aspectRatio(contentMode: .fill).clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 4) {
                    Image(systemName: c.icon).font(.title2).foregroundStyle(.white.opacity(0.9))
                    Text(c.title).font(.caption2).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }.padding(4)
            }
        }
    }

    // MARK: Cards on the page

    private var onPage: some View {
        let cards = settings.coreCards.compactMap(model.coreCard)
        return Panel("Cards on the bar", footer: "Drag to reorder. \(cards.count) card\(cards.count == 1 ? "" : "s") · about \(AppSettings.coreCardsThatFit) fit without scrolling. ⌁ = live from this Mac, only while Deckhand runs.") {
            if cards.isEmpty { Text("Nothing on the bar yet — add a card.").foregroundStyle(.secondary) }
            List {
                ForEach(Array(cards.enumerated()), id: \.element.id) { i, c in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                            Label(c.title, systemImage: c.icon)
                            if c.needsMac { Image(systemName: "bolt.horizontal").font(.caption).foregroundStyle(.orange).help("Live from this Mac") }
                            if c.id == "WEATHER" {
                                if settings.accuWeatherKey.isEmpty { Text("needs key").font(.caption2).foregroundStyle(.orange) }
                                Button(ui.keyOpen ? "Hide key" : "Key…") { ui.keyOpen.toggle() }.buttonStyle(.link).font(.caption)
                            }
                            if c.id == "TIME" {
                                Button("Update picture") { model.refreshDeckhandCover(settings: settings); reloadCover() }.buttonStyle(.link).font(.caption)
                                    .disabled(!settings.deckhandPagePublished).help("Re-draws today's weather & date on the clock card")
                            }
                            Spacer()
                            Button { settings.coreCards.removeAll { $0 == c.id } } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.borderless).accessibilityLabel("Remove \(c.title)")
                        }
                        if c.id == "WEATHER", ui.keyOpen {
                            VStack(alignment: .leading, spacing: 4) {
                                TextField("AccuWeather API key", text: $settings.accuWeatherKey).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                                HStack(spacing: 6) {
                                    Text("AccuWeather: 14-day trial, paid afterwards. Deckhand's own weather on the Clock card is free.").font(.caption).foregroundStyle(.secondary)
                                    Link("Get a key", destination: URL(string: "https://developer.accuweather.com")!).font(.caption)
                                }
                            }.padding(.leading, 26)
                        }
                    }
                    .accessibilityActions {
                        Button("Move left") { settings.moveCoreCard(c.id, by: -1) }
                        Button("Move right") { settings.moveCoreCard(c.id, by: 1) }
                    }
                }
                .onMove { from, to in var l = settings.coreCards; l.move(fromOffsets: from, toOffset: to); settings.coreCards = l }
            }
            .listStyle(.inset).scrollContentBackground(.hidden)
            .frame(height: CGFloat(max(1, cards.count)) * 28 + (ui.keyOpen ? 60 : 0) + 10)
            addCardMenu
        }
    }

    /// Same control as on the VivoCube page: one "Add a card…" menu.
    private var addCardMenu: some View {
        let available = model.allCoreCardsNow.filter { !settings.coreCards.contains($0.id) }
        let hasSense = model.modules.contains { $0.type == "SENSE_CUBE" }
        return Menu {
            ForEach(available) { c in
                let needsSense = c.id.hasPrefix("SENSE_") && !hasSense
                Button { settings.coreCards.append(c.id) } label: {
                    Label(c.title + (needsSense ? " (no SenseCube found)" : (c.note.isEmpty ? "" : " — " + c.note)), systemImage: c.icon)
                }.disabled(needsSense)
            }
        } label: { Label("Add a card…", systemImage: "plus") }
        .frame(width: 150).disabled(available.isEmpty)
        .help(available.isEmpty ? "Every card is on the page." : "")
    }

    // MARK: Disclosures

    private var pagesOnBar: some View {
        Group {
            if model.corebarPages.isEmpty { Text("Not read yet.").foregroundStyle(.secondary) }
            ForEach(model.corebarPages, id: \.id) { p in
                HStack {
                    Image(systemName: model.currentPageId == p.id ? "checkmark.circle.fill" : "circle").foregroundStyle(model.currentPageId == p.id ? .green : .secondary)
                    Text(p.name)
                    if ![AppModel.defaultPageId, AppModel.deckhandPageId].contains(p.id) { Text("from the official app").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Show") { model.switchPage(id: p.id) }.buttonStyle(.link)
                }
            }
            Text("Publishing rewrites all pages (the bar cannot send them back). The official app's Deploy removes Deckhand's pictures — publish again afterwards.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var advanced: some View {
        Group {
            HStack(spacing: 10) {
                Button { model.refreshModules() } label: { Label(model.isWorking ? "Looking…" : "Find modules", systemImage: "magnifyingglass") }.disabled(model.isWorking)
                Button { model.refreshPages() } label: { Label("Re-read pages", systemImage: "arrow.clockwise") }
                Button { reloadCover() } label: { Label("Redraw preview", systemImage: "photo") }
            }
            Text("Knob and key bindings are published with the page — see Controls.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
