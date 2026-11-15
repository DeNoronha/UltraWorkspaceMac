import SwiftUI
import UltraBarKit

/// Cube Cards (was Widgets): the pictures Deckhand draws for the VivoCube, each with a preview, "Show on cube" and its
/// settings. Which cards the cube shows, and in what order, is the VivoCube page; the bar's own cards are chosen on
/// the CoreBar page only (the old "For the CoreBar" list duplicated Add a Card there).
struct CubeCardsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @StateObject private var pm = PreviewModel()

    var body: some View {
        LibraryLayout {
            List(selection: Binding(get: { model.selectedAddon as Theme? }, set: { if let v = $0 { model.selectedAddon = v } })) {
                Section("For the VivoCube") {
                    ForEach(Theme.library) { t in
                        HStack {
                            Label(t.title, systemImage: t.icon)
                            Spacer()
                            if settings.vivoCards.contains(t) {
                                Image(systemName: "checkmark.circle").foregroundStyle(.secondary).help("On the cube")
                            }
                        }
                        .tag(t)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(t.title + (settings.vivoCards.contains(t) ? ", on the cube" : ""))
                    }
                }
            }
            .listStyle(.inset)
        } detail: {
            Form {
                header
                CardSettingsSections(t: model.selectedAddon)
            }
            .formStyle(.grouped)
        }
        .navigationSubtitle("Pictures this Mac draws for the VivoCube")
        .onAppear { reload() }
        .onChange(of: model.selectedAddon) { _ in reload() }
        .onChange(of: settings.vivoPicturePath) { _ in reload() }
    }
    private func reload() { pm.reload { await model.previewImage(model.selectedAddon, settings: settings) } }

    private var header: some View {
        let t = model.selectedAddon, onCube = settings.vivoCards.contains(t)
        return Section {
            HStack(alignment: .top, spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black)
                    if let img = pm.image {
                        Image(nsImage: img).resizable().interpolation(.high).frame(width: 160, height: 160).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else if pm.loading { ProgressView() } else { Text("—").foregroundStyle(.white.opacity(0.6)) }
                }
                .frame(width: 176, height: 176)
                .accessibilityLabel("Preview of \(t.title)")
                VStack(alignment: .leading, spacing: 8) {
                    Label(t.title, systemImage: t.icon).font(.title2).bold()
                    Text(Self.blurb(t)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Redraw Preview") { reload() }.help("Draw the card again with the current settings")
                }
            }
            Toggle("Show on cube", isOn: Binding(get: { onCube }, set: { on in
                if on {
                    if t == .picture, settings.vivoPicturePath.isEmpty { Self.choosePicture(settings) }
                    settings.addVivoCard(t); model.requestCardPermissions(t)
                } else { settings.removeVivoCard(t) }
            }))
            .disabled(!onCube && settings.vivoSlotsLeft == 0)
            if !onCube && settings.vivoSlotsLeft == 0 {
                StatusLabel("The cube is full (\(AppModel.maxVivoLayers) cards). Remove one on the VivoCube page.", .info)
            } else if onCube {
                HStack {
                    if model.lastCubeSentAt != nil, !model.cubeOffline, CoreBarSession.UploadDiag.shared.last.hasPrefix("accepted") {
                        StatusLabel("On the cube.", .ok)
                    } else {
                        StatusLabel(model.lastCubeSentAt == nil ? "In the cube's list, not sent yet." : "In the cube's list; the last send did not arrive.", .attention)
                    }
                    Spacer()
                    Button("Open VivoCube") { model.nav = .vivoCube }
                }
            }
        } footer: {
            Footnote("The cube gets a new picture every 5 minutes at most, so these cards show slow-changing things.")
        }
    }

    static func choosePicture(_ settings: AppSettings) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a picture for the cube (it is scaled to 240 × 240)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Copy next to our settings so the card keeps working if the original moves.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("UltraWorkspaceMac", isDirectory: true)
        let dest = base.appendingPathComponent("picture." + (url.pathExtension.isEmpty ? "png" : url.pathExtension))
        try? FileManager.default.removeItem(at: dest)
        if (try? FileManager.default.copyItem(at: url, to: dest)) != nil { settings.vivoPicturePath = dest.path } else { settings.vivoPicturePath = url.path }
    }

    static func blurb(_ t: Theme) -> String {
        switch t {
        case .weather: return "The weather now, from Open-Meteo (free, no key)."
        case .music: return "What Music is playing, with the album art."
        case .claude: return "Claude Code: tokens today, against your own daily budget, and which sessions wait for you. A snapshot, redrawn every 5 minutes at most."
        case .crypto, .crypto2, .crypto3, .crypto4, .crypto5: return "Up to five coins, each its own card: the price, today's range and chart (CoinGecko, no key)."
        case .calendar: return "Your next events from the calendars you choose, in their colours."
        case .date: return "Today's date: weekday, day, month and year."
        case .picture: return "A picture of your own, scaled to the cube's 240 × 240 screen."
        default: return "" // live-feed cards are not in the library (Theme.isLiveFeed)
        }
    }
}

/// The settings of one card Deckhand draws, as Form sections — shared by Cube Cards and Apps (a bar app such as
/// Weather or Crypto shows the same data as its cube card, so it has the same settings).
struct CardSettingsSections: View {
    let t: Theme
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings

    private func coin(_ slot: Int) -> String { slot < settings.cryptoCoins.count ? settings.cryptoCoins[slot] : "" }
    private func setCoin(_ slot: Int, _ v: String) { var c = settings.cryptoCoins; while c.count < 5 { c.append("") }; c[slot] = v; settings.cryptoCoins = c }

    @ViewBuilder var body: some View {
        switch t {
        case .weather:
            Section {
                LocationSummaryRow()
                LabeledContent("Units") {
                    HStack(spacing: 8) {
                        Text("\(settings.units == .metric ? "°C" : "°F") · \(settings.clock24h ? "24-hour" : "12-hour") clock").foregroundStyle(.secondary)
                        Button("Change…") { SettingsWindow.open(.location) }
                    }
                }
            } header: { Text("Weather") } footer: { Footnote("Location and units are set once, in Settings → Location & Units.") }
        case .music:
            Section("Music") { MusicControls() }
        case .date:
            Section("Date") {
                Picker("Style", selection: $settings.dateStyle) { Text("Long").tag(AppSettings.DateStyle.long); Text("Short").tag(AppSettings.DateStyle.short); Text("Numeric").tag(AppSettings.DateStyle.numeric) }
                    .pickerStyle(.segmented)
                Toggle("Weekday", isOn: $settings.dateShowWeekday)
                Toggle("Year", isOn: $settings.dateShowYear)
            }
        case .crypto, .crypto2, .crypto3, .crypto4, .crypto5:
            Section {
                ForEach(0..<5, id: \.self) { slot in
                    LabeledContent("Coin \(slot + 1)") {
                        HStack {
                            Picker("Coin \(slot + 1)", selection: Binding(get: { coin(slot) }, set: { setCoin(slot, $0) })) {
                                Text("None").tag("")
                                ForEach(CryptoStats.knownCoins, id: \.id) { k in Text("\(k.symbol) — \(k.name)").tag(k.id) }
                                if !coin(slot).isEmpty, !CryptoStats.knownCoins.contains(where: { $0.id == coin(slot) }) { Text(coin(slot)).tag(coin(slot)) }
                            }.labelsHidden()
                            TextField("CoinGecko id", text: Binding(get: { coin(slot) }, set: { setCoin(slot, $0.lowercased()) }), prompt: Text("or a CoinGecko id"))
                                .labelsHidden().accessibilityLabel("Coin \(slot + 1), CoinGecko id")
                        }
                    }
                }
                Picker("Currency", selection: $settings.cryptoCurrency) { ForEach(CryptoStats.currencies, id: \.self) { Text($0.uppercased()).tag($0) } }
            } header: { Text("Coins") } footer: { Footnote("Each coin is its own card on the cube and uses one of its \(AppModel.maxVivoLayers) slots.") }
        case .calendar:
            Section("Calendars") { CalendarPicker() }
        case .claude:
            Section {
                Picker("Plan", selection: $settings.claudePlan) { ForEach(AppSettings.ClaudePlan.allCases, id: \.self) { Text($0.title).tag($0) } }
                TextField("Daily budget", value: $settings.claudeDailyBudget, format: .number, prompt: Text("Tokens, e.g. 20000000"))
                Toggle("Notify me when a session waits for me", isOn: $settings.claudeNotifyWaiting)
            } header: { Text("Claude Code") } footer: { Footnote("Anthropic publishes no per-plan limits, so the % is against your own budget; 0 shows no %.") }
        case .picture:
            Section("Picture") {
                LabeledContent("Picture") {
                    HStack {
                        Text(settings.vivoPicturePath.isEmpty ? "None chosen" : (settings.vivoPicturePath as NSString).lastPathComponent).foregroundStyle(.secondary)
                        Button(settings.vivoPicturePath.isEmpty ? "Choose…" : "Change…") { CubeCardsView.choosePicture(settings) }
                    }
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
            Text(model.nowPlaying.hasTrack ? model.nowPlaying.artist : " ").font(.callout).foregroundStyle(.secondary)
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
                StatusLabel("Calendar access is off for Deckhand. Allow it in System Settings → Privacy & Security → Calendars.", .attention)
                Button("Ask for Access") { Task { _ = await CalendarSource.requestAccess(); ui.auth = CalendarSource.authStatus(); ui.cals = CalendarSource.calendars() } }
            } else if ui.cals.isEmpty {
                Text("No calendars found.").foregroundStyle(.secondary)
            } else {
                Text(settings.calendarIDs.isEmpty ? "All calendars are shown. Tick some to limit the card." : "\(settings.calendarIDs.count) selected.").font(.callout).foregroundStyle(.secondary)
                ForEach(ui.cals) { c in
                    Toggle(isOn: Binding(get: { settings.calendarIDs.contains(c.id) },
                                         set: { on in if on { settings.calendarIDs.append(c.id) } else { settings.calendarIDs.removeAll { $0 == c.id } } })) {
                        HStack(spacing: 6) {
                            Circle().fill(Color(red: c.rgb.0, green: c.rgb.1, blue: c.rgb.2)).frame(width: 10, height: 10)
                            Text(c.title)
                            Text(c.source).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                if !settings.calendarIDs.isEmpty { Button("Show All") { settings.calendarIDs = [] } }
            }
        }
        .onAppear { ui.auth = CalendarSource.authStatus(); ui.cals = CalendarSource.calendars() }
    }
}
