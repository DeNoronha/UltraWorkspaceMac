import SwiftUI
import UltraBarKit

/// Library of cards Deckhand can draw: preview, settings, and "Add to the cube".
struct WidgetsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @StateObject private var pm = PreviewModel()

    var body: some View {
        VStack(spacing: 0) {
            Header("Widgets", "Cards Deckhand draws for the cube.")
            Divider()
            HSplitView {
                List(selection: Binding(get: { model.selectedAddon as Theme? }, set: { if let v = $0 { model.selectedAddon = v } })) {
                    ForEach(Theme.library) { t in
                        HStack {
                            Label(t.title, systemImage: t.icon)
                            Spacer()
                            if settings.vivoCards.contains(t) { Image(systemName: "circle.circle").font(.caption).foregroundStyle(.secondary).help("In the cube's card list") }
                        }.tag(t)
                    }
                }
                .frame(minWidth: 200, maxWidth: 260)

                ScrollView {
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
                                HStack {
                                    if settings.vivoCards.contains(model.selectedAddon) {
                                        if model.lastCubeSentAt != nil, !model.cubeOffline, CoreBarSession.UploadDiag.shared.last.hasPrefix("accepted") {
                                            Label("On the cube", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                                        } else {
                                            Label(model.lastCubeSentAt == nil ? "In the cube's list — not sent yet" : "In the cube's list — the last send did not arrive", systemImage: "circle.circle").foregroundStyle(.orange)
                                        }
                                        Button("Remove") { settings.removeVivoCard(model.selectedAddon) }
                                    } else {
                                        Button { if model.selectedAddon == .picture, settings.vivoPicturePath.isEmpty { Self.choosePicture(settings) }; settings.addVivoCard(model.selectedAddon); model.requestCardPermissions(model.selectedAddon) } label: { Label("Add to the cube", systemImage: "plus") }
                                            .buttonStyle(.borderedProminent).disabled(settings.vivoSlotsLeft == 0)
                                        if settings.vivoSlotsLeft == 0 { Text("The cube is full (\(AppModel.maxVivoLayers) cards).").font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Button { reload() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).accessibilityLabel("Redraw preview")
                                }
                            }
                        }
                        Divider()
                        addonSettings(model.selectedAddon)
                        Spacer()
                    }.padding(20).frame(minWidth: 360, alignment: .leading)
                }
            }
        }
        .onAppear { reload() }
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

    private func blurb(_ t: Theme) -> String {
        switch t {
        case .weather: return "Live weather and clock via Open-Meteo — free, no key."
        case .music: return "What Music is playing, with album art."
        case .cpu: return "CPU and memory use of this Mac."
        case .network: return "Download and upload speed of this Mac."
        case .claude: return "Claude Code: tokens today, your plan, % of your own daily budget, active sessions, and which sessions wait for your input."
        case .battery: return "Battery charge and power state (a desktop Mac shows “On AC power”)."
        case .disk: return "How full the startup disk is."
        case .worldclock: return "The time in three cities of your choice."
        case .crypto, .crypto2, .crypto3, .crypto4, .crypto5: return "Up to five coins, each as its own card: price now, today's low and high, change since midnight and a chart of today (CoinGecko, no key)."
        case .calendar: return "Your next events from the calendars you pick, each in its calendar's colour."
        case .clock: return "A clock face — analog or digital, 12 or 24 hours."
        case .date: return "Today's date: weekday, day, month and year, long or short."
        case .diskio: return "Live disk read/write throughput."
        case .topcpu: return "The apps using the most CPU right now."
        case .uptime: return "How long this Mac has been running, with load averages."
        case .picture: return "A picture of your own, scaled to the cube's 240 × 240 panel."
        }
    }

    @ViewBuilder private func addonSettings(_ t: Theme) -> some View {
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
        case .worldclock:
            Panel("World clock") {
                ForEach(0..<3, id: \.self) { i in
                    HStack {
                        Text("City \(i + 1)").frame(width: 60, alignment: .leading)
                        TimeZonePicker(selection: Binding(get: { i < settings.worldClockZones.count ? settings.worldClockZones[i] : "" },
                                                          set: { v in var z = settings.worldClockZones; while z.count < 3 { z.append("") }; z[i] = v; settings.worldClockZones = z }))
                    }
                }
                Toggle("24-hour clock", isOn: $settings.clock24h).toggleStyle(.switch)
            }
        case .clock:
            Panel("Clock") {
                Picker("Style", selection: $settings.clockStyle) { Text("Analog").tag(AppSettings.ClockStyle.analog); Text("Digital").tag(AppSettings.ClockStyle.digital) }
                    .pickerStyle(.segmented).frame(width: 200)
                Toggle("24-hour clock", isOn: $settings.clock24h).toggleStyle(.switch)
                Toggle("Show seconds", isOn: $settings.clockSeconds).toggleStyle(.switch)
                Text("The cube's picture is redrawn only when Deckhand sends it again (every few minutes), so seconds are a snapshot, not a running hand.").font(.caption).foregroundStyle(.secondary)
            }
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
                    Button("Choose…") { Self.choosePicture(settings) }
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


/// Searchable time-zone picker (600+ identifiers): a text filter plus a menu of matches.
struct TimeZonePicker: View {
    @Binding var selection: String
    @StateObject private var ui = UI()
    private final class UI: ObservableObject { @Published var filter = "" }
    private var matches: [String] {
        let all = TimeZone.knownTimeZoneIdentifiers
        let f = ui.filter.trimmingCharacters(in: .whitespaces).lowercased()
        if f.isEmpty { return all }
        return all.filter { $0.lowercased().replacingOccurrences(of: "_", with: " ").contains(f) }
    }
    var body: some View {
        HStack {
            TextField("Search city", text: $ui.filter).frame(width: 130)
            Picker("", selection: $selection) {
                if !selection.isEmpty, !matches.contains(selection) { Text(selection).tag(selection) }
                ForEach(matches.prefix(200), id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")).tag($0) }
            }.labelsHidden().frame(width: 230)
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
