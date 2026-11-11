import SwiftUI
import UltraBarKit

/// Apps on the bar, laid out like Widgets: the list on the left (Deckhand's own apps, the vendor's
/// marketplace, the firmware's), the chosen app on the right with an "On the bar" switch and its
/// settings. Deckhand's apps install over ADB; marketplace apps are fetched by the bar itself (APP_MANAGER).
struct AppsView: View {
    static func barAppIcon(_ page: String) -> String {
        switch page {
        case "claude": return "sparkles"; case "crypto": return "bitcoinsign.circle"; case "weather": return "cloud.sun"; case "music": return "music.note"; case "calendar": return "calendar"
        case "flights": return "airplane"; case "sky": return "moon.stars"; case "news": return "newspaper"; case "verse": return "book.closed"; case "tasks": return "checklist"
        case "haven": return "ferry"
        default: return "waveform.path.ecg" }
    }
    static func blurb(_ page: String) -> String {
        switch page {
        case "monitor": return "This Mac, live: CPU history, memory, network up and down, disk and the clock."
        case "claude": return "Which terminal needs you: every Claude Code session of the last hour, the waiting ones pulsing orange, with the project name and what it last said."
        case "crypto": return "Your coins with today's chart — the same coins as the cube's Crypto cards."
        case "weather": return "The weather now plus three days, for the location of the Weather widget."
        case "music": return "What Music is playing: album art, title, play/pause, next and previous."
        case "calendar": return "Today and the next two days from the calendars you pick."
        case "flights": return "Aircraft overhead on a small radar, with flight number, airline, route, altitude and speed (adsb.lol and adsbdb, no key)."
        case "sky": return "Today's sun arc with rise, set, noon, golden hour and twilight, and the moon in its phase with rise, set and the next full and new moon."
        case "news": return "Headlines from the source you pick, four at a time, rotating."
        case "verse": return "A Bible verse for the day (World English Bible), one per day of the year."
        case "tasks": return "Your open Linear issues: started work first, then by priority and due date."
        case "haven": return "Ships at the ports and terminals you choose, live from AIS: what lies alongside and what is on its way in, with a rough arrival time. Tap a place for its approach."
        default: return ""
        }
    }

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @MainActor final class UI: ObservableObject { @Published var selected: String? }
    @StateObject private var ui = UI()

    /// One marketplace or firmware entry: catalogue and/or installed, merged by package.
    private struct Entry: Identifiable {
        let package: String, name: String, version: String, icon: URL?
        let installed: CoreBarSession.AppInfo?, store: BarAppStore.StoreApp?
        /// Turned off by Android (firmware apps only); the bar does not list it while it is off.
        var off = false
        var id: String { package }
        var system: Bool { off || (installed?.systemApp ?? false) }
    }
    private var entries: [Entry] {
        var out: [String: Entry] = [:]
        for s in model.storeApps { out[s.package] = Entry(package: s.package, name: s.name, version: s.versionName, icon: s.iconURL, installed: nil, store: s) }
        for a in model.barApps where !a.isScreensaver && !a.packageName.hasPrefix(BarPages.packagePrefix) {
            let s = out[a.packageName]?.store
            out[a.packageName] = Entry(package: a.packageName, name: s?.name ?? a.appName, version: a.versionName, icon: s?.iconURL ?? a.iconUrl.flatMap(URL.init), installed: a, store: s,
                                       off: model.turnedOffApps.contains(a.packageName))
        }
        for p in model.turnedOffApps where out[p]?.installed == nil {
            out[p] = Entry(package: p, name: model.turnedOffName(p) ?? out[p]?.name ?? p, version: "", icon: out[p]?.icon, installed: nil, store: out[p]?.store, off: true)
        }
        return out.values.sorted { ($0.installed == nil ? 1 : 0, $0.name.lowercased()) < ($1.installed == nil ? 1 : 0, $1.name.lowercased()) }
    }
    private func updateAvailable(_ e: Entry) -> Bool { e.installed != nil && model.marketUpdate(for: e.package) != nil }

    var body: some View {
        VStack(spacing: 0) {
            Header("Apps", "Apps run on the bar itself. Switch one on to install it; its settings are here too.") {
                HStack {
                    RefreshButton()
                    UpdateAllButton()
                }
            }
            LibraryErrorStrip()
            Divider()
            HSplitView {
                List(selection: $ui.selected) {
                    Section {
                        ForEach(AppModel.barAppPages, id: \.page) { app in
                            let v = model.barAppVersion(app.page)
                            LibraryRow(title: app.label, caption: v, inUse: v != nil, busy: model.barAppBusy == app.page, updateAvailable: model.barAppNeedsUpdate(app.page)) {
                                Image(systemName: Self.barAppIcon(app.page))
                            }.tag(BarPages.package(for: app.page))
                        }
                    } header: { Text("Deckhand apps") }
                    let market = entries.filter { !$0.system }, firmware = entries.filter(\.system)
                    Section {
                        if market.isEmpty { Text(model.link.isConnected ? (model.storeApps.isEmpty ? "Press Refresh to load the catalogue." : "Nothing in the catalogue.") : "Connect to the bar to list them.").font(.caption).foregroundStyle(.secondary) }
                        ForEach(market) { e in
                            LibraryRow(title: e.name, caption: e.installed == nil ? nil : e.version, inUse: e.installed != nil, busy: model.appBusy == e.package, updateAvailable: updateAvailable(e)) {
                                AppIcon(url: e.icon, fallback: "app", size: 18)
                            }.tag(e.package)
                        }
                    } header: { Text("Marketplace") }
                    if !firmware.isEmpty {
                        Section("Built into the firmware") {
                            ForEach(firmware) { e in
                                LibraryRow(title: e.name, caption: e.off ? "turned off" : e.version, inUse: !e.off, busy: model.appBusy == e.package, updateAvailable: updateAvailable(e)) {
                                    AppIcon(url: e.icon, fallback: "app.badge", size: 18)
                                }.tag(e.package)
                            }
                        }
                    }
                }
                .frame(minWidth: 240, maxWidth: 300)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let sel = ui.selected {
                            if let app = AppModel.barAppPages.first(where: { BarPages.package(for: $0.page) == sel }) { deckhandDetail(app) }
                            else if let e = entries.first(where: { $0.package == sel }) { entryDetail(e) }
                            else { Text("Pick an app on the left.").foregroundStyle(.secondary) }
                        } else { Text("Pick an app on the left.").foregroundStyle(.secondary) }
                        Spacer()
                    }.padding(20).frame(minWidth: 360, maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if model.storeApps.isEmpty { model.refreshAppStore() }
            if ui.selected == nil { ui.selected = BarPages.package(for: AppModel.barAppPages[0].page) }
        }
    }

    /// Put an app's icon on the Deckhand page, or take it off. Installing a Deckhand app puts it on, removing an app
    /// takes it off, so the page never shows an icon for an app that is not on the bar.
    private func setIcon(_ cardID: String, _ on: Bool) {
        if on { if !settings.coreCards.contains(cardID) { settings.coreCards.append(cardID) } }
        else { settings.coreCards.removeAll { $0 == cardID } }
    }

    /// The second line under "On the bar": whether the app's icon is on Deckhand's page in the bar's launcher.
    @ViewBuilder private func iconRow(_ cardID: String, known: Bool) -> some View {
        let onPage = settings.coreCards.contains(cardID)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                if known {
                    InstalledToggle(title: "Icon on the Deckhand page", isOn: onPage) { setIcon(cardID, $0) }
                    if onPage, !settings.deckhandPagePublished { Text("not published yet").font(.caption).foregroundStyle(.orange) }
                } else {
                    Text("Press Refresh to see its icon.").font(.caption).foregroundStyle(.secondary)
                }
                Button("Open CoreBar page") { model.nav = .coreBarPage }.buttonStyle(.borderless).font(.callout)
            }
            Text("The page of cards you swipe through on the bar; tap the icon there to open the app. Without it, the app is still in the bar's app list.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 20)
    }

    // MARK: Deckhand app

    @ViewBuilder private func deckhandDetail(_ app: (page: String, label: String, apk: String)) -> some View {
        let installed = model.barAppVersion(app.page), stale = model.barAppNeedsUpdate(app.page), busy = model.barAppBusy == app.page
        let pkg = BarPages.package(for: app.page), hasAPK = AppModel.bundledAPK(app.apk) != nil
        DetailTitle(title: app.label, version: installed, tag: stale ? ("update \(AppModel.barAppsVersion)", .orange) : (installed != nil ? ("up to date", .green) : ("not installed", .secondary)), subtitle: pkg) {
            AppIcon(url: model.barAppIconURL(app.page), fallback: Self.barAppIcon(app.page), size: 48)
        }
        Text(Self.blurb(app.page)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        let cardID = AppModel.appCardPrefix + pkg
        HStack(spacing: 14) {
            InstalledToggle(title: "On the bar", isOn: installed != nil, busy: busy, disabled: !hasAPK || model.barAppBusy != nil,
                            note: hasAPK ? nil : "No APK in this build.", confirmOff: "Remove \(app.label) from the bar?") { on in
                setIcon(cardID, on)
                if on { model.installBarApp(app.page) } else { model.uninstallBarApp(app.page) }
            }
            if stale, !busy {
                Button { model.installBarApp(app.page) } label: { Label("Update to \(AppModel.barAppsVersion)", systemImage: "arrow.down.circle") }
                    .buttonStyle(.borderedProminent).disabled(model.barAppBusy != nil)
            }
        }
        if installed != nil {
            iconRow(cardID, known: model.coreCard(cardID) != nil)
        } else {
            Text("Installs over the bar's debug bridge (Settings → Debug bridge), with its icon on the Deckhand page.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        Divider()
        appSettings(app.page)
    }

    /// The app's own settings. Apps that mirror a cube card share that card's settings.
    @ViewBuilder private func appSettings(_ page: String) -> some View {
        switch page {
        case "flights":
            Panel("Flights settings") {
                HStack { Stepper("Within \(settings.flightsRadiusKm) km", value: $settings.flightsRadiusKm, in: 1...25); Text("of the location below.").font(.caption).foregroundStyle(.secondary) }
                Text("The bar fetches the positions itself, every 10 s while the page is on screen.").font(.caption).foregroundStyle(.secondary)
            }
            LocationPanel()
        case "news":
            Panel("Headlines settings") {
                Picker("Source", selection: $settings.newsSource) { ForEach(NewsFeed.sources) { s in Text(s.name).tag(s.id) } }.frame(width: 260)
                Text("The bar fetches the headlines itself, every 10 minutes.").font(.caption).foregroundStyle(.secondary)
            }
        case "tasks":
            Panel("Tasks settings", footer: "Linear → Settings → Security & access → Personal API keys. The key is kept in a user-only file on this Mac and only sent to api.linear.app.") {
                HStack {
                    SecureField("Linear personal API key (lin_api_…)", text: $model.linearKey).frame(width: 320)
                    if let e = model.linearError { Text(e).font(.caption).foregroundStyle(.orange) }
                    else { Text(model.linearKey.isEmpty ? "No key yet." : "Saved.").font(.caption).foregroundStyle(.secondary) }
                }
            }
        case "haven":
            HavenSettings()
        case "sky":
            LocationPanel()
            Text("Sun and moon are computed on the bar for this location; nothing is fetched.").font(.caption).foregroundStyle(.secondary)
        case "weather": AddonSettingsPanel(t: .weather)
        case "crypto": AddonSettingsPanel(t: .crypto)
        case "calendar": AddonSettingsPanel(t: .calendar)
        case "claude": AddonSettingsPanel(t: .claude)
        case "music": AddonSettingsPanel(t: .music)
        case "verse":
            Text("No settings. One of 98 well-known passages, picked by the day of the year; the bar fetches the text from bible-api.com.").font(.caption).foregroundStyle(.secondary)
        default:
            Text("No settings: it shows this Mac as it is.").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Marketplace / firmware app

    @ViewBuilder private func entryDetail(_ e: Entry) -> some View {
        let busy = model.appBusy == e.package, update = updateAvailable(e)
        let tag: (String, Color) = update ? ("update \(e.store?.versionName ?? "")", .orange) : (model.staleCatalogueNote(e.package).map { ($0, .secondary) } ?? (e.off ? ("turned off", .secondary) : e.system ? ("built in", .secondary) : (e.installed != nil ? ("installed", .green) : ("not installed", .secondary))))
        DetailTitle(title: e.name, version: e.installed == nil ? e.store?.versionName : e.version, tag: tag, subtitle: e.package + (e.store == nil ? " · not in the marketplace" : "")) {
            AppIcon(url: e.icon, fallback: e.system ? "app.badge" : "app", size: 48)
        }
        if let s = e.store, !s.summary.isEmpty { Text(s.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        if e.system {
            InstalledToggle(title: "Turned on", isOn: !e.off, busy: busy, disabled: model.appBusy != nil || !AppModel.canTurnOff(e.package) || model.adbStatus.wifi != true,
                            note: !AppModel.canTurnOff(e.package) ? "The bar needs this app; it cannot be turned off." : (model.adbStatus.wifi != true ? "Needs the debug bridge (Settings)." : nil),
                            confirmOff: "Turn off \(e.name)? It disappears from the bar and does not run until you turn it on again here.") { on in
                if !on { setIcon(AppModel.appCardPrefix + e.package, false) }
                model.setAppTurnedOn(e.package, name: e.name, on)
            }
        }
        HStack(spacing: 14) {
            if !e.system {
            InstalledToggle(title: "On the bar", isOn: e.installed != nil, busy: busy, disabled: model.appBusy != nil || !model.link.isConnected || e.system || (e.installed == nil && e.store == nil),
                            note: e.system ? "Part of the firmware; it cannot be removed." : nil, confirmOff: "Remove \(e.name) from the bar?") { on in
                if !on { setIcon(AppModel.appCardPrefix + e.package, false) }
                if on { model.installApp(e.package, name: e.name) } else { model.uninstallApp(e.package, name: e.name) }
            }
            }
            if update, let s = e.store, !busy {
                Button { model.installApp(e.package, name: e.name) } label: { Label("Update to \(s.versionName)", systemImage: "arrow.down.circle") }
                    .buttonStyle(.borderedProminent).disabled(model.appBusy != nil)
            }
            if let a = e.installed, let port = a.port, let tok = a.sessionToken, let bar = model.selectedCoreBar,
               let url = URL(string: "http://\(model.address(for: bar.serialNo) ?? bar.lastIp):\(port)/?sessionToken=\(tok)") {
                Link(destination: url) { Label("Web UI", systemImage: "safari") }.buttonStyle(.bordered).help("Opens the app's own web page on the bar in your browser.")
            }
        }
        if let a = e.installed, a.allowProfile {
            iconRow(AppModel.appCardPrefix + a.packageName, known: true)
        }
        if let s = e.store, !s.changeLog.isEmpty {
            Panel("What's new in \(s.versionName)") { Text(s.changeLog).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        Text(e.system ? "Part of the bar's system image: updatable from the marketplace, not removable. Turning it off is Android's own switch: the app stays on the bar but does not run and is not shown, until you turn it on again." : "The bar downloads and installs the app itself (it needs internet), one at a time, in about ten seconds. No settings on this side; the app has its own on the bar.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Haven: the aisstream.io key and the places file.
private struct HavenSettings: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Panel("Haven settings", footer: "A free key from aisstream.io (sign in with GitHub). It is kept in a user-only file on this Mac and only sent to stream.aisstream.io; the bar asks Deckhand for the ships.") {
            HStack {
                SecureField("aisstream.io API key", text: $model.aisstreamKey).frame(width: 320)
                TimelineView(.periodic(from: .now, by: 3)) { _ in
                    let h = model.barPages.haven
                    if let e = h.lastError ?? h.placesError { Text(e).font(.caption).foregroundStyle(.orange) }
                    else if model.aisstreamKey.isEmpty { Text("No key yet.").font(.caption).foregroundStyle(.secondary) }
                    else if h.connected { Text("Connected · \(h.messages) messages").font(.caption).foregroundStyle(.green) }
                    else { Text("Saved. Connects while Haven is on the bar.").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        Panel("Places", footer: "Each place has an area (alongside when a ship lies still in it), an approach (moving ships in it that close in, or whose AIS destination contains one of the match words, are on their way) and a kind: port (only ships of minLength m and up) or terminal (barges). Boxes are [latMin, latMax, lonMin, lonMax]. The file stays on this Mac; Deckhand reads it again within 30 s of a change.") {
            let loaded = HavenFeed.loadPlaces()
            ForEach(loaded.places, id: \.id) { p in
                HStack { Image(systemName: p.kind == "port" ? "building.2" : "shippingbox").foregroundStyle(.secondary).frame(width: 18); Text(p.name); Text(p.kind).font(.caption).foregroundStyle(.secondary) }
            }
            HStack {
                Button { NSWorkspace.shared.activateFileViewerSelecting([HavenFeed.ensurePlacesFile()]) } label: { Label(loaded.fromFile ? "Show haven.json" : "Create haven.json", systemImage: "doc.text") }
                Text(loaded.fromFile ? HavenFeed.placesURL.path : "No places file: Haven watches the port of Rotterdam.").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }
}
