import SwiftUI
import UltraBarKit

/// CoreBar: the Deckhand page on the bar. What the bar shows, a preview drawn from the card list, the list itself
/// (drag, remove with Undo, add), and Publish in the toolbar. This is the one place where the bar's cards are chosen.
struct CoreBarPageView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @Environment(\.undoManager) private var undo
    @StateObject private var cover = PreviewModel()
    @StateObject private var ui = UI()
    private final class UI: ObservableObject { @Published var confirm = false; @Published var stripPage = 0 }

    var body: some View {
        Form {
            DeviceStatusSection(kind: .bar) {
                ProgressRow(progress: model.pageProgress, lastAt: model.lastPagePublishedAt, idle: "Published",
                            never: settings.deckhandPagePublished ? "Published before this session." : "Not published yet.")
            }
            preview
            cardsSection
            if settings.coreCards.contains("WEATHER") { weatherKeySection }
        }
        .formStyle(.grouped)
        .navigationSubtitle("Deckhand page")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { publish() } label: { Label("Publish", systemImage: "arrow.up.circle") }
                    .labelStyle(.titleAndIcon)
                    .prominentAction()
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.isWorking || model.pageProgress.isRunning || settings.coreCards.isEmpty)
                    .help("Send these cards, and the knob and key bindings, to the bar (⌘↩)")
            }.accentToolbarItem()
        }
        .onAppear { reloadCover(); if model.corebarPages.isEmpty { model.refreshPages() } }
        .publishConfirmation(isPresented: $ui.confirm)
    }

    private func publish() {
        if model.publishNeedsConfirmation(settings: settings) { ui.confirm = true } else { model.publishDeckhandPage(settings: settings) }
    }
    private func reloadCover() { cover.reload { guard let png = await model.renderPageCover(settings: settings) else { return nil }; return NSImage(data: png) } }

    // MARK: Preview strip

    private var preview: some View {
        let cards = settings.coreCards.compactMap(model.coreCard)
        // One screenful of the bar at a time; the bar scrolls sideways through the rest, so the preview pages through
        // them the same way. Screenfuls by slots: the clock card takes two.
        let per = AppSettings.coreCardsThatFit
        var screenfuls: [[AppSettings.CoreCard]] = [[]]; var used = 0
        for c in cards {
            let w = c.id == "TIME" ? 2 : 1
            if used + w > per, !screenfuls[screenfuls.count - 1].isEmpty { screenfuls.append([]); used = 0 }
            screenfuls[screenfuls.count - 1].append(c); used += w
        }
        let pages = screenfuls.count
        let page = min(ui.stripPage, pages - 1)
        let shown = screenfuls[page]
        return Section {
            // A fixed width keeps a long list from pushing the window wider (2026-11-03).
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black)
                HStack(spacing: 6) {
                    ForEach(shown, id: \.id) { c in
                        tile(c, cover: c.id == "TIME" ? cover.image : nil)
                            .frame(width: c.id == "TIME" ? 164 : 82, height: 82)
                    }
                    if cards.isEmpty { Text("No cards yet.").foregroundStyle(.white.opacity(0.7)).padding(.leading, 12) }
                }.padding(8)
            }
            .frame(width: 8 + CGFloat(per) * 88 + 8, height: 98).clipped()
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Preview: " + shown.map(\.title).joined(separator: ", "))
            HStack(spacing: 8) {
                if pages > 1 {
                    Button { ui.stripPage = max(0, page - 1) } label: { Image(systemName: "chevron.left") }.disabled(page == 0).accessibilityLabel("Previous screenful")
                    Text("Screenful \(page + 1) of \(pages)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    Button { ui.stripPage = min(pages - 1, page + 1) } label: { Image(systemName: "chevron.right") }.disabled(page >= pages - 1).accessibilityLabel("Next screenful")
                }
                Spacer()
                Button("Redraw Preview") { reloadCover() }.help("Draw the preview again from the card list")
            }
        } header: {
            Text("Preview")
        } footer: {
            Footnote("Drawn from the card list, not read back from the bar.")
        }
    }

    private func tile(_ c: AppSettings.CoreCard, cover: NSImage?) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.13))
            if let cover {
                Image(nsImage: cover).resizable().interpolation(.high).aspectRatio(contentMode: .fill).clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 4) {
                    CardIcon(card: c, size: 28).font(.title2).foregroundStyle(.white.opacity(0.9))
                    Text(c.title).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                }.padding(4)
            }
        }
    }

    // MARK: Cards on the page

    private var cardsSection: some View {
        let cards = settings.coreCards.compactMap(model.coreCard)
        return Section {
            if cards.isEmpty { Text("No cards yet. Add one below.").foregroundStyle(.secondary) }
            ReorderableRows(items: cards, id: \.id, directions: ("Left", "Right"), move: { moveCards(cards, $0, $1) }) { _, c in
                HStack(spacing: 8) {
                    Label { Text(c.title) } icon: { CardIcon(card: c) }
                    if c.needsMac {
                        Image(systemName: "bolt.horizontal").foregroundStyle(.secondary)
                            .help("Live from this Mac: updates only while Deckhand runs")
                            .accessibilityLabel("Live from this Mac")
                    }
                    if c.id == "WEATHER", settings.accuWeatherKey.isEmpty { Tag("Needs a key", .attention) }
                    Spacer()
                    if c.id == "TIME" {
                        Button("Update Picture") { model.refreshDeckhandCover(settings: settings); reloadCover() }
                            .disabled(!settings.deckhandPagePublished).help("Draw today's weather and date on the clock card again and upload it")
                    }
                    RemoveMark(title: c.title) { remove(c) }
                }
            } menu: { _, c in
                Divider()
                Button("Remove") { remove(c) }
            }
            addCardMenu
        } header: {
            Text("Cards on the Deckhand page")
        } footer: {
            Footnote("\(cards.count) card\(cards.count == 1 ? "" : "s"); about \(AppSettings.coreCardsThatFit) fit without scrolling. Drag to reorder. Which page the bar shows is on Bar System.")
        }
    }

    /// `from`/`to` count the cards shown. When every stored id is a known card (always, unless a card was dropped from
    /// Deckhand) that is the stored list itself; otherwise the shown cards are reordered and unknown ids kept after them.
    private func moveCards(_ cards: [AppSettings.CoreCard], _ from: IndexSet, _ to: Int) {
        if cards.count == settings.coreCards.count {
            var l = settings.coreCards; l.move(fromOffsets: from, toOffset: to); settings.coreCards = l
        } else {
            var shown = cards.map(\.id); shown.move(fromOffsets: from, toOffset: to)
            settings.coreCards = shown + settings.coreCards.filter { !shown.contains($0) }
        }
    }

    private func remove(_ c: AppSettings.CoreCard) {
        let before = settings.coreCards
        settings.coreCards.removeAll { $0 == c.id }
        registerUndo(undo, settings, \.coreCards, old: before, name: "Remove \(c.title)")
    }

    private var addCardMenu: some View {
        let available = model.allCoreCardsNow.filter { !settings.coreCards.contains($0.id) }
        let hasSense = model.modules.contains { $0.type == "SENSE_CUBE" }
        return Menu {
            ForEach(available) { c in
                let needsSense = c.id.hasPrefix("SENSE_") && !hasSense
                Button { settings.coreCards.append(c.id) } label: {
                    Label(c.title + (needsSense ? " (no SenseCube found)" : ""), systemImage: c.icon)
                }.disabled(needsSense)
                .help(c.note)
            }
        } label: { Label("Add a Card", systemImage: "plus") }
        .fixedSize()
        .disabled(available.isEmpty)
        .help(available.isEmpty ? "Every card is on the page." : "")
    }

    /// The bar's own weather card needs an AccuWeather key; shown only while that card is on the page.
    private var weatherKeySection: some View {
        Section {
            CommitSecureField("AccuWeather key", value: $settings.accuWeatherKey)
            Link("Get a Key", destination: URL(string: "https://developer.accuweather.com")!)
        } header: {
            Text("Weather (bar's own)")
        } footer: {
            Footnote("AccuWeather has a 14-day trial, then it is paid. The Clock card's weather is free.")
        }
    }
}
