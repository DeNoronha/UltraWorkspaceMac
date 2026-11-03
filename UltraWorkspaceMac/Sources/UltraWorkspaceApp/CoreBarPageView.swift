import SwiftUI
import UltraBarKit

/// CoreBar page: preview strip drawn from the card list, the list itself
/// (drag, remove, add), one Publish button, details in disclosures.
struct CoreBarPageView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @StateObject private var cover = PreviewModel()
    @StateObject private var ui = UI()
    private final class UI: ObservableObject { @Published var confirm = false; @Published var pages = false; @Published var advanced = false; @Published var keyOpen = false }

    var body: some View {
        VStack(spacing: 0) {
            Header("CoreBar page", "A row of the bar's own cards. About \(AppSettings.coreCardsThatFit) fit; more scroll sideways.") { pagePicker }
            DeviceStrip(kind: .bar)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    preview
                    HStack(alignment: .top, spacing: 18) {
                        onPage
                        addCard.frame(width: 260)
                    }
                    HStack(alignment: .top, spacing: 14) {
                        Button { publish() } label: { Label("Publish page", systemImage: "arrow.up.circle.fill").frame(minWidth: 120) }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(model.isWorking || settings.coreCards.isEmpty)
                        ProgressRow(progress: model.pageProgress, lastAt: model.lastPagePublishedAt, idle: "Published", never: settings.deckhandPagePublished ? "Published before this session." : "Not sent yet.").padding(.top, 6)
                    }
                    Panel("Pages on the bar") { pagesOnBar }
                    Panel("Advanced") { advanced }
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

    // MARK: Showing picker

    @ViewBuilder private var pagePicker: some View {
        if !model.corebarPages.isEmpty {
            Picker("Showing", selection: Binding(get: { model.currentPageId ?? "" }, set: { if !$0.isEmpty { model.switchPage(id: $0) } })) {
                ForEach(model.corebarPages, id: \.id) { Text($0.name).tag($0.id) }
            }.pickerStyle(.segmented).frame(maxWidth: 320)
            .help(model.currentPageId == nil ? "The bar does not report its page; pick one to switch." : "Switch the page on the bar")
        }
    }

    // MARK: Preview strip

    private var preview: some View {
        let cards = settings.coreCards.compactMap(AppSettings.coreCard)
        return Panel("Preview") {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black)
                HStack(spacing: 6) {
                    ForEach(Array(cards.enumerated()), id: \.element.id) { i, c in
                        tile(c, cover: c.id == "TIME" ? cover.image : nil)
                            .frame(width: c.id == "TIME" ? 164 : 82, height: 82)
                            .opacity(i >= AppSettings.coreCardsThatFit ? 0.35 : 1)
                    }
                    if cards.isEmpty { Text("No cards — add some on the right.").foregroundStyle(.secondary).padding(.leading, 12) }
                }.padding(8)
            }
            .frame(height: 98).clipped()
            if cards.count > AppSettings.coreCardsThatFit {
                Text("Dimmed cards scroll into view sideways on the bar.").font(.caption).foregroundStyle(.secondary)
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
        let cards = settings.coreCards.compactMap(AppSettings.coreCard)
        return Panel("Cards on the page", footer: "Drag to reorder. ⌁ = live from this Mac, only while Deckhand runs.") {
            if cards.isEmpty { Text("Nothing on the page yet — add a card.").foregroundStyle(.secondary) }
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
        }
    }

    private var addCard: some View {
        let available = AppSettings.allCoreCards.filter { !settings.coreCards.contains($0.id) }
        let hasSense = model.modules.contains { $0.type == "SENSE_CUBE" }
        return Panel("Add a card") {
            if available.isEmpty { Text("Every card is on the page.").foregroundStyle(.secondary) }
            ForEach(available) { c in
                let needsSense = c.id.hasPrefix("SENSE_") && !hasSense
                HStack(alignment: .top, spacing: 8) {
                    Button { settings.coreCards.append(c.id) } label: { Image(systemName: "plus.circle") }
                        .buttonStyle(.borderless).disabled(needsSense).accessibilityLabel("Add \(c.title)")
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Label(c.title, systemImage: c.icon)
                            if c.needsMac { Image(systemName: "bolt.horizontal").font(.caption).foregroundStyle(.orange) }
                        }
                        if needsSense { Text("No SenseCube found").font(.caption2).foregroundStyle(.secondary) }
                        else if !c.note.isEmpty { Text(c.note).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                }
            }
        }
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
            Text("The knob and keys get their bindings with every page publish: knob turn → Mac volume, press → mute; DotKey 1/2 → cube card 1/2, 3 → next card, hold 3 → Standard page.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
