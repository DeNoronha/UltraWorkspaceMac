import Foundation
import AppKit
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
    nonisolated static let macPages: Set<String> = ["claude", "music", "calendar", "tasks", "haven", "strava", "cask", "schiphol", "zeekr"]
    nonisolated static let packagePrefix = "nl.denoronha.deckhand."
    nonisolated static func package(for page: String) -> String { packagePrefix + page }
    /// Pages whose bar app fetches its own data on the bar: the APK carries the page and the feeds, and gets only
    /// its settings from this Mac (pushed over ADB, or read as `/config.json`).
    nonisolated static let onBar: Set<String> = ["flights", "crypto", "weather", "sky", "news", "verse", "tide"]

    private var claude: [String: Any] = ["sessions": [], "tokens": "", "active": 0, "waiting": 0]
    private var calendar: [String: Any] = ["days": []]
    private var music: [String: Any] = ["playing": false, "hasTrack": false]
    private var art: (key: String, jpeg: Data)?
    private var linear: [String: Any] = ["issues": [], "hasKey": false]
    /// When each page's data was last asked for: the Linear poll runs fast while the Tasks page is open.
    private var lastHit: [String: Date] = [:]
    /// Seconds since a page last asked for its data (nil: never) — `AppModel.musicWanted` slows the Music poll on it.
    func secondsSinceHit(_ page: String) -> TimeInterval? { lastHit[page].map { Date().timeIntervalSince($0) } }
    private var tasks: [Task<Void, Never>] = []
    /// When the Claude/Music and Calendar feeds last produced data.
    private var updated: [String: Date] = [:]
    /// The Claude/Music and Calendar feeds run only while their bar app asked for data in the last ten minutes,
    /// so a Mac without those apps on a bar spends nothing on them.
    private func wanted(_ page: String) -> Bool { lastHit[page].map { Date().timeIntervalSince($0) < 600 } ?? false }
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
    /// The owner's Zeekr (Zeekr's EU gateway), polled while the Zeekr app is on the bar.
    let zeekr = ZeekrFeed()
    private weak var model: AppModel?
    private var settings: AppSettings?

    func start(model: AppModel, settings: AppSettings) {
        stop()
        self.model = model; self.settings = settings
        haven.start(key: { model.aisstreamKey }, wanted: { [weak self] in
            model.barAppVersion("haven") != nil || (self?.lastHit["haven"].map { Date().timeIntervalSince($0) < 600 } ?? false)
        })
        strava.start(wanted: { [weak self] in
            model.barAppVersion("strava") != nil || (self?.lastHit["strava"].map { Date().timeIntervalSince($0) < 600 } ?? false)
        })
        cask.start(key: { model.whiskystatsKey }, wanted: { [weak self] in
            model.barAppVersion("cask") != nil || (self?.lastHit["cask"].map { Date().timeIntervalSince($0) < 600 } ?? false)
        })
        schiphol.start(open: { [weak self] in self?.lastHit["schiphol"].map { Date().timeIntervalSince($0) < 120 } ?? false },
                       installed: { [weak self] in model.barAppVersion("schiphol") != nil || (self?.lastHit["schiphol"].map { Date().timeIntervalSince($0) < 600 } ?? false) })
        zeekr.start(wanted: { [weak self] in
            model.barAppVersion("zeekr") != nil || (self?.lastHit["zeekr"].map { Date().timeIntervalSince($0) < 600 } ?? false)
        }, pageOpen: { [weak self] in self?.lastHit["zeekr"].map { Date().timeIntervalSince($0) < 30 } ?? false })
        startLinearFeed(model: model)
        startConfigFeed(model: model, settings: settings)
        tasks.append(Task { [weak self] in   // Claude sessions + Music: 2 s
            while !Task.isCancelled {
                if let s = self, !s.wanted("claude"), !s.wanted("music") { try? await Task.sleep(nanoseconds: 2_000_000_000); continue }
                // Low priority and incremental (ClaudeUsage.snapshot): this must never crowd out the link.
                // Every Claude session open in cmux (its newest transcript per workspace), else the last hour's.
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
                let cmuxStatus = await Task.detached(priority: .utility) { CmuxNames.claudeStatus() }.value
                let snap = await Task.detached(priority: .utility) { ClaudeUsage.snapshot() }.value
                // Music's state comes from the model's own 3 s poll (and is refreshed at once by the page's
                // play/next/previous): asking Music again here ran a second AppleScript on the main thread every 2 s.
                let np = model.nowPlaying
                guard let self else { return }
                let now = Date()
                // Status as cmux's sidebar shows it (running / waiting / idle) when cmux knows the workspace, else from
                // the transcript: Claude busy = running, Claude done or asking = waiting.
                func status(_ x: ClaudeUsage.Session) -> String {
                    if let c = cmuxStatus[x.cwd] { return c == "waiting" && x.state == .question ? "question" : c }
                    return x.state == .working ? "running" : x.state == .question ? "question" : "waiting"
                }
                // Waiting ones first, then running, then idle; within each, the most recent first.
                func rank(_ st: String) -> Int { st == "waiting" || st == "question" ? 0 : st == "running" ? 1 : 2 }
                let ordered = s.sorted { a, b in
                    let ra = rank(status(a)), rb = rank(status(b))
                    return ra != rb ? ra < rb : a.lastAt > b.lastAt
                }
                let budget = settings.claudeDailyBudget
                self.claude = ["sessions": ordered.prefix(12).map { ["project": cmux[$0.cwd] ?? $0.project, "title": $0.title, "state": status($0), "ago": Int(now.timeIntervalSince($0.lastAt)), "last": $0.lastText] },
                               "tokens": ClaudeUsage.shortTokens(snap.todayTokens), "tokensRaw": snap.todayTokens, "budget": budget,
                               "plan": settings.claudePlan.title, "active": snap.activeSessions, "waiting": s.filter { ["waiting", "question"].contains(status($0)) }.count]
                let key = np.title + "|" + np.artist + "|" + np.album
                if np.hasTrack, self.art?.key != key {
                    let jpeg = AppleMusic.currentArtwork().flatMap { Self.jpeg($0, side: 240) }
                    self.art = (key, jpeg ?? Data())
                }
                self.music = ["playing": np.isPlaying, "hasTrack": np.hasTrack, "title": np.title, "artist": np.artist, "album": np.album, "artKey": key.hashValue]
                self.updated["claude"] = Date()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        })
        tasks.append(Task { [weak self] in   // calendar: 1 min
            while !Task.isCancelled {
                if let s = self, !s.wanted("calendar") { try? await Task.sleep(nanoseconds: 2_000_000_000); continue }
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
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        })
    }

    func stop() { tasks.forEach { $0.cancel() }; tasks.removeAll(); haven.stop(); strava.stop(); cask.stop(); schiphol.stop(); zeekr.stop() }

    /// Linear for the Tasks app.
    private func startLinearFeed(model: AppModel) {
        tasks.append(Task { [weak self] in   // Linear: every 20 s while the page is open, else every 2 min
            while !Task.isCancelled {
                guard let self else { return }
                let key = model.linearKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if key.isEmpty {
                    self.linear = ["issues": [], "hasKey": false]; model.linearError = nil
                } else {
                    do {
                        let r = try await LinearTasks.fetch(apiKey: key)
                        model.linearError = nil
                        self.linear = Self.linearDict(r)
                    } catch {
                        model.linearError = error.localizedDescription
                        self.linear = ["hasKey": true, "issues": self.linear["issues"] ?? [], "error": error.localizedDescription]
                    }
                }
                // A new key takes effect at once. 20 s while the Tasks page is open on the bar (so an issue closed
                // in Linear disappears quickly), two minutes otherwise, waking up as soon as the page is opened.
                let open = self.lastHit["tasks"].map { Date().timeIntervalSince($0) < 60 } ?? false
                for _ in 0..<(open ? 4 : 24) {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if Task.isCancelled || model.linearKey != key { break }
                    if !open, let t = self.lastHit["tasks"], Date().timeIntervalSince(t) < 10 { break }
                }
            }
        })
    }

    /// The bar apps' configuration (v2), owned by Deckhand: one document per bar, a section per app.
    ///
    ///     {"v":2, "location":{"lat","lon","place"}, "units":{"metric","clock24h"},
    ///      "apps":{"flights":{"radiusKm"}, "crypto":{"coins":[…],"currency"}, "news":{"source"}, "weather":{}, "sky":{}, "verse":{},
///              "tide":{"stations":[{"code","name","tide"}…]}}}
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
            ] as [String: Any],
        ]
        if let l = location { doc["location"] = ["lat": (l.lat * 1000).rounded() / 1000, "lon": (l.lon * 1000).rounded() / 1000, "place": l.name] }
        return doc
    }

    /// Keeps `/config.json` current (every 10 s; the location is cached by the model) and pushes a changed
    /// document to the bar. A push that fails (ADB off) is retried on the next change or after 30 minutes.
    private var pushedConfig: Data?
    private var pushedAt = Date.distantPast
    /// Forget what was pushed, so the next round pushes again (after a bar app was installed).
    func repushConfig() { pushedConfig = nil }

    private func startConfigFeed(model: AppModel, settings: AppSettings) {
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                let loc = try? await model.resolveLocation(settings: settings)
                let doc = Self.configDocument(settings: settings, location: loc)
                let data = (try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys])) ?? Data()
                guard let self else { return }
                self.barConfig = doc
                if data != self.pushedConfig || Date().timeIntervalSince(self.pushedAt) > 1800 {
                    if await Self.pushConfig(data, model: model) { self.pushedConfig = data; self.pushedAt = Date() }
                    else { self.pushedAt = Date() }   // ADB off: try again on the next change or in 30 min
                }
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        })
    }

    /// `am broadcast` of the document to each on-bar app (base64, so no shell quoting). `-f 32` is
    /// FLAG_INCLUDE_STOPPED_PACKAGES: an app that was installed but never opened is "stopped" and would not get it
    /// (seen on the bar 2026-11-06). True when the bar took it.
    private static func pushConfig(_ data: Data, model: AppModel) async -> Bool {
        guard let adb = AdbBridge.find(), let ip = model.ipForSelected() else { return false }
        let b = AdbBridge(path: adb, ip: ip)
        guard await b.connect() else { return false }
        let b64 = data.base64EncodedString()
        let cmd = onBar.sorted().map { "am broadcast -f 32 -a nl.denoronha.deckhand.CONFIG -p \(package(for: $0)) --es config64 \(b64)" }.joined(separator: "; ")
        let out = await b.shell(cmd)
        return out.contains("Broadcast completed")
    }

    nonisolated static func linearDict(_ r: LinearTasks.Result) -> [String: Any] {
        ["hasKey": true, "me": r.me, "at": Int(Date().timeIntervalSince1970), "issues": r.issues.map {
            i -> [String: Any] in ["id": i.identifier, "uid": i.id, "title": i.title, "priority": i.priority, "priorityLabel": i.priorityLabel, "due": i.dueDate.map { $0 as Any } ?? NSNull(),
             "state": i.state, "stateType": i.stateType, "color": i.stateColor, "project": i.project.map { $0 as Any } ?? NSNull(), "team": i.team] }]
    }

    /// Answer one POST with the `X-Deckhand: action` header: `/tasks/done/<uuid>`, `/music/cmd/<play|next|previous>`.
    nonisolated func action(_ path: String, model: AppModel) -> MonitorServer.Response? {
        let parts = path.split(separator: "/").map(String.init)
        guard let page = parts.first, Self.macPages.contains(page) else { return nil }
        if page == "tasks", parts.count == 3, parts[1] == "done" {
            // The bar marks an issue done: Deckhand moves it to the team's Done state and drops it from the list.
            let uid = parts[2]
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
        // The owner's own car picture for the Zeekr page (kept in Deckhand's private folder, never in the APK).
        if parts.count == 3, parts[0] == "zeekr", parts[1] == "car", parts[2].hasSuffix(".png") {
            let variant = String(parts[2].dropLast(4))
            guard ZeekrFeed.pictures.contains(where: { $0.variant == variant }) else { return nil }
            return DispatchQueue.main.sync { self.zeekr.picture(variant) }.map { MonitorServer.Response(type: "image/png", body: $0) }
        }
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
        case "zeekr": return zeekr.snapshot(clock24h: settings?.clock24h ?? true)
        case "cask": return cask.snapshot(hasKey: !(model?.whiskystatsKey.isEmpty ?? true))
        default: return [:]
        }
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
