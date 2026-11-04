import Foundation
import AppKit
import UltraBarKit

/// Full-width pages for the bar's Deckhand apps (2026-11-04): one page per app, each a 1424×280 HTML view
/// served by `MonitorServer` and polled by the page's own script. `BarPages` keeps the data the pages
/// need fresh on its own cadence (crypto and weather every few minutes, calendar every minute, Claude
/// sessions and Music every 2 s) so a request never waits on the network.
///
/// Routes: `/<page>` (html), `/<page>/data.json`, `/music/art.jpg`, `/music/cmd/<play|next|previous>`, `/flights/tile/z/x/y.png`, `/tasks/done/<id>`.
@MainActor
final class BarPages {
    nonisolated static let pages = ["monitor", "claude", "crypto", "weather", "music", "calendar", "flights", "sky", "news", "verse", "tasks"]
    nonisolated static let packagePrefix = "nl.denoronha.deckhand."
    nonisolated static func package(for page: String) -> String { packagePrefix + page }

    private var claude: [String: Any] = ["sessions": [], "tokens": "", "active": 0, "waiting": 0]
    private var crypto: [String: Any] = ["coins": []]
    private var weather: [String: Any] = [:]
    private var calendar: [String: Any] = ["days": []]
    private var music: [String: Any] = ["playing": false, "hasTrack": false]
    private var art: (key: String, jpeg: Data)?
    private var flights: [String: Any] = ["aircraft": [], "radius": 3]
    private var sky: [String: Any] = [:]
    private var news: [String: Any] = ["items": []]
    private var verse: [String: Any] = [:]
    private var linear: [String: Any] = ["issues": [], "hasKey": false]
    /// When each page's data was last asked for: the flights poll runs fast only while the page is open.
    private var lastHit: [String: Date] = [:]
    /// Seconds since a page last asked for its data (nil: never) — `AppModel.musicWanted` slows the Music poll on it.
    func secondsSinceHit(_ page: String) -> TimeInterval? { lastHit[page].map { Date().timeIntervalSince($0) } }
    private var tasks: [Task<Void, Never>] = []

    /// The resource self-check reports once per launch, not on every settings change that restarts the feeds.
    private static var reportedMissing = false

    func start(model: AppModel, settings: AppSettings) {
        stop()
        if !Self.reportedMissing, !Self.missingResources.isEmpty {
            Self.reportedMissing = true
            model.say("Bar pages missing from the app's resource bundle: \(Self.missingResources.joined(separator: ", ")). Those pages show 'Page missing' on the bar; rebuild with packaging/make-app.sh.")
        }
        startFeeds(model: model, settings: settings)
        tasks.append(Task { [weak self] in   // Claude sessions + Music: 2 s
            while !Task.isCancelled {
                // Low priority and incremental (ClaudeUsage.snapshot): this must never crowd out the link.
                let s = await Task.detached(priority: .utility) { ClaudeUsage.sessions() }.value
                let snap = await Task.detached(priority: .utility) { ClaudeUsage.snapshot() }.value
                // Music's state comes from the model's own 3 s poll (and is refreshed at once by the page's
                // play/next/previous): asking Music again here ran a second AppleScript on the main thread every 2 s.
                let np = model.nowPlaying
                guard let self else { return }
                let now = Date()
                self.claude = ["sessions": s.prefix(6).map { ["project": $0.project, "title": $0.title, "state": $0.state.rawValue, "ago": Int(now.timeIntervalSince($0.lastAt)), "last": $0.lastText] },
                               "tokens": ClaudeUsage.shortTokens(snap.todayTokens), "active": snap.activeSessions, "waiting": s.filter { $0.state != .working }.count]
                let key = np.title + "|" + np.artist + "|" + np.album
                if np.hasTrack, self.art?.key != key {
                    let jpeg = AppleMusic.currentArtwork().flatMap { Self.jpeg($0, side: 240) }
                    self.art = (key, jpeg ?? Data())
                }
                self.music = ["playing": np.isPlaying, "hasTrack": np.hasTrack, "title": np.title, "artist": np.artist, "album": np.album, "artKey": key.hashValue]
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        })
        tasks.append(Task { [weak self] in   // crypto: 2 min
            while !Task.isCancelled {
                let ids = settings.cryptoCoinsConfigured, cur = settings.cryptoCurrency
                let coins = await CryptoStats.fetch(ids: ids, currency: cur)
                var out: [[String: Any]] = []
                for id in ids {
                    let day = await CryptoStats.today(id: id, currency: cur)
                    let c = coins.first { $0.symbol.lowercased() == CryptoStats.symbol(for: id).lowercased() }
                    out.append(["symbol": CryptoStats.symbol(for: id).uppercased(), "price": c?.price ?? day?.current ?? 0, "change": c?.change24h ?? 0,
                                "points": Self.thin(day?.points ?? [], to: 90), "open": day?.open ?? 0])
                }
                guard let self else { return }
                self.crypto = ["coins": out, "suffix": CryptoStats.suffix(for: cur), "at": Int(Date().timeIntervalSince1970)]
                try? await Task.sleep(nanoseconds: 120_000_000_000)
            }
        })
        tasks.append(Task { [weak self] in   // weather: 15 min
            while !Task.isCancelled {
                let metric = settings.units == .metric
                if let loc = try? await model.resolveLocation(settings: settings),
                   let now = try? await OpenMeteo.current(latitude: loc.lat, longitude: loc.lon, metric: metric, placeName: loc.name),
                   let days = try? await OpenMeteo.daily(latitude: loc.lat, longitude: loc.lon, metric: metric, days: 4) {
                    guard let self else { return }
                    self.weather = ["place": now.place, "temp": now.temperature.rounded(), "unit": now.unitSuffix, "sky": "\(now.sky)", "code": now.code,
                                    "isDay": now.isDay, "humidity": now.humidity ?? 0, "wind": now.windSpeed.map { Int($0.rounded()) } ?? 0, "windUnit": now.windSuffix,
                                    "days": days.map { ["date": $0.date, "sky": "\($0.sky)", "code": $0.code, "max": $0.tmax.rounded(), "min": $0.tmin.rounded(), "rain": $0.precipProb ?? 0] }]
                }
                try? await Task.sleep(nanoseconds: 900_000_000_000)
            }
        })
        tasks.append(Task { [weak self] in   // calendar: 1 min
            while !Task.isCancelled {
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
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        })
    }

    func stop() { tasks.forEach { $0.cancel() }; tasks.removeAll() }

    /// The newer apps' feeds (2026-11-04): flights, sun and moon, headlines, the verse of the day, Linear.
    private func startFeeds(model: AppModel, settings: AppSettings) {
        tasks.append(Task { [weak self] in   // flights: every 10 s while the page is open, else every 2 min
            var routes: [String: Flights.Route?] = [:]
            while !Task.isCancelled {
                guard let self else { return }
                let open = self.lastHit["flights"].map { Date().timeIntervalSince($0) < 60 } ?? false
                let radius = Double(max(1, settings.flightsRadiusKm))
                if let loc = try? await model.resolveLocation(settings: settings) {
                    // Ask for a wider circle so "nearest beyond" can be shown when nothing is overhead.
                    let all = (try? await Flights.nearby(lat: loc.lat, lon: loc.lon, radiusKm: max(radius, 25))) ?? []
                    var out: [[String: Any]] = []
                    for a in all.prefix(8) {
                        var r = routes[a.callsign]
                        if r == nil, !a.callsign.isEmpty { let fetched = await Flights.route(callsign: a.callsign); routes[a.callsign] = .some(fetched); r = .some(fetched) }
                        let route = r ?? nil
                        func ap(_ x: Flights.Airport?) -> Any { x.map { ["iata": $0.iata, "name": $0.name, "city": $0.city, "country": $0.country] as [String: Any] } ?? NSNull() }
                        out.append(["callsign": a.callsign, "reg": a.registration, "type": a.type, "alt": a.altitudeM ?? NSNull(), "ground": a.onGround,
                                    "speed": a.speedKmh ?? NSNull(), "vs": a.verticalMps ?? NSNull(), "track": a.track ?? NSNull(),
                                    "km": (a.distanceKm * 10).rounded() / 10, "bearing": a.bearing, "dir": Flights.compass(a.bearing), "inside": a.distanceKm <= radius,
                                    "airline": route?.airline ?? NSNull(), "from": ap(route?.origin), "to": ap(route?.destination)])
                    }
                    self.flights = ["aircraft": out, "radius": Int(radius), "place": loc.name, "lat": loc.lat, "lon": loc.lon, "at": Int(Date().timeIntervalSince1970)]
                }
                // 10 s while the page is open; otherwise 2 min, but wake up within 5 s of the page being opened.
                for _ in 0..<(open ? 2 : 24) {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if Task.isCancelled { return }
                    if !open, let t = self.lastHit["flights"], Date().timeIntervalSince(t) < 10 { break }
                }
            }
        })
        tasks.append(Task { [weak self] in   // sun & moon: every minute, computed locally
            while !Task.isCancelled {
                guard let self else { return }
                if let loc = try? await model.resolveLocation(settings: settings) {
                    let now = Date()
                    let s = SkyMath.sunDay(at: now, lat: loc.lat, lon: loc.lon), m = SkyMath.moonInfo(at: now, lat: loc.lat, lon: loc.lon)
                    func t(_ d: Date?) -> Any { d.map { Int($0.timeIntervalSince1970) as Any } ?? NSNull() }
                    self.sky = ["place": loc.name, "lat": loc.lat, "now": Int(now.timeIntervalSince1970), "tz": TimeZone.current.secondsFromGMT(),
                                "sun": ["rise": t(s.sunrise), "set": t(s.sunset), "noon": t(s.solarNoon), "dawn": t(s.civilDawn), "dusk": t(s.civilDusk),
                                        "goldenEnd": t(s.goldenEnd), "goldenStart": t(s.goldenStart), "dayLength": Int(s.dayLength),
                                        "elevation": (s.now.elevation * 10).rounded() / 10, "azimuth": s.now.azimuth.rounded()],
                                "moon": ["phase": m.phase, "illumination": m.illumination, "age": (m.ageDays * 10).rounded() / 10, "name": m.name, "waxing": m.waxing,
                                         "rise": t(m.rise), "set": t(m.set), "nextFull": t(m.nextFull), "nextNew": t(m.nextNew),
                                         "elevation": (m.now.elevation * 10).rounded() / 10, "azimuth": m.now.azimuth.rounded(), "distanceKm": Int(m.distanceKm)]]
                }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        })
        tasks.append(Task { [weak self] in   // headlines: every 10 min
            while !Task.isCancelled {
                guard let self else { return }
                let src = NewsFeed.source(settings.newsSource)
                if let items = try? await NewsFeed.fetch(src, limit: 14) {
                    self.news = ["source": src.name, "at": Int(Date().timeIntervalSince1970),
                                 "items": items.map { i -> [String: Any] in
                                    ["title": i.title, "ago": i.date.map { Int(Date().timeIntervalSince($0)) as Any } ?? NSNull(), "summary": String(i.summary.prefix(160)),
                                     "day": i.day.map { (Calendar.current.isDateInToday($0) ? "today" : Calendar.current.isDateInYesterday($0) ? "yesterday" : $0.formatted(date: .abbreviated, time: .omitted)) as Any } ?? NSNull()] }]
                } else if (self.news["items"] as? [Any])?.isEmpty ?? true {
                    self.news = ["source": src.name, "items": [], "error": "Could not load \(src.name)."]
                }
                try? await Task.sleep(nanoseconds: 600_000_000_000)
            }
        })
        tasks.append(Task { [weak self] in   // verse of the day: once an hour (the reference changes at midnight)
            var have = ""
            while !Task.isCancelled {
                guard let self else { return }
                let ref = DailyVerse.reference(for: Date())
                if ref != have, let v = try? await DailyVerse.fetch(reference: ref) {
                    have = ref
                    self.verse = ["reference": v.reference, "text": v.text, "translation": v.translation, "date": Date().formatted(date: .long, time: .omitted)]
                }
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)
            }
        })
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

    nonisolated static func linearDict(_ r: LinearTasks.Result) -> [String: Any] {
        ["hasKey": true, "me": r.me, "at": Int(Date().timeIntervalSince1970), "issues": r.issues.map {
            i -> [String: Any] in ["id": i.identifier, "uid": i.id, "title": i.title, "priority": i.priority, "priorityLabel": i.priorityLabel, "due": i.dueDate.map { $0 as Any } ?? NSNull(),
             "state": i.state, "stateType": i.stateType, "color": i.stateColor, "project": i.project.map { $0 as Any } ?? NSNull(), "team": i.team] }]
    }

    /// Answer one POST with the `X-Deckhand: action` header: `/tasks/done/<uuid>`, `/music/cmd/<play|next|previous>`.
    nonisolated func action(_ path: String, model: AppModel) -> MonitorServer.Response? {
        let parts = path.split(separator: "/").map(String.init)
        guard let page = parts.first, Self.pages.contains(page) else { return nil }
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
        guard let page = parts.first else { return .html(Self.html("monitor")) }
        guard Self.pages.contains(page) else { return nil }
        if parts.count == 1 { return .html(Self.html(page)) }
        if parts[1] == "data.json" { return .json(DispatchQueue.main.sync { self.lastHit[page] = Date(); return self.data(page) }) }
        if page == "music", parts[1] == "art.jpg" {
            let jpeg = DispatchQueue.main.sync { self.art?.jpeg } ?? Data()
            return jpeg.isEmpty ? nil : MonitorServer.Response(type: "image/jpeg", body: jpeg)
        }
        if page == "flights", parts.count == 5, parts[1] == "tile", let z = Int(parts[2]), let x = Int(parts[3]), let y = Int(parts[4].replacingOccurrences(of: ".png", with: "")) {
            guard let png = MapTiles.tile(z: z, x: x, y: y) else { return MonitorServer.Response("404 Not Found", type: "text/plain", body: Data()) }
            return MonitorServer.Response(type: "image/png", body: png)
        }
        return nil
    }

    private func data(_ page: String) -> [String: Any] {
        switch page {
        case "claude": return claude
        case "crypto": return crypto
        case "weather": return weather
        case "music": return music
        case "calendar": return calendar
        case "flights": return flights
        case "sky": return sky
        case "news": return news
        case "verse": return verse
        case "tasks": return linear
        default: return [:]
        }
    }

    // MARK: helpers

    nonisolated static func thin(_ pts: [Double], to n: Int) -> [Double] {
        guard pts.count > n, n > 1 else { return pts }
        return (0..<n).map { pts[$0 * (pts.count - 1) / (n - 1)] }
    }

    nonisolated static func jpeg(_ img: NSImage, side: Int) -> Data? {
        let out = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            img.draw(in: rect, from: .zero, operation: .copy, fraction: 1); return true
        }
        guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    // MARK: pages

    /// The pages live in `Resources/pages/` (`shell.html` with `{{TITLE}}` and `{{JS}}`, one `<page>.js` per
    /// app, `monitor.html` on its own), read once at startup into `resources`. A page whose file is absent
    /// gets a plain "page missing" HTML with the file name, never a crash; `start()` reports the gap once.
    nonisolated static let resourceNames = ["shell.html", "monitor.html"] + pages.filter { $0 != "monitor" }.map { "\($0).js" }

    nonisolated static let resources: [String: String] = {
        var out: [String: String] = [:]
        for name in resourceNames {
            guard let url = resourceURL(name), var s = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if s.hasSuffix("\n") { s.removeLast() }   // the files end in a newline; the shell adds its own
            out[name] = s
        }
        return out
    }()

    nonisolated static var missingResources: [String] { resourceNames.filter { resources[$0] == nil } }

    /// `Bundle.module` without its fatalError: the SwiftPM resource bundle sits next to the binary under
    /// `.build/<conf>/` and in `Contents/Resources/` inside Deckhand.app (packaging/make-app.sh copies it).
    nonisolated static func resourceURL(_ name: String) -> URL? {
        let bundleName = "UltraWorkspaceMac_UltraWorkspaceApp.bundle"
        let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent()]
        let ext = (name as NSString).pathExtension, base = (name as NSString).deletingPathExtension
        for root in roots.compactMap({ $0 }) {
            if let bundle = Bundle(url: root.appendingPathComponent(bundleName)),
               let url = bundle.url(forResource: base, withExtension: ext, subdirectory: "pages") { return url }
            let flat = root.appendingPathComponent("pages").appendingPathComponent(name)   // `swift run` from a checkout
            if FileManager.default.fileExists(atPath: flat.path) { return flat }
        }
        return nil
    }

    nonisolated static func html(_ page: String) -> String {
        switch page {
        case "monitor": return resources["monitor.html"] ?? missing("monitor.html")
        case "claude": return wrap("Claude", "claude.js")
        case "crypto": return wrap("Crypto", "crypto.js")
        case "weather": return wrap("Weather", "weather.js")
        case "music": return wrap("Music", "music.js")
        case "calendar": return wrap("Calendar", "calendar.js")
        case "flights": return wrap("Flights", "flights.js")
        case "sky": return wrap("Sun & Moon", "sky.js")
        case "news": return wrap("Headlines", "news.js")
        case "verse": return wrap("Verse", "verse.js")
        case "tasks": return wrap("Tasks", "tasks.js")
        default: return wrap(page, "")
        }
    }

    /// Shared shell (`shell.html`): dark grey 1424×280 canvas, a ✕, a "waiting" overlay, and a poll loop that
    /// calls `render(d)` from the page's script. `script` is the resource name; "" gives the bare shell.
    nonisolated static func wrap(_ title: String, _ script: String) -> String {
        guard let shell = resources["shell.html"] else { return missing("shell.html") }
        let js: String
        if script.isEmpty { js = "" } else if let s = resources[script] { js = s } else { return missing(script) }
        return shell.replacingOccurrences(of: "{{TITLE}}", with: title).replacingOccurrences(of: "\n{{JS}}\n", with: "\n" + js + "\n")
    }

    nonisolated static func missing(_ name: String) -> String {
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>Deckhand</title></head><body style=\"margin:0;background:#1c2029;color:#fff;font:20px -apple-system,sans-serif;display:flex;align-items:center;justify-content:center;width:1424px;height:280px\">Page missing: \(name) is not in the Deckhand resource bundle. Rebuild with packaging/make-app.sh.</body></html>"
    }
}
