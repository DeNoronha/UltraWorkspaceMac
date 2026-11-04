import SwiftUI
import UltraBarKit

/// Library of cards Deckhand can draw: preview, settings, and "Add to the cube".
struct WidgetsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @StateObject private var pm = PreviewModel()
    /// The two screens take different things: the cube shows pictures drawn by this Mac,
    /// the bar draws its own live cards. The library lists both, in separate sections.
    enum Item: Hashable { case cube(Theme), bar(String) }
    @MainActor final class UI: ObservableObject { @Published var selected: Item = .cube(.weather) }
    @StateObject private var ui = UI()

    /// Cube cards whose numbers change by the second on the Mac but reach the cube only as a snapshot.
    private static let snapshotCards: Set<Theme> = [.claude]

    var body: some View {
        VStack(spacing: 0) {
            Header("Widgets", "Cards for the cube and the bar. Switch one on to show it; its settings are here too.")
            Divider()
            HSplitView {
                List(selection: Binding(get: { ui.selected as Item? }, set: { if let v = $0 { ui.selected = v; if case .cube(let t) = v { model.selectedAddon = t } } })) {
                    Section {
                        ForEach(Theme.library) { t in
                            HStack {
                                Label(t.title, systemImage: t.icon)
                                Spacer()
                                if Self.snapshotCards.contains(t) { Text("snapshot").font(.caption2).foregroundStyle(.secondary).help("Redrawn every 5 minutes at most — not a live meter.") }
                                if settings.vivoCards.contains(t) { Image(systemName: "circle.circle").font(.caption).foregroundStyle(.secondary).help("In the cube's card list") }
                            }.tag(Item.cube(t))
                        }
                    } header: { Text("For the VivoCube") } footer: { Text("Pictures drawn by this Mac, 240 × 240, re-sent every 5 minutes at most — so no live readings or clocks here; the bar has those.").font(.caption).foregroundStyle(.secondary) }
                    Section {
                        ForEach(AppSettings.allCoreCards) { c in
                            HStack {
                                Label { Text(c.title) } icon: { CardIcon(card: c) }
                                Spacer()
                                if settings.coreCards.contains(c.id) { Image(systemName: "rectangle.on.rectangle").font(.caption).foregroundStyle(.secondary).help("On the CoreBar page") }
                            }.tag(Item.bar(c.id))
                        }
                    } header: { Text("For the CoreBar") } footer: { Text("Cards the bar draws itself and updates live (CPU every 3 s, network every 5 s). Apps have their own cards: see Apps.").font(.caption).foregroundStyle(.secondary) }
                }
                .frame(minWidth: 220, maxWidth: 280)

                ScrollView {
                    if case .bar(let id) = ui.selected, let c = model.coreCard(id) {
                        barDetail(c)
                    } else {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 20) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black)
                                if let img = pm.image {
                                    Image(nsImage: img).resizable().interpolation(.high).frame(width: 200, height: 200).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                } else if pm.loading { ProgressView() } else { Text("—").foregroundStyle(.secondary) }
                            }
                            .frame(width: 220, height: 220)
                            .accessibilityLabel("Preview of \(model.selectedAddon.title)")
                            VStack(alignment: .leading, spacing: 10) {
                                Label(model.selectedAddon.title, systemImage: model.selectedAddon.icon).font(.title3).bold()
                                Text(blurb(model.selectedAddon)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                let t = model.selectedAddon, onCube = settings.vivoCards.contains(t)
                                InstalledToggle(title: "On the cube", isOn: onCube, disabled: !onCube && settings.vivoSlotsLeft == 0,
                                                note: !onCube && settings.vivoSlotsLeft == 0 ? "The cube is full (\(AppModel.maxVivoLayers) cards)." : nil) { on in
                                    if on {
                                        if t == .picture, settings.vivoPicturePath.isEmpty { Self.choosePicture(settings) }
                                        settings.addVivoCard(t); model.requestCardPermissions(t)
                                    } else { settings.removeVivoCard(t) }
                                }
                                if onCube {
                                    if model.lastCubeSentAt != nil, !model.cubeOffline, CoreBarSession.UploadDiag.shared.last.hasPrefix("accepted") {
                                        Label("On the cube", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                                    } else {
                                        Label(model.lastCubeSentAt == nil ? "In the cube's list — not sent yet" : "In the cube's list — the last send did not arrive", systemImage: "circle.circle").foregroundStyle(.orange).font(.callout)
                                    }
                                }
                                Button { reload() } label: { Label("Redraw preview", systemImage: "arrow.clockwise") }.buttonStyle(.borderless).font(.callout)
                            }
                        }
                        if Self.snapshotCards.contains(model.selectedAddon) {
                            Label("The cube gets this as a picture, redrawn every 5 minutes at most — a snapshot, not a live meter. For live numbers use the bar's own card (see “For the CoreBar”).", systemImage: "camera.metering.spot")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Divider()
                        AddonSettingsPanel(t: model.selectedAddon)
                        Spacer()
                    }.padding(20).frame(minWidth: 360, alignment: .leading)
                    }
                }
            }
        }
        .onAppear { ui.selected = .cube(model.selectedAddon); reload() }
        .onChange(of: model.selectedAddon) { _ in reload() }
        .onChange(of: settings.vivoPicturePath) { _ in reload() }
    }
    private func reload() { pm.reload { await model.previewImage(model.selectedAddon, settings: settings) } }

    static func choosePicture(_ settings: AppSettings) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .image]
        panel.allowsMultipleSelection = false
        panel.message = "Pick a picture for the cube (it is scaled to 240 × 240)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Copy next to our settings so the card keeps working if the original moves.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("UltraWorkspaceMac", isDirectory: true)
        let dest = base.appendingPathComponent("picture." + (url.pathExtension.isEmpty ? "png" : url.pathExtension))
        try? FileManager.default.removeItem(at: dest)
        if (try? FileManager.default.copyItem(at: url, to: dest)) != nil { settings.vivoPicturePath = dest.path } else { settings.vivoPicturePath = url.path }
    }

    /// Detail pane for a card the bar draws itself: no preview (the bar renders it), add/remove on the page.
    private func barDetail(_ c: AppSettings.CoreCard) -> some View {
        let onPage = settings.coreCards.contains(c.id)
        let hasSense = model.modules.contains { $0.type == "SENSE_CUBE" }
        let needsSense = c.id.hasPrefix("SENSE_") && !hasSense
        return VStack(alignment: .leading, spacing: 12) {
            Label { Text(c.title) } icon: { CardIcon(card: c, size: 22) }.font(.title3).bold()
            Text(c.note.isEmpty ? "Drawn by the bar itself from live data this Mac sends over the link." : c.note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("The bar renders this card at its own size on the 1424 × 280 strip and updates it live. Deckhand cannot change how it looks; it only puts the card on the Deckhand page.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            InstalledToggle(title: "On the CoreBar page", isOn: onPage, disabled: !onPage && needsSense, note: needsSense ? "No SenseCube found." : nil) { on in
                if on { settings.coreCards.append(c.id) } else { settings.coreCards.removeAll { $0 == c.id } }
            }
            HStack {
                if onPage {
                    Label(settings.deckhandPagePublished ? "On the CoreBar page" : "On the CoreBar page — not published yet", systemImage: "rectangle.on.rectangle").foregroundStyle(settings.deckhandPagePublished ? .green : .orange).font(.callout)
                }
                Button("Open CoreBar page") { model.nav = .coreBarPage }.buttonStyle(.borderless).font(.callout)
            }
        }.padding(20).frame(minWidth: 360, alignment: .leading)
    }

    private func blurb(_ t: Theme) -> String {
        switch t {
        case .weather: return "Current weather via Open-Meteo — free, no key. No clock on purpose: the cube gets a new picture every 5 minutes at most."
        case .music: return "What Music is playing, with album art."
        case .claude: return "Claude Code: tokens today, your plan, % of your own daily budget, active sessions, and which sessions wait for your input."
        case .crypto, .crypto2, .crypto3, .crypto4, .crypto5: return "Up to five coins, each as its own card: price now, today's low and high, change since midnight and a chart of today (CoinGecko, no key)."
        case .calendar: return "Your next events from the calendars you pick, each in its calendar's colour."
        case .date: return "Today's date: weekday, day, month and year, long or short."
        case .picture: return "A picture of your own, scaled to the cube's 240 × 240 panel."
        default: return "" // live-feed cards are not in the library (Theme.isLiveFeed)
        }
    }

}

/// The settings of one Mac-drawn card — shared by the Widgets page and the Apps page (a bar app
/// such as Weather or Crypto shows the same data as its cube card, so it has the same settings).
struct AddonSettingsPanel: View {
    let t: Theme
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @ViewBuilder var body: some View {
        switch t {
        case .weather:
            Panel("Weather settings") {
                Picker("Location", selection: $settings.locationMode) {
                    Text("Same as this Mac").tag(AppSettings.LocationMode.auto)
                    Text("Manual").tag(AppSettings.LocationMode.manual)
                }.pickerStyle(.radioGroup)
                if settings.locationMode == .manual {
                    TextField("City (e.g. Amsterdam)", text: $settings.manualCity).frame(width: 220)
                    HStack { TextField("Lat", text: $settings.manualLat).frame(width: 90); TextField("Lon", text: $settings.manualLon).frame(width: 90) }
                } else {
                    Text("Time zone: \(settings.macTimeZone)").font(.caption).foregroundStyle(.secondary)
                }
                Picker("Units", selection: $settings.units) { Text("°C").tag(AppSettings.Units.metric); Text("°F").tag(AppSettings.Units.imperial) }
                    .pickerStyle(.segmented).frame(width: 160)
                Toggle("24-hour clock", isOn: $settings.clock24h).toggleStyle(.switch)
            }
        case .music:
            Panel("Music") { MusicControls() }
        case .date:
            Panel("Date") {
                Picker("Style", selection: $settings.dateStyle) { Text("Long").tag(AppSettings.DateStyle.long); Text("Short").tag(AppSettings.DateStyle.short); Text("Numeric").tag(AppSettings.DateStyle.numeric) }
                    .pickerStyle(.segmented).frame(width: 260)
                Toggle("Weekday", isOn: $settings.dateShowWeekday).toggleStyle(.switch)
                Toggle("Year", isOn: $settings.dateShowYear).toggleStyle(.switch)
                Text("Language follows this Mac (\(Locale.current.identifier)).").font(.caption).foregroundStyle(.secondary)
            }
        case .crypto, .crypto2, .crypto3, .crypto4, .crypto5:
            Panel("Crypto", footer: "Each coin becomes its own card on the cube; they count towards the \(AppModel.maxVivoLayers) slots.") {
                ForEach(0..<5, id: \.self) { slot in
                    HStack {
                        Text("Coin \(slot + 1)").frame(width: 60, alignment: .leading)
                        Picker("", selection: Binding(get: { slot < settings.cryptoCoins.count ? settings.cryptoCoins[slot] : "" },
                                                      set: { v in var c = settings.cryptoCoins; while c.count < 5 { c.append("") }; c[slot] = v; settings.cryptoCoins = c })) {
                            Text("None").tag("")
                            ForEach(CryptoStats.knownCoins, id: \.id) { k in Text("\(k.symbol) — \(k.name)").tag(k.id) }
                            let cur = slot < settings.cryptoCoins.count ? settings.cryptoCoins[slot] : ""
                            if !cur.isEmpty, !CryptoStats.knownCoins.contains(where: { $0.id == cur }) { Text(cur).tag(cur) }
                        }.labelsHidden().frame(width: 200)
                        TextField("or a CoinGecko id", text: Binding(get: { slot < settings.cryptoCoins.count ? settings.cryptoCoins[slot] : "" },
                                                                   set: { v in var c = settings.cryptoCoins; while c.count < 5 { c.append("") }; c[slot] = v.lowercased(); settings.cryptoCoins = c })).frame(width: 160)
                    }
                }
                HStack {
                    Text("Currency").frame(width: 60, alignment: .leading)
                    Picker("", selection: $settings.cryptoCurrency) { ForEach(CryptoStats.currencies, id: \.self) { Text($0.uppercased()).tag($0) } }
                        .labelsHidden().frame(width: 100)
                }
            }
        case .calendar:
            Panel("Calendars") { CalendarPicker() }
        case .claude:
            Panel("Claude Code") {
                HStack {
                    Text("Plan").frame(width: 100, alignment: .leading)
                    Picker("", selection: $settings.claudePlan) { ForEach(AppSettings.ClaudePlan.allCases, id: \.self) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 160)
                }
                HStack {
                    Text("Daily budget").frame(width: 100, alignment: .leading)
                    TextField("tokens, e.g. 20000000", value: $settings.claudeDailyBudget, format: .number).frame(width: 160)
                    Text("0 = no percentage").font(.caption).foregroundStyle(.secondary)
                }
                Text("Anthropic does not publish per-plan token limits, so the % is against a budget you set yourself (input + output + cache writes, from ~/.claude transcripts).").font(.caption).foregroundStyle(.secondary)
                Toggle("Notify me when a session waits for my input", isOn: $settings.claudeNotifyWaiting).toggleStyle(.switch)
            }
        case .picture:
            Panel("Picture") {
                HStack {
                    Text(settings.vivoPicturePath.isEmpty ? "No picture chosen." : (settings.vivoPicturePath as NSString).lastPathComponent).foregroundStyle(.secondary)
                    Button("Choose…") { WidgetsView.choosePicture(settings) }
                }
            }
        default:
            EmptyView()
        }
    }
}

struct MusicControls: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.nowPlaying.hasTrack ? model.nowPlaying.title : "Nothing playing").fontWeight(.medium)
            Text(model.nowPlaying.hasTrack ? model.nowPlaying.artist : " ").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { model.musicPrevious() } label: { Image(systemName: "backward.fill") }.accessibilityLabel("Previous track")
                Button { model.musicPlayPause() } label: { Image(systemName: model.nowPlaying.isPlaying ? "pause.fill" : "play.fill") }.accessibilityLabel(model.nowPlaying.isPlaying ? "Pause" : "Play")
                Button { model.musicNext() } label: { Image(systemName: "forward.fill") }.accessibilityLabel("Next track")
                Button { model.musicVolume(-10) } label: { Image(systemName: "speaker.wave.1.fill") }.accessibilityLabel("Quieter")
                Button { model.musicVolume(10) } label: { Image(systemName: "speaker.wave.3.fill") }.accessibilityLabel("Louder")
            }.buttonStyle(.bordered)
        }
    }
}


/// Toggle list of the Mac's calendars with their colours; nothing ticked = all calendars.
struct CalendarPicker: View {
    @EnvironmentObject var settings: AppSettings
    @StateObject private var ui = UI()
    private final class UI: ObservableObject { @Published var cals: [CalendarSource.CalInfo] = []; @Published var auth: CalAuth = .notDetermined }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if ui.auth != .authorized {
                Text("Calendar access is off for Deckhand. Allow it in System Settings → Privacy & Security → Calendars.").foregroundStyle(.orange)
                Button("Ask for access") { Task { _ = await CalendarSource.requestAccess(); ui.auth = CalendarSource.authStatus(); ui.cals = CalendarSource.calendars() } }
            } else if ui.cals.isEmpty {
                Text("No calendars found.").foregroundStyle(.secondary)
            } else {
                Text(settings.calendarIDs.isEmpty ? "All calendars are shown. Tick some to limit the card." : "\(settings.calendarIDs.count) selected.").font(.caption).foregroundStyle(.secondary)
                ForEach(ui.cals) { c in
                    Toggle(isOn: Binding(get: { settings.calendarIDs.contains(c.id) },
                                         set: { on in if on { settings.calendarIDs.append(c.id) } else { settings.calendarIDs.removeAll { $0 == c.id } } })) {
                        HStack(spacing: 6) {
                            Circle().fill(Color(red: c.rgb.0, green: c.rgb.1, blue: c.rgb.2)).frame(width: 10, height: 10)
                            Text(c.title)
                            Text(c.source).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                if !settings.calendarIDs.isEmpty { Button("Show all") { settings.calendarIDs = [] }.buttonStyle(.link).font(.caption) }
            }
        }
        .onAppear { ui.auth = CalendarSource.authStatus(); ui.cals = CalendarSource.calendars() }
    }
}
