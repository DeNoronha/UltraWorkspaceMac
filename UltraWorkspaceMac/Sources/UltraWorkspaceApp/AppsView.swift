import SwiftUI
import UltraBarKit

/// Apps on the bar: the list on the left (Deckhand's own apps, the vendor's marketplace, the firmware's), the chosen
/// app on the right with Install / Update / Remove…, "Show on Deckhand page" and its settings. Deckhand's apps install
/// over the debug bridge; marketplace apps are fetched by the bar itself (APP_MANAGER). The toolbar filter (All /
/// On the Bar / Updates) replaced the Installed page.
struct AppsView: View {
    static func barAppIcon(_ page: String) -> String {
        switch page {
        case "claude": return "sparkles"; case "crypto": return "bitcoinsign.circle"; case "weather": return "cloud.sun"; case "music": return "music.note"; case "calendar": return "calendar"
        case "flights": return "airplane"; case "sky": return "moon.stars"; case "news": return "newspaper"; case "verse": return "book.closed"; case "tasks": return "checklist"
        case "haven": return "ferry"
        case "tide": return "water.waves"
        case "strava": return "figure.run"
        case "cask": return "chart.line.uptrend.xyaxis"
        case "schiphol": return "airplane.departure"
        case "teletekst": return "tv"
        case "earth": return "globe.europe.africa"
        case "seo": return "chart.line.uptrend.xyaxis"
        case "portfolio": return "chart.pie"
        default: return "waveform.path.ecg" }
    }
    /// The app's own launcher icon (bundled by make-app.sh), so the list shows the same picture as the bar; the
    /// SF Symbol above is only the fallback for a build without it (`swift run`).
    static func bundledIcon(_ page: String) -> URL? {
        Bundle.main.url(forResource: page, withExtension: "png", subdirectory: "bar-app-icons")
    }
    static func blurb(_ page: String) -> String {
        switch page {
        case "monitor": return "This Mac, live: CPU history, memory, network up and down, disk and the clock."
        case "claude": return "Which terminal needs you: every Claude Code session of the last hour, the waiting ones pulsing orange, with the project name and what it last said."
        case "crypto": return "Your coins with today's chart — the same coins as the cube's Crypto cards."
        case "weather": return "The weather now plus three days, for your location."
        case "music": return "What Music is playing: album art, title, play/pause, next and previous."
        case "calendar": return "Today and the next two days from the calendars you pick."
        case "flights": return "Aircraft overhead on a small radar, with flight number, airline, route, altitude and speed (adsb.lol and adsbdb, no key)."
        case "sky": return "Today's sun arc with rise, set, noon, golden hour and twilight, and the moon in its phase with rise, set and the next full and new moon."
        case "news": return "Headlines from the source you pick, four at a time, rotating."
        case "verse": return "A Bible verse for the day (World English Bible), one per day of the year."
        case "tasks": return "Your open Linear issues: started work first, then by priority and due date."
        case "tide": return "Water levels at the Rijkswaterstaat gauges you choose: the level now in cm NAP and which way it goes, today's curve against the predicted tide, the next high and low water, and a small almanac with sun and moon."
        case "strava": return "Your own Strava activities: the latest with its route, this week against last week per sport, and the year so far. Powered by Strava."
        case "schiphol": return "Amsterdam Schiphol: which runways are in use for landing and take-off, the aircraft on and around them, the last 15 minutes' movements, and with a Schiphol API key the next arrivals and departures."
        case "portfolio": return "Your Kraken account at a glance: what it is worth, how it moved over a day, week, month or year, and per coin its price, value and change, with the market's 24-hour high and low, VWAP, volume and spread."
        case "seo": return "Your website's health and search traffic: Google's Lighthouse scores and Core Web Vitals, a check of the page itself, and from Search Console the clicks, impressions, position and top search terms."
        case "earth": return "The whole planet, live: a turning globe and a world map with the aircraft in the air, the satellites overhead, the earthquakes of the last day and where it is night."
        case "teletekst": return "NOS Teletekst as it looks on television: the news index and its stories, sport and the weather map, in the teletext colours and blocks, two columns at a time, turning by itself."
        case "haven": return "Ships at the ports and terminals you choose, live from AIS: what lies alongside and what is on its way in, with a rough arrival time. Tap a place for its approach."
        case "cask": return "Your whisky collection at auction prices (Whiskystats): what it is worth, against what you paid and a month ago, with each bottle's trend. Tap a bottle for its auctions."
        default: return ""
        }
    }

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @MainActor final class UI: ObservableObject { @Published var filter: LibraryFilter = .all; @Published var search = "" }
    @StateObject private var ui = UI()

    /// One marketplace or firmware entry: catalogue and/or installed, merged by package.
    private struct Entry: Identifiable {
        let package: String, name: String, version: String, icon: URL?
        let installed: CoreBarSession.AppInfo?, store: BarAppStore.StoreApp?
        /// Turned off by Android (firmware apps only); the bar does not list it while it is off.
        var off = false
        /// On the bar but left out of the launcher's list (see `AppModel.unlistedBarApps`): firmware, can be turned off.
        var unlisted = false
        var id: String { package }
        var system: Bool { off || unlisted || (installed?.systemApp ?? false) }
    }
    private var entries: [Entry] {
        var out: [String: Entry] = [:]
        for s in model.storeApps { out[s.package] = Entry(package: s.package, name: s.name, version: s.versionName, icon: s.iconURL, installed: nil, store: s) }
        for a in model.barApps where !a.isScreensaver && !a.packageName.hasPrefix(BarPages.packagePrefix) {
            let s = out[a.packageName]?.store
            out[a.packageName] = Entry(package: a.packageName, name: s?.name ?? a.appName, version: a.versionName, icon: s?.iconURL ?? a.iconUrl.flatMap(URL.init), installed: a, store: s,
                                       off: model.turnedOffApps.contains(a.packageName))
        }
        for (p, name) in model.unlistedBarApps where out[p] == nil {
            out[p] = Entry(package: p, name: name, version: "", icon: nil, installed: nil, store: nil, unlisted: true)
        }
        for p in model.turnedOffApps where out[p]?.installed == nil {
            out[p] = Entry(package: p, name: model.turnedOffName(p) ?? out[p]?.name ?? p, version: "", icon: out[p]?.icon, installed: nil, store: out[p]?.store, off: true)
        }
        return out.values.sorted { ($0.installed == nil ? 1 : 0, $0.name.lowercased()) < ($1.installed == nil ? 1 : 0, $1.name.lowercased()) }
    }
    private func updateAvailable(_ e: Entry) -> Bool { e.installed != nil && model.marketUpdate(for: e.package) != nil }
    private func matches(_ name: String) -> Bool {
        let q = ui.search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || name.localizedCaseInsensitiveContains(q)
    }
    private func shown(_ e: Entry) -> Bool {
        guard matches(e.name) else { return false }
        switch ui.filter {
        case .all: return true
        case .onBar: return e.installed != nil || e.unlisted
        case .updates: return updateAvailable(e)
        }
    }
    private func shown(page: String) -> Bool {
        guard matches(AppModel.barAppPages.first { $0.page == page }?.label ?? page) else { return false }
        switch ui.filter {
        case .all: return true
        case .onBar: return model.barAppVersion(page) != nil
        case .updates: return model.barAppNeedsUpdate(page)
        }
    }

    var body: some View {
        LibraryLayout {
            LibraryFilterBar(filter: $ui.filter, search: $ui.search)
        } list: {
            List(selection: $model.selectedApp) {
                let ours = AppModel.barAppPages.filter { shown(page: $0.page) }
                if !ours.isEmpty {
                    Section("Deckhand apps") {
                        ForEach(ours, id: \.page) { app in
                            let v = model.barAppVersion(app.page)
                            LibraryRow(title: app.label, caption: v, installed: v != nil, busy: model.barAppBusy == app.page, updateAvailable: model.barAppNeedsUpdate(app.page)) {
                                AppIcon(url: Self.bundledIcon(app.page), title: app.label, fallback: Self.barAppIcon(app.page), size: 22)
                            }.tag(BarPages.package(for: app.page))
                        }
                    }
                }
                let all = entries.filter(shown)
                let market = all.filter { !$0.system }, firmware = all.filter(\.system)
                if !market.isEmpty || ui.filter == .all {
                    Section("Marketplace") {
                        if market.isEmpty { Text(model.link.isConnected ? (model.storeApps.isEmpty ? "Press Refresh to load the catalogue." : "Nothing in the catalogue.") : "Connect to the bar to list them.").font(.callout).foregroundStyle(.secondary) }
                        ForEach(market) { e in
                            LibraryRow(title: e.name, caption: e.installed == nil ? nil : e.version, installed: e.installed != nil, busy: model.appBusy == e.package, updateAvailable: updateAvailable(e)) {
                                AppIcon(url: e.icon, title: e.name, size: 22)
                            }.tag(e.package)
                        }
                    }
                }
                if !firmware.isEmpty {
                    Section("Built into the firmware") {
                        ForEach(firmware) { e in
                            LibraryRow(title: e.name, caption: e.off ? "Turned off" : e.version, installed: !e.off, busy: model.appBusy == e.package, updateAvailable: updateAvailable(e)) {
                                AppIcon(url: e.icon, title: e.name, size: 22)
                            }.tag(e.package)
                        }
                    }
                }
                if ours.isEmpty, all.isEmpty {
                    Text(!ui.search.isEmpty ? "No app matches “\(ui.search)”." : ui.filter == .updates ? "Everything is up to date." : "Nothing on the bar yet.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
        } detail: {
            Form {
                LibraryErrorSection()
                if let sel = model.selectedApp, let app = AppModel.barAppPages.first(where: { BarPages.package(for: $0.page) == sel }) { deckhandDetail(app) }
                else if let sel = model.selectedApp, let e = entries.first(where: { $0.package == sel }) { entryDetail(e) }
                else { Section { Text("Choose an app on the left.").foregroundStyle(.secondary) } }
            }
            .formStyle(.grouped)
        }
        .navigationSubtitle("Run on the bar itself")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { UpdateAllButton(screensavers: false) }.accentToolbarItem()
        }
        .onAppear {
            if model.storeApps.isEmpty { model.refreshAppStore() }
            if model.selectedApp == nil { model.selectedApp = BarPages.package(for: AppModel.barAppPages[0].page) }
        }
    }

    /// Put an app's card on the Deckhand page, or take it off. Installing a Deckhand app puts it on, removing an app
    /// takes it off, so the page never shows a card for an app that is not on the bar.
    private func setCard(_ cardID: String, _ on: Bool) {
        if on { if !settings.coreCards.contains(cardID) { settings.coreCards.append(cardID) } }
        else { settings.coreCards.removeAll { $0 == cardID } }
    }

    /// "Show on Deckhand page": whether the app's card is on Deckhand's page in the bar's launcher. Instant, so a switch.
    @ViewBuilder private func cardSection(_ cardID: String, known: Bool) -> some View {
        let onPage = settings.coreCards.contains(cardID)
        Section {
            if known {
                Toggle("Show on Deckhand page", isOn: Binding(get: { onPage }, set: { setCard(cardID, $0) }))
                if onPage, !settings.deckhandPagePublished {
                    HStack {
                        StatusLabel("Not published yet.", .attention)
                        Spacer()
                        Button("Open CoreBar") { model.nav = .coreBarPage }
                    }
                }
            } else {
                StatusLabel("Press Refresh to see its card.", .info)
            }
        } footer: {
            Footnote("Tap the card on the bar to open the app. Without it, the app is still in the bar's app list.")
        }
    }

    // MARK: Deckhand app

    @ViewBuilder private func deckhandDetail(_ app: (page: String, label: String, apk: String)) -> some View {
        let installed = model.barAppVersion(app.page), stale = model.barAppNeedsUpdate(app.page), busy = model.barAppBusy == app.page
        let pkg = BarPages.package(for: app.page), hasAPK = AppModel.bundledAPK(app.apk) != nil
        let adbOK = model.adbStatus.wifi == true && !model.adbStatus.unauthorized
        let cardID = AppModel.appCardPrefix + pkg
        Section {
            DetailTitle(title: app.label, version: installed, tag: stale ? ("Update \(AppModel.barAppsVersion)", .update) : (installed != nil ? ("On the bar", .ok) : ("Not installed", .info))) {
                AppIcon(url: Self.bundledIcon(app.page) ?? model.barAppIconURL(app.page), title: app.label, fallback: Self.barAppIcon(app.page), size: 52)
            }
            Text(Self.blurb(app.page)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            InstallControls(name: app.label, installed: installed != nil, updateTo: stale ? AppModel.barAppsVersion : nil, busy: busy,
                            canInstall: hasAPK && model.barAppBusy == nil,
                            note: !hasAPK ? "This build has no copy of the app." : (installed == nil && !adbOK ? "Installs over the debug bridge (Settings → Debug Bridge)." : nil),
                            install: { setCard(cardID, true); model.installBarApp(app.page) },
                            remove: { setCard(cardID, false); model.uninstallBarApp(app.page) })
        }
        if installed != nil { cardSection(cardID, known: model.coreCard(cardID) != nil) }
        appSettings(app.page)
        AppDetailsSection(package: pkg)
    }

    /// The app's own settings. Apps that mirror a cube card share that card's settings.
    @ViewBuilder private func appSettings(_ page: String) -> some View {
        switch page {
        case "flights":
            Section {
                Stepper(value: $settings.flightsRadiusKm, in: 1...25) { LabeledContent("Radius", value: "\(settings.flightsRadiusKm) km") }
                LocationSummaryRow()
            } header: { Text("Flights") } footer: { Footnote("The bar fetches the aircraft itself, every 10 s while the page is open.") }
        case "news":
            Section {
                Picker("Source", selection: $settings.newsSource) { ForEach(NewsFeed.sources) { s in Text(s.name).tag(s.id) } }
            } header: { Text("Headlines") } footer: { Footnote("The bar fetches the headlines itself, every 10 minutes.") }
        case "tasks":
            Section {
                SecureField("Linear API key", text: $model.linearKey, prompt: Text("lin_api_…"))
                if let e = model.linearError { StatusLabel(e, .failed) }
                else if model.linearKey.isEmpty { StatusLabel("No key yet.", .info) }
            } header: { Text("Tasks") } footer: { Footnote("Linear → Settings → Security & access → Personal API keys. Kept in this Mac's Keychain.") }
        case "haven":
            HavenSettings()
        case "tide":
            TideSettings()
        case "strava":
            StravaSettings(feed: model.barPages.strava)
        case "cask":
            CaskSettings(feed: model.barPages.cask)
        case "schiphol":
            SchipholSettings()
        case "teletekst":
            TeletekstSettings()
        case "seo":
            SeoSettings(feed: model.barPages.seo)
        case "portfolio":
            PortfolioSettings(feed: model.barPages.portfolio)
        case "earth":
            Section {
                Picker("Globe", selection: $settings.earthCenter) {
                    Text("Centred on my location").tag("home")
                    Text("Turning").tag("turn")
                }
                LocationSummaryRow()
                Picker("Earthquakes", selection: $settings.earthMinMag) {
                    Text("Magnitude 2.5 and up").tag(2.5)
                    Text("Magnitude 4.5 and up").tag(4.5)
                }
            } header: { Text("Earth") } footer: { Footnote("The bar fetches everything itself, without a key: aircraft from OpenSky every 15 minutes, earthquakes from USGS every 10, satellites from CelesTrak twice a day, only while Earth is open. Tap the globe on the bar to switch between the two; tap an earthquake to turn the globe to it.") }
        case "sky":
            Section { LocationSummaryRow() } header: { Text("Sun & Moon") } footer: { Footnote("Computed on the bar for this location; nothing is fetched.") }
        case "weather": CardSettingsSections(t: .weather)
        case "crypto": CardSettingsSections(t: .crypto)
        case "calendar": CardSettingsSections(t: .calendar)
        case "claude": CardSettingsSections(t: .claude)
        case "music": CardSettingsSections(t: .music)
        case "verse":
            Section { Text("No settings. One of 98 well-known passages, picked by the day of the year.").foregroundStyle(.secondary) }
        default:
            Section { Text("No settings: it shows this Mac as it is.").foregroundStyle(.secondary) }
        }
    }

    // MARK: Marketplace / firmware app

    @ViewBuilder private func entryDetail(_ e: Entry) -> some View {
        let busy = model.appBusy == e.package, update = updateAvailable(e)
        let tag: (String, StatusKind) = update ? ("Update \(e.store?.versionName ?? "")", .update)
            : (model.staleCatalogueNote(e.package).map { ($0, .info) } ?? (e.off ? ("Turned off", .info) : e.system ? ("Built in", .info) : (e.installed != nil ? ("On the bar", .ok) : ("Not installed", .info))))
        let webUI: URL? = {
            guard let a = e.installed, let port = a.port, let tok = a.sessionToken, let bar = model.selectedCoreBar else { return nil }
            return URL(string: "http://\(model.address(for: bar.serialNo) ?? bar.lastIp):\(port)/?sessionToken=\(tok)")
        }()
        Section {
            DetailTitle(title: e.name, version: e.installed == nil ? e.store?.versionName : e.version, tag: tag) {
                AppIcon(url: e.icon, title: e.name, size: 52)
            }
            if let s = e.store, !s.summary.isEmpty { Text(s.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if e.system {
                FirmwareControls(name: e.name, isOn: !e.off, busy: busy,
                                 disabled: model.appBusy != nil || !AppModel.canTurnOff(e.package) || model.adbStatus.wifi != true,
                                 note: !AppModel.canTurnOff(e.package) ? "The bar needs this app; it cannot be turned off." : (model.adbStatus.wifi != true ? "Needs the debug bridge (Settings → Debug Bridge)." : nil)) { on in
                    if !on { setCard(AppModel.appCardPrefix + e.package, false) }
                    model.setAppTurnedOn(e.package, name: e.name, on)
                }
                if update, let s = e.store {
                    Button("Update to \(s.versionName)") { model.installApp(e.package, name: e.name) }.primaryInline().disabled(model.appBusy != nil)
                }
            } else {
                InstallControls(name: e.name, installed: e.installed != nil, updateTo: update ? e.store?.versionName : nil, busy: busy,
                                canInstall: model.appBusy == nil && model.link.isConnected && (e.installed != nil || e.store != nil),
                                install: { model.installApp(e.package, name: e.name) },
                                remove: { setCard(AppModel.appCardPrefix + e.package, false); model.uninstallApp(e.package, name: e.name) })
            }
        } footer: {
            Footnote(e.system ? "Part of the bar's firmware: it can be updated and turned off, not removed." : "The bar downloads and installs the app itself, in about ten seconds.")
        }
        if let a = e.installed, a.allowProfile { cardSection(AppModel.appCardPrefix + a.packageName, known: true) }
        if let s = e.store, !s.changeLog.isEmpty {
            Section("What's new in \(s.versionName)") { Text(s.changeLog).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        AppDetailsSection(package: e.package, inMarketplace: e.store != nil, webUI: webUI)
    }
}

/// Haven: the aisstream.io key and the places.
private struct HavenSettings: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Section {
            SecureField("aisstream.io key", text: $model.aisstreamKey)
            TimelineView(.periodic(from: .now, by: 3)) { _ in
                let h = model.barPages.haven
                if let e = h.lastError ?? h.placesError { StatusLabel(e, .failed) }
                else if model.aisstreamKey.isEmpty { StatusLabel("No key yet.", .info) }
                else if h.isLive { StatusLabel("Connected · \(h.messages) messages", .ok) }
                else { StatusLabel("Saved. Connects while Haven is on the bar.", .info) }
            }
        } header: {
            Text("Haven")
        } footer: {
            Footnote("A free key from aisstream.io. Kept in this Mac's Keychain; the bar asks Deckhand for the ships.")
        }
        HavenPlacesPanel()
    }
}
