import Foundation
import AppKit
import Combine
import UltraBarKit

/// The data API for the bar's Deckhand apps (bar apps 2.0). Every app carries its own page in its APK and loads it
/// locally; the ones that show what only this Mac knows (Monitor, Claude, Music, Calendar, Tasks, Haven) ask this Mac for
/// their data, served by `MonitorServer`. `BarPages` keeps that data fresh on its own cadence (calendar every
/// minute, Claude sessions and Music every 2 s, Linear every 20 s to 2 min, Haven's AIS stream live) so a request never
/// waits on the network.
/// The six on-bar apps (Flights, Crypto, Weather, Sun & Moon, Headlines, Verse) fetch their own data; Deckhand only
/// gives them their settings (`configDocument`).
///
/// Routes: `/config.json`, `/<page>/data.json`, `/music/art.jpg`; actions `/music/cmd/<play|next|previous>` and
/// `/tasks/done/<id>`. Monitor's `/monitor/stats.json` is answered in `AppModel.startBarDataServer`.
@MainActor
final class BarPages {
    /// Pages whose data comes from this Mac through `route` (Monitor's samples are served by `AppModel.startBarDataServer`).
    nonisolated static let macPages: Set<String> = ["claude", "music", "calendar", "tasks", "haven", "strava", "cask", "schiphol", "seo", "portfolio", "actions", "jira", "climate", "books", "traffic", "connection", "chess"]
    nonisolated static let packagePrefix = "nl.denoronha.deckhand."
    nonisolated static func package(for page: String) -> String { packagePrefix + page }
    /// Pages whose bar app fetches its own data on the bar: the APK carries the page and the feeds, and gets only
    /// its settings from this Mac (pushed over ADB, or read as `/config.json`).
    nonisolated static let onBar: Set<String> = ["flights", "crypto", "weather", "sky", "news", "verse", "tide", "teletekst", "earth", "status"]

    private var claude: [String: Any] = ["sessions": [], "tokens": "", "active": 0, "waiting": 0]
    private var calendar: [String: Any] = ["days": []]
    private var music: [String: Any] = ["playing": false, "hasTrack": false]
    private var art: (key: String, jpeg: Data)?
    private var linear: [String: Any] = ["issues": [], "hasKey": false]
    /// When each page's data was last asked for: the Linear poll runs fast while the Tasks page is open. Every
    /// request also wakes the feeds (`poke`), whose loops sleep until then instead of checking every 2 to 5 s.
    private var lastHit: [String: Date] = [:] { didSet { poke() } }
    /// Woken by every bar request (and a changed API key).
    private let hits = WakeSignal()
    /// Woken when the bar config may have changed: a setting, the Tide or Teletekst file, `repushConfig`.
    private let configWake = WakeSignal()
    private var subscriptions: [AnyCancellable] = []
    /// Wakes the loops that wait for a bar request: this class's own, the feeds', the Music poll.
    private func poke() { hits.signal(); haven.poke(); strava.poke(); schiphol.poke(); seo.poke(); portfolio.poke(); actions.poke(); jira.poke(); climate.poke(); books.poke(); traffic.poke(); connection.poke(); chess.poke(); model?.musicWake.signal() }
    /// Nobody can be looking at the bar apps: the bar's screen is off (presence over ADB) or this Mac is asleep,
    /// has its screens off or is locked, and no bar app asked for anything in the last two minutes (Deckhand Home
    /// asks every minute while it is on screen). The feeds pause then; the next request wakes them.
    private var dormant: Bool {
        guard let model, model.barScreenOn == false || PowerState.shared.idle else { return false }
        return lastHit.values.max().map { Date().timeIntervalSince($0) > 120 } ?? true
    }
    /// `wanted`, and someone can see it.
    private func feedWanted(_ page: String) -> Bool { wanted(page) && !dormant }
    /// Seconds since a page last asked for its data (nil: never) — `AppModel.musicWanted` slows the Music poll on it.
    func secondsSinceHit(_ page: String) -> TimeInterval? { lastHit[page].map { Date().timeIntervalSince($0) } }
    private var tasks: [Task<Void, Never>] = []
    /// When the Claude/Music and Calendar feeds last produced data.
    private var updated: [String: Date] = [:]
    /// The Claude/Music and Calendar feeds run only while their bar app asked for data in the last ten minutes,
    /// so a Mac without those apps on a bar spends nothing on them.
    private func wanted(_ page: String) -> Bool {
        if lastHit[page].map({ Date().timeIntervalSince($0) < 600 }) ?? false { return true }
        // Deckhand Home's tiles show the next event and the waiting Claude sessions, so they keep those feeds going.
        return (page == "calendar" || page == "claude") && homeWanted
    }
    /// Deckhand Home asked for its tiles in the last ten minutes (it asks every minute while it is on screen).
    private var homeWanted: Bool { lastHit["home"].map { Date().timeIntervalSince($0) < 600 } ?? false }
    /// The weather at the configured location for Home's Weather tile, asked every 10 minutes while Home is shown.
    private var homeWeather: OpenMeteo.Now?
    /// The feed behind each gated page.
    private nonisolated static let feedOf: [String: String] = ["claude": "claude", "music": "claude", "calendar": "calendar"]
    /// What the on-bar apps need from this Mac, at most every few minutes: where, which units, which coins.
    private var barConfig: [String: Any] = [:]
    /// Ships near the Haven places (aisstream.io), held open while the Haven app is on the bar.
    let haven = HavenFeed()
    /// The athlete's own Strava activities for the Training app, polled every 12 min while it is on the bar.
    let strava = StravaFeed()
    /// The Cask bottles and their Whiskystats auction prices, cached on disk and refreshed within a credit budget.
    let cask = CaskFeed()
    /// Schiphol's runways and traffic (adsb.lol) and, with the user's key, its timetable; polled while the app is on the bar.
    let schiphol = SchipholFeed()
    /// One website's health and its Search Console numbers for the SEO app, refreshed while it is on the bar.
    let seo = SiteFeed()
    /// The user's Kraken holdings and the market around them for the Portfolio app, refreshed while it is on the bar.
    let portfolio = KrakenFeed()
    /// The user's GitHub workflow runs for the GitHub Actions app, refreshed while it is on the bar.
    let actions = ActionsFeed()
    /// One Jira board's columns and cards for the Jira Board app, refreshed while it is on the bar.
    let jira = JiraFeed()
    /// The house's heating (tado) and the Netatmo station for the Climate app, refreshed while it is on the bar.
    let climate = ClimateFeed()
    /// The e-Boekhouden administration's bank, results and open invoices for the Books app, refreshed while it is on the bar.
    let books = BooksFeed()
    /// This Mac's network traffic per host, service and app for the Traffic app, sampled only while it is on screen.
    let traffic = TrafficFeed()
    /// The path to the internet hop by hop and the ASUS router for the Connection app, measured only while it is on screen.
    let connection = ConnectionFeed()
    /// One Chess.com player's ratings, games and the puzzle of the day for the Chess app, refreshed while it is on the bar.
    let chess = ChessFeed()
    private weak var model: AppModel?
    private var settings: AppSettings?

    func start(model: AppModel, settings: AppSettings) {
        stop()
        self.model = model; self.settings = settings
        haven.start(key: { model.aisstreamKey }, wanted: { [weak self] in
            guard let self, !self.dormant else { return false }
            return model.barAppVersion("haven") != nil || (self.lastHit["haven"].map { Date().timeIntervalSince($0) < 600 } ?? false)
        })
        portfolio.start(currency: { [weak self] in self?.settings?.portfolioCurrency ?? "EUR" }, minValue: { [weak self] in self?.settings?.portfolioMinValue ?? 10 }, wanted: { [weak self] in
            guard let self, !self.dormant else { return false }
            return model.barAppVersion("portfolio") != nil || (self.lastHit["portfolio"].map { Date().timeIntervalSince($0) < 600 } ?? false)
        })
        actions.start(days: { [weak self] in self?.settings?.actionsDays ?? 7 }, forks: { [weak self] in self?.settings?.actionsForks ?? false }, wanted: { [weak self] in
            guard let self, !self.dormant else { return false }
            return model.barAppVersion("actions") != nil || (self.lastHit["actions"].map { Date().timeIntervalSince($0) < 600 } ?? false)
        })
        jira.start(site: { [weak self] in self?.settings?.jiraSite ?? "" }, board: { [weak self] in self?.settings?.jiraBoard ?? 0 },
                   onlyMine: { [weak self] in self?.settings?.jiraOnlyMine ?? false }, wanted: { [weak self] in
            guard let self, !self.dormant else { return false }
            return model.barAppVersion("jira") != nil || (self.lastHit["jira"].map { Date().timeIntervalSince($0) < 600 } ?? false)
        })
        // Traffic samples every 5 s, so only while the app was asked in the last two minutes (it asks every 5 s on screen),
        // not merely installed.
        connection.start(address: { [weak self] in self?.settings?.routerAddress ?? "" }, https: { [weak self] in self?.settings?.routerHTTPS ?? false }, wanted: { [weak self] in
            guard let self, !self.dormant else { return false }
            return self.lastHit["connection"].map { Date().timeIntervalSince($0) < 120 } ?? false
        })
        traffic.start(window: { [weak self] in self?.settings?.trafficWindow ?? 10 }, wanted: { [weak self] in
            guard let self, !self.dormant else { return false }
            return self.lastHit["traffic"].map { Date().timeIntervalSince($0) < 120 } ?? false
        })
        chess.start(user: { [weak self] in self?.settings?.chessUser ?? "" }, showPuzzle: { [weak self] in self?.settings?.chessPuzzle ?? true }, wanted: { [weak self] in
            guard let self, !self.dormant else { return false }
            return model.barAppVersion("chess") != nil || (self.lastHit["chess"].map { Date().timeIntervalSince($0) < 600 } ?? false)
        })
        books.start(hide: { [weak self] in self?.settings?.booksHide ?? false }, wanted: { [weak self] in
            guard let self, !self.dormant else { return false }
            return model.barAppVersion("books") != nil || (self.lastHit["books"].map { Date().timeIntervalSince($0) < 600 } ?? false)
        })
        climate.start(wanted: { [weak self] in
            guard let self, !self.dormant else { return false }
            return model.barAppVersion("climate") != nil || (self.lastHit["climate"].map { Date().timeIntervalSince($0) < 600 } ?? false)
        })
        seo.start(url: { [weak self] in self?.settings?.seoURL ?? "" }, wanted: { [weak self] in
            guard let self, !self.dormant else { return false }
            return model.barAppVersion("seo") != nil || (self.lastHit["seo"].map { Date().timeIntervalSince($0) < 600 } ?? false)
        })
        strava.start(wanted: { [weak self] in
            guard let self, !self.dormant else { return false }
            return model.barAppVersion("strava") != nil || (self.lastHit["strava"].map { Date().timeIntervalSince($0) < 600 } ?? false)
        })
        cask.start(key: { model.whiskystatsKey }, wanted: { [weak self] in
            model.barAppVersion("cask") != nil || (self?.lastHit["cask"].map { Date().timeIntervalSince($0) < 600 } ?? false)
        })
        schiphol.start(open: { [weak self] in self?.lastHit["schiphol"].map { Date().timeIntervalSince($0) < 120 } ?? false },
                       home: { [weak self] in self?.lastHit["home"].map { Date().timeIntervalSince($0) < 120 } ?? false },
                       installed: { [weak self] in
                           guard let self, !self.dormant else { return false }
                           return model.barAppVersion("schiphol") != nil || (self.lastHit["schiphol"].map { Date().timeIntervalSince($0) < 600 } ?? false)
                       })
        // A new Linear or aisstream key takes effect at once (after the assignment: `$` publishes before it).
        model.$linearKey.combineLatest(model.$aisstreamKey).dropFirst().removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main).sink { [weak self] _ in MainActor.assumeIsolated { self?.poke() } }.store(in: &subscriptions)
        settings.objectWillChange.sink { [weak self] _ in MainActor.assumeIsolated { self?.configWake.signal() } }.store(in: &subscriptions)
        subscriptions.append(AnyCancellable(NotificationCenter.default.publisher(for: Self.configFilesChanged).receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.configWake.signal() }
        }))
        startLinearFeed(model: model)
        startConfigFeed(model: model, settings: settings)
        tasks.append(Task { [weak self] in   // Claude sessions + Music: 2 s while their page is open, 30 s for Home's tile
            while !Task.isCancelled {
                if let s = self, !s.feedWanted("claude"), !s.feedWanted("music") {
                    await s.hits.wait(600) { s.feedWanted("claude") || s.feedWanted("music") }; continue
                }
                // Every 2 s for the Claude and Music pages; every 30 s when only Home's tile is looking.
                let pageOpen = (self?.lastHit["claude"].map { Date().timeIntervalSince($0) < 600 } ?? false) || (self?.wanted("music") ?? false)
                // The Music page alone needs only the track: no cmux processes and no transcript reads for it.
                let claudeOn = self?.feedWanted("claude") ?? false
                // Low priority and incremental (ClaudeUsage.snapshot): this must never crowd out the link.
                // Every Claude session open in cmux (its newest transcript per workspace), else the last hour's.
                if claudeOn, let self {
                    let s = await Task.detached(priority: .utility) { () -> [ClaudeUsage.Session] in
                        let open = CmuxNames.workspaces()
                        guard !open.isEmpty else { return ClaudeUsage.sessions() }
                        var seen = Set<String>()
                        return open.compactMap { w in
                            guard var s = ClaudeUsage.latestSession(cwd: w.directory), seen.insert(s.id).inserted else { return nil }
                            if let t = w.title { s.project = t }
                            return s
                        }
                    }.value
                    let cmux = await Task.detached(priority: .utility) { CmuxNames.byDirectory() }.value
                    // cmux's sidebar status costs a process per workspace: at most every 5 s while the page is open, else every minute.
                    let cmuxStatus = await Task.detached(priority: .utility) { CmuxNames.claudeStatus(maxAge: pageOpen ? 5 : 60) }.value
                    let snap = await Task.detached(priority: .utility) { ClaudeUsage.snapshot() }.value
                    let now = Date()
                    // Only a session that needs you counts as waiting: a question (AskUserQuestion) or a tool call waiting
                    // for permission (cmux says waiting while the transcript ends in an unanswered tool call). A session whose
                    // turn simply ended (Claude's last entry is text) is "done": your turn, but nothing is being asked.
                    func status(_ x: ClaudeUsage.Session) -> String {
                        if x.state == .question { return "question" }
                        if let c = cmuxStatus[x.cwd] { return c == "waiting" ? (x.state == .waiting ? "done" : "waiting") : c }
                        return x.state == .working ? "running" : "done"
                    }
                    // Needs you first, then running, then done, then idle; within each, the most recent first.
                    func rank(_ st: String) -> Int { st == "waiting" || st == "question" ? 0 : st == "running" ? 1 : st == "done" ? 2 : 3 }
                    let ordered = s.sorted { a, b in
                        let ra = rank(status(a)), rb = rank(status(b))
                        return ra != rb ? ra < rb : a.lastAt > b.lastAt
                    }
                    let budget = settings.claudeDailyBudget
                    self.claude = ["sessions": ordered.prefix(12).map { ["project": cmux[$0.cwd] ?? $0.project, "title": $0.title, "state": status($0), "ago": Int(now.timeIntervalSince($0.lastAt)), "last": $0.lastText] },
                                   "tokens": ClaudeUsage.shortTokens(snap.todayTokens), "tokensRaw": snap.todayTokens, "budget": budget,
                                   "plan": settings.claudePlan.title, "active": snap.activeSessions, "waiting": s.filter { ["waiting", "question"].contains(status($0)) }.count]
                }
                // Music's state comes from the model's own 3 s poll (and is refreshed at once by the page's
                // play/next/previous): asking Music again here ran a second AppleScript on the main thread every 2 s.
                let np = model.nowPlaying
                guard let self else { return }
                let key = np.title + "|" + np.artist + "|" + np.album
                if np.hasTrack, self.art?.key != key {
                    let jpeg = AppleMusic.currentArtwork().flatMap { Self.jpeg($0, side: 240) }
                    self.art = (key, jpeg ?? Data())
                }
                self.music = ["playing": np.isPlaying, "hasTrack": np.hasTrack, "title": np.title, "artist": np.artist, "album": np.album, "artKey": key.hashValue]
                self.updated["claude"] = Date()
                if pageOpen { await Task.relaxedSleep(2) }
                else { await self.hits.wait(30) { self.lastHit["claude"].map { Date().timeIntervalSince($0) < 5 } ?? false } }
            }
        })
        tasks.append(Task { [weak self] in   // Home's Weather tile: 10 min while Home is on screen
            var last = Date.distantPast
            while !Task.isCancelled {
                guard let s = self else { return }
                let shown = s.homeWanted && !s.dormant
                if shown, Date().timeIntervalSince(last) > 600 {
                    last = Date()
                    if let w = try? await model.resolveWeather(settings: settings, metric: settings.units != .imperial) { s.homeWeather = w }
                }
                // Until the next 10-minute mark while Home is shown, else until Home asks again.
                let left = shown ? max(1, 600 - Date().timeIntervalSince(last)) : 3600
                await s.hits.wait(left) { s.homeWanted && !s.dormant && Date().timeIntervalSince(last) > 600 }
            }
        })
        tasks.append(Task { [weak self] in   // calendar: 1 min
            while !Task.isCancelled {
                if let s = self, !s.feedWanted("calendar") { await s.hits.wait(600) { s.feedWanted("calendar") }; continue }
                let events = await CalendarSource.upcoming(limit: 40, calendarIDs: settings.calendarIDs, days: 3)
                guard let self else { return }
                let cal = Calendar.current, today = cal.startOfDay(for: Date())
                let df = DateFormatter(); df.dateFormat = settings.clock24h ? "HH:mm" : "h:mm a"
                var days: [[String: Any]] = []
                for i in 0..<3 {
                    let d = cal.date(byAdding: .day, value: i, to: today)!, next = cal.date(byAdding: .day, value: 1, to: d)!
                    var seen = Set<String>()   // the same event in two subscribed calendars shows once
                    let evs = events.filter { $0.start < next && $0.end > d && seen.insert($0.title + "\($0.start.timeIntervalSince1970)").inserted }.map { e -> [String: Any] in
                        let (r, g, b) = e.calendarColorRGBA
                        return ["title": e.title, "time": e.isAllDay ? "all day" : df.string(from: e.start) + "–" + df.string(from: e.end), "allDay": e.isAllDay,
                                "color": String(format: "#%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255)), "past": e.end < Date()]
                    }
                    let name = i == 0 ? "Today" : i == 1 ? "Tomorrow" : d.formatted(.dateTime.weekday(.wide))
                    days.append(["name": name, "date": d.formatted(.dateTime.day().month(.abbreviated)), "events": evs])
                }
                self.calendar = ["days": days, "authorized": CalendarSource.authStatus() == .authorized]
                self.updated["calendar"] = Date()
                await Task.relaxedSleep(60)
            }
        })
    }

    func stop() { tasks.forEach { $0.cancel() }; tasks.removeAll(); subscriptions.removeAll(); haven.stop(); strava.stop(); cask.stop(); schiphol.stop(); seo.stop(); portfolio.stop(); actions.stop(); jira.stop(); climate.stop(); books.stop(); traffic.stop(); connection.stop(); chess.stop() }

    /// Linear for the Tasks app.
    private func startLinearFeed(model: AppModel) {
        tasks.append(Task { [weak self] in   // Linear: every 20 s while the page is open, else every 2 min
            while !Task.isCancelled {
                guard let self else { return }
                let key = model.linearKey.trimmingCharacters(in: .whitespacesAndNewlines)
                // Only while the Tasks app is on the bar (or asked lately) and someone can see it.
                let tasksWanted = { (model.barAppVersion("tasks") != nil || (self.lastHit["tasks"].map { Date().timeIntervalSince($0) < 600 } ?? false)) && !self.dormant }
                if !key.isEmpty, !tasksWanted() {
                    await self.hits.wait(600) { tasksWanted() || model.linearKey.trimmingCharacters(in: .whitespacesAndNewlines) != key }
                    continue
                }
                if key.isEmpty {
                    self.linear = ["issues": [], "hasKey": false]; model.update(\.linearError, nil)
                } else {
                    do {
                        let r = try await LinearTasks.fetch(apiKey: key)
                        model.update(\.linearError, nil)
                        self.linear = Self.linearDict(r)
                    } catch {
                        model.update(\.linearError, error.localizedDescription)
                        self.linear = ["hasKey": true, "issues": self.linear["issues"] ?? [], "error": error.localizedDescription]
                    }
                }
                // A new key takes effect at once. 20 s while the Tasks page is open on the bar (so an issue closed
                // in Linear disappears quickly), two minutes otherwise, waking up as soon as the page is opened.
                let open = self.lastHit["tasks"].map { Date().timeIntervalSince($0) < 60 } ?? false
                await self.hits.wait(open ? 20 : 120) {
                    model.linearKey.trimmingCharacters(in: .whitespacesAndNewlines) != key || (!open && self.lastHit["tasks"].map { Date().timeIntervalSince($0) < 10 } ?? false)
                }
            }
        })
    }

    /// The bar apps' configuration (v2), owned by Deckhand: one document per bar, a section per app.
    ///
    ///     {"v":2, "location":{"lat","lon","place"}, "units":{"metric","clock24h"},
    ///      "apps":{"flights":{"radiusKm"}, "crypto":{"coins":[…],"currency"}, "news":{"source"}, "weather":{}, "sky":{}, "verse":{},
    ///              "tide":{"stations":[{"code","name","tide"}…]}, "teletekst":{"pages":[{"page","stories"}…],"interval"}, "earth":{"minMag","center"},
    ///              "status":{"services":[id…]}}}
    ///
    /// An app section may carry its own `location` to override the shared one. Deckhand pushes the document to the
    /// on-bar apps over the debug bridge whenever it changes (`am broadcast … --es config64`, accepted only from the
    /// shell user), and serves it as `/config.json` so an app also picks it up from the beacon when ADB is off.
    /// The apps keep their copy and run without the Mac. Position rounded to three decimals (about 100 m).
    static func configDocument(settings: AppSettings, location: (lat: Double, lon: Double, name: String)?) -> [String: Any] {
        var doc: [String: Any] = [
            "v": 2,
            "units": ["metric": settings.units == .metric, "clock24h": settings.clock24h],
            "apps": [
                "flights": ["radiusKm": max(1, settings.flightsRadiusKm)],
                "crypto": ["coins": settings.cryptoCoinsConfigured, "currency": settings.cryptoCurrency.lowercased()],
                "news": ["source": settings.newsSource],
                "weather": [String: Any](), "sky": [String: Any](), "verse": [String: Any](),
                "tide": TideStations.configSection(),   // the gauges from tide.json (Apps → Tide)
                "teletekst": TeletekstPages.configSection(),   // the pages from teletekst.json (Apps → Teletekst)
                "earth": ["minMag": settings.earthMinMag, "center": settings.earthCenter],
                "status": ["services": CloudStatus.sanitize(settings.statusServices)],   // Apps → Cloud Status
            ] as [String: Any],
        ]
        if let l = location { doc["location"] = ["lat": (l.lat * 1000).rounded() / 1000, "lon": (l.lon * 1000).rounded() / 1000, "place": l.name] }
        return doc
    }

    /// Keeps `/config.json` current and pushes a changed document to the bar: at once when a setting, the Tide or
    /// Teletekst file changes or `repushConfig` asks, else every 5 minutes (the location is cached by the model for
    /// an hour). Until 2026-11-15 this ran every 10 s. A push that fails (ADB off) is retried on the next change or
    /// after 30 minutes.
    private var pushedConfig: Data?
    private var pushedAt = Date.distantPast
    /// Posted by the Tide and Teletekst editors after they saved their file.
    nonisolated static let configFilesChanged = Notification.Name("DeckhandBarConfigFilesChanged")
    /// Forget what was pushed, so the next round pushes again (after a bar app was installed).
    func repushConfig() { pushedConfig = nil; configWake.signal() }

    private func startConfigFeed(model: AppModel, settings: AppSettings) {
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                let loc = try? await model.resolveLocation(settings: settings)
                let doc = Self.configDocument(settings: settings, location: loc)
                // What is pushed over ADB also carries this Mac's address and the bar's data key (never served).
                let data = (try? JSONSerialization.data(withJSONObject: Self.withMacSection(doc, model: model), options: [.sortedKeys])) ?? Data()
                guard let self else { return }
                self.barConfig = doc
                if data != self.pushedConfig || Date().timeIntervalSince(self.pushedAt) > 1800 {
                    if await Self.pushConfig(data, model: model) { self.pushedConfig = data; self.pushedAt = Date() }
                    else { self.pushedAt = Date() }   // ADB off: try again on the next change or in 30 min
                }
                // `objectWillChange` comes before the new value is set, and typing sends one per key: wait a second.
                if await self.configWake.sleep(300) { await Task.relaxedSleep(1) }
            }
        })
    }

    /// The pushed document: `doc` plus `"mac": {"base": "http://<this Mac>:7432", "key": "<64 hex>"}` for the selected
    /// bar (M2/M3, bar apps 2.4 and Home 1.6): the apps accept only beacons signed with that key and send it as
    /// `X-Deckhand-Key` on every request. Only ever sent over ADB (DUMP-guarded receiver), never served as /config.json.
    static func withMacSection(_ doc: [String: Any], model: AppModel) -> [String: Any] {
        guard let serial = model.selectedSerial, let ip = model.ipForSelected(), let mine = LocalIP.address(reaching: ip) else { return doc }
        let key = Store.shared.barKey(serial: serial)
        guard !key.isEmpty else { return doc }
        let port = MonitorServer.shared.port != 0 ? MonitorServer.shared.port : MonitorServer.defaultPort
        var out = doc
        out["mac"] = ["base": "http://\(mine):\(port)", "key": key]
        return out
    }

    /// Every Deckhand package on the bar that takes the config broadcast: the on-bar apps (settings), the Mac apps and
    /// Monitor (address and key), and Deckhand Home (address and key).
    nonisolated static var configReceivers: [String] {
        (onBar.union(macPages).union(["monitor"])).sorted().map { package(for: $0) } + ["nl.denoronha.deckhand.home"]
    }

    /// `am broadcast` of the document to each Deckhand app (base64, so no shell quoting), a few apps per shell
    /// command so a command line stays short. `-f 32` is FLAG_INCLUDE_STOPPED_PACKAGES: an app that was installed but
    /// never opened is "stopped" and would not get it (seen on the bar 2026-11-06). The command is not logged (it holds
    /// the key). True when the bar took it.
    private static func pushConfig(_ data: Data, model: AppModel) async -> Bool {
        guard let adb = AdbBridge.find(), let ip = model.ipForSelected() else { return false }
        let b = AdbBridge(path: adb, ip: ip)
        guard await b.connect() else { return false }
        let b64 = data.base64EncodedString()
        var ok = true
        let all = configReceivers
        for start in stride(from: 0, to: all.count, by: 6) {
            let cmd = all[start..<min(start + 6, all.count)].map { "am broadcast -f 32 -a nl.denoronha.deckhand.CONFIG -p \($0) --es config64 \(b64)" }.joined(separator: "; ")
            let out = await b.shell(cmd)
            ok = ok && out.contains("Broadcast completed")
        }
        return ok
    }

    nonisolated static func linearDict(_ r: LinearTasks.Result) -> [String: Any] {
        ["hasKey": true, "me": r.me, "at": Int(Date().timeIntervalSince1970), "issues": r.issues.map {
            i -> [String: Any] in ["id": i.identifier, "uid": i.id, "title": i.title, "priority": i.priority, "priorityLabel": i.priorityLabel, "due": i.dueDate.map { $0 as Any } ?? NSNull(),
             "state": i.state, "stateType": i.stateType, "color": i.stateColor, "project": i.project.map { $0 as Any } ?? NSNull(), "team": i.team] }]
    }

    /// Answer one POST with the `X-Deckhand: action` header: `/tasks/done/<uuid>`, `/music/cmd/<play|next|previous>`,
    /// `/climate/heat/<°C>/<30|60|120|240|next>`, `/climate/schedule`.
    nonisolated func action(_ path: String, model: AppModel) -> MonitorServer.Response? {
        let parts = path.split(separator: "/").map(String.init)
        guard let page = parts.first, Self.macPages.contains(page) else { return nil }
        if page == "tasks", parts.count == 3, parts[1] == "done" {
            // The bar marks an issue done: Deckhand moves it to the team's Done state and drops it from the list.
            // Only an issue this Mac served on the Tasks page (L6): the full-access key must not close any issue by UUID.
            let uid = parts[2]
            let served = DispatchQueue.main.sync { ((self.linear["issues"] as? [[String: Any]]) ?? []).contains { ($0["uid"] as? String) == uid } }
            guard served else { return MonitorServer.Response("404 Not Found", type: "text/plain", body: Data("not a served issue".utf8)) }
            DispatchQueue.main.async {
                let key = model.linearKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty, uid.range(of: "^[0-9a-fA-F-]{36}$", options: .regularExpression) != nil else { return }
                Task { @MainActor in
                    do {
                        try await LinearTasks.complete(apiKey: key, issueID: uid)
                        var l = self.linear
                        let issues = (l["issues"] as? [[String: Any]]) ?? []
                        let done = issues.first { ($0["uid"] as? String) == uid }?["id"] as? String ?? uid
                        l["issues"] = issues.filter { ($0["uid"] as? String) != uid }
                        self.linear = l
                        model.say("Linear: \(done) marked done from the bar.")
                        // Then the real list from Linear, so the page shows exactly what Linear has.
                        if let r = try? await LinearTasks.fetch(apiKey: key) { self.linear = Self.linearDict(r) }
                    } catch { model.linearError = "Could not mark the issue done: \(error.localizedDescription)"; model.say(model.linearError!) }
                }
            }
            return .json(["ok": true])
        }
        if page == "climate" {
            // The heating: only the shapes Climate.heatRequest allows (15–25 °C in half degrees, fixed durations).
            if parts.count == 4, parts[1] == "heat", let r = Climate.heatRequest(celsius: parts[2], duration: parts[3]) {
                DispatchQueue.main.async { Task { @MainActor in await self.climate.heat(celsius: r.celsius, minutes: r.minutes) } }
                return .json(["ok": true])
            }
            if parts == ["climate", "schedule"] {
                DispatchQueue.main.async { Task { @MainActor in await self.climate.backToSchedule() } }
                return .json(["ok": true])
            }
            return MonitorServer.Response("400 Bad Request", type: "text/plain", body: Data("not a heating request".utf8))
        }
        if page == "music", parts.count == 3, parts[1] == "cmd" {
            DispatchQueue.main.async {
                switch parts[2] { case "play": model.musicPlayPause(); case "next": model.musicNext(); case "previous": model.musicPrevious(); default: break }
            }
            return .json(["ok": true])
        }
        return nil
    }

    /// Answer one request (called off the main actor by the server; reads a snapshot).
    nonisolated func route(_ path: String, model: AppModel) -> MonitorServer.Response? {
        let parts = path.split(separator: "/").map(String.init)
        if parts == ["config.json"] { return .json(DispatchQueue.main.sync { self.barConfig }) }
        if parts == ["home", "glance.json"] { return .json(DispatchQueue.main.sync { () -> [String: Any] in self.lastHit["home"] = Date(); return self.glance() }) }
        guard parts.count == 2, let page = parts.first, Self.macPages.contains(page) else { return nil }
        if parts[1] == "data.json" {
            // A request that wakes an idle feed gets 503: the page retries in 2 s and then gets fresh data, instead
            // of showing what the feed had before it went idle until its next poll.
            let body: [String: Any]? = DispatchQueue.main.sync {
                let feed = Self.feedOf[page]
                let fresh = feed.map { f in self.wanted(page) && (self.updated[f].map { Date().timeIntervalSince($0) < 600 } ?? false) } ?? true
                self.lastHit[page] = Date()
                return fresh ? self.data(page) : nil
            }
            return body.map { .json($0) } ?? MonitorServer.Response("503 Service Unavailable", type: "text/plain", body: Data())
        }
        if page == "music", parts[1] == "art.jpg" {
            let jpeg = DispatchQueue.main.sync { self.art?.jpeg } ?? Data()
            return jpeg.isEmpty ? nil : MonitorServer.Response(type: "image/jpeg", body: jpeg)
        }
        return nil
    }

    private func data(_ page: String) -> [String: Any] {
        switch page {
        case "claude": return claude
        case "music": return music
        case "calendar": return calendar
        case "tasks": return linear
        case "schiphol": return schiphol.snapshot(clock24h: settings?.clock24h ?? true)
        case "haven": return haven.snapshot(hasKey: !(model?.aisstreamKey.isEmpty ?? true), clock24h: settings?.clock24h ?? true)
        case "strava": return strava.snapshot(metric: settings?.units != .imperial, clock24h: settings?.clock24h ?? true)
        case "cask": return cask.snapshot(hasKey: !(model?.whiskystatsKey.isEmpty ?? true))
        case "seo": return seo.snapshot()
        case "portfolio": return portfolio.snapshot()
        case "actions": return actions.snapshot()
        case "jira": return jira.snapshot()
        case "climate": return climate.snapshot()
        case "books": return books.snapshot()
        case "traffic": return traffic.snapshot()
        case "connection": return connection.snapshot()
        case "chess": return chess.snapshot()
        default: return [:]
        }
    }

    // MARK: Deckhand Home's tiles

    /// One short live line per app for Deckhand Home's tiles, from what the feeds already hold (no request of its
    /// own, except the weather): `{"apps": {"<page>": {"line", "tone"?, "badge"?, "temp"?}}}`. `tone` colours the
    /// line (up, down, warn, live); `badge` is a count drawn on the icon; `temp` is drawn on the Weather icon.
    /// An app with nothing to say is left out and its tile shows only its name. Monitor's line is added by the route.
    func glance() -> [String: Any] {
        var apps: [String: [String: Any]] = [:]
        let clock24h = settings?.clock24h ?? true
        let time = DateFormatter(); time.dateFormat = clock24h ? "HH:mm" : "h:mm a"

        // Claude: sessions waiting for an answer first, else how many are working, else today's tokens.
        let waiting = claude["waiting"] as? Int ?? 0, active = claude["active"] as? Int ?? 0
        if waiting > 0 { apps["claude"] = ["line": "\(waiting) waiting", "tone": "warn", "badge": waiting] }
        else if active > 0 { apps["claude"] = ["line": "\(active) working", "tone": "live"] }
        else if let t = claude["tokens"] as? String, !t.isEmpty, (claude["tokensRaw"] as? Int ?? 0) > 0 { apps["claude"] = ["line": "\(t) today"] }

        // Music: the track while it plays.
        if let np = model?.nowPlaying, np.hasTrack, np.isPlaying, !np.title.isEmpty { apps["music"] = ["line": np.title, "tone": "live"] }

        // Calendar: the next event today that has not ended (all-day events only when nothing else is left).
        if let days = calendar["days"] as? [[String: Any]], let today = days.first, let evs = today["events"] as? [[String: Any]] {
            let open = evs.filter { !($0["past"] as? Bool ?? false) }
            if let e = open.first(where: { !($0["allDay"] as? Bool ?? false) }) ?? open.first, let title = e["title"] as? String {
                let start = (e["allDay"] as? Bool ?? false) ? "" : ((e["time"] as? String)?.components(separatedBy: "–").first ?? "") + " "
                apps["calendar"] = ["line": start + title]
            } else if calendar["authorized"] as? Bool ?? false { apps["calendar"] = ["line": "Nothing left today"] }
        }

        // Tasks: open issues assigned to the owner.
        if linear["hasKey"] as? Bool ?? false, let issues = linear["issues"] as? [[String: Any]] {
            // The badge counts only what needs doing now (urgent, or due today or earlier); the line says how many are open.
            let today = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date()) }()
            let urgent = issues.filter { ($0["priority"] as? Int) == 1 || (($0["due"] as? String).map { $0 <= today } ?? false) }.count
            var t: [String: Any] = ["line": issues.isEmpty ? "All done" : "\(issues.count) open"]
            if urgent > 0 { t["badge"] = urgent }
            apps["tasks"] = t
        }

        // Weather: temperature on the icon, the sky in words.
        if let w = homeWeather { apps["weather"] = ["line": w.sky.label, "temp": "\(Int(w.temperature.rounded()))°"] }

        // Training: this week's distance in the sport done most.
        let st = strava.snapshot(metric: settings?.units != .imperial, clock24h: clock24h)
        if let weeks = st["weeks"] as? [[String: Any]] {
            if let w = weeks.first, let this = w["this"] as? [String: Any], let d = this["dist"] as? String, !d.isEmpty { apps["strava"] = ["line": "\(d) this week"] }
            else if st["connected"] as? Bool ?? false { apps["strava"] = ["line": "Nothing this week"] }
        }

        // Whisky Portfolio: what the bottles are worth, and the change over a month.
        let c = cask.snapshot(hasKey: !(model?.whiskystatsKey.isEmpty ?? true))
        if let total = c["total"] as? Double, (c["priced"] as? Int ?? 0) > 0 {
            let nf = NumberFormatter(); nf.numberStyle = .currency; nf.currencyCode = "EUR"; nf.maximumFractionDigits = 0
            let d30 = c["d30"] as? Double ?? 0
            let pct = abs(d30) >= 0.001 ? String(format: " %@%.1f%%", d30 > 0 ? "▲" : "▼", abs(d30) * 100) : ""
            apps["cask"] = ["line": (nf.string(from: total as NSNumber) ?? "") + pct, "tone": d30 >= 0.001 ? "up" : d30 <= -0.001 ? "down" : ""]
        }

        // Schiphol: the runways in use for landing and take-off.
        let sp = schiphol.snapshot(clock24h: clock24h)
        let land = (sp["landing"] as? [[String: Any]])?.first?["rwy"] as? String, off = (sp["takeoff"] as? [[String: Any]])?.first?["rwy"] as? String
        if land != nil || off != nil { apps["schiphol"] = ["line": [land.map { "↓ \($0)" }, off.map { "↑ \($0)" }].compactMap { $0 }.joined(separator: "  ")] }

        // Haven: ships on their way in, else ships alongside, over all places.
        let hv = haven.snapshot(hasKey: !(model?.aisstreamKey.isEmpty ?? true), clock24h: clock24h)
        if let places = hv["places"] as? [[String: Any]], hv["connected"] as? Bool ?? false {
            let arriving = places.reduce(0) { $0 + ($1["nArriving"] as? Int ?? 0) }, alongside = places.reduce(0) { $0 + ($1["nAlongside"] as? Int ?? 0) }
            if arriving > 0 { apps["haven"] = ["line": "\(arriving) arriving", "tone": "live"] }
            else if alongside > 0 { apps["haven"] = ["line": "\(alongside) alongside"] }
        }
        // SEO: the mobile SEO score and the clicks of the last 28 days.
        if let line = seo.homeLine() { apps["seo"] = ["line": line] }
        // Portfolio: the total and its change over the last day.
        if let p = portfolio.homeLine() { apps["portfolio"] = ["line": p.line, "tone": p.tone] }
        // GitHub Actions: what is failing or running, else that everything passes.
        if let l = actions.homeLine() { apps["actions"] = ["line": l.line, "tone": l.tone] }
        // Jira Board: the user's cards waiting for review or in progress, else how many are open.
        if let l = jira.homeLine() { apps["jira"] = ["line": l.line, "tone": l.tone] }
        // Climate: a manual heating setting with its end, else inside and outside.
        if let l = climate.homeLine() { apps["climate"] = ["line": l.line, "tone": l.tone] }
        // Books: profit this year and what customers still owe.
        if let l = books.homeLine() { apps["books"] = ["line": l.line, "tone": l.tone] }
        // Traffic: the rate right now, while it is being sampled.
        if let l = traffic.homeLine() { apps["traffic"] = ["line": l.line, "tone": l.tone] }
        // Connection: the verdict, while it is being measured.
        if let l = connection.homeLine() { apps["connection"] = ["line": l.line, "tone": l.tone] }
        // Chess: the games waiting for the user's move (with a badge), else the main rating and its month.
        if let l = chess.homeLine() { var t: [String: Any] = ["line": l.line, "tone": l.tone]; if l.badge > 0 { t["badge"] = l.badge }; apps["chess"] = t }
        return ["apps": apps, "order": homeOrder(), "at": Int(Date().timeIntervalSince1970)]
    }

    /// The order of Deckhand Home's tiles, the same as Deckhand's Apps list: Deckhand's apps in their fixed order, then the
    /// marketplace apps on the bar, then the firmware's own apps (each by name). Home keeps Settings and UltraBar last itself.
    func homeOrder() -> [String] {
        var order = AppModel.barAppPages.map { BarPages.package(for: $0.page) }
        guard let model else { return order }
        let others = model.barApps.filter { !$0.isScreensaver && !$0.packageName.hasPrefix(BarPages.packagePrefix) && !model.turnedOffApps.contains($0.packageName) }
        let byName: (CoreBarSession.AppInfo, CoreBarSession.AppInfo) -> Bool = { $0.appName.lowercased() < $1.appName.lowercased() }
        order += others.filter { !$0.systemApp }.sorted(by: byName).map(\.packageName)
        order += others.filter { $0.systemApp }.sorted(by: byName).map(\.packageName)
        return order
    }

    // MARK: helpers

    nonisolated static func jpeg(_ img: NSImage, side: Int) -> Data? {
        let out = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            img.draw(in: rect, from: .zero, operation: .copy, fraction: 1); return true
        }
        guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}
