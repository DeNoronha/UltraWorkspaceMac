import Foundation
import UltraBarKit

/// Amsterdam Schiphol for the Schiphol bar app: which runways are in use for landing and take-off, worked out from
/// live ADS-B positions (adsb.lol, keyless, ODbL), the aircraft around the field for a runway schematic, how many
/// landed and took off in the last 15 minutes, and — when the user has registered for Schiphol's Public Flight
/// API — the next arrivals and departures from the airport's own timetable.
///
/// Deckhand polls, keeps the 15-minute history and holds the Schiphol credentials, so the bar never waits on the
/// network and the credentials never leave this Mac; the bar app asks for `/schiphol/data.json`.
@MainActor
final class SchipholFeed {

    // MARK: the field

    /// One runway direction: the threshold an aircraft lands on or takes off from, and the true heading it flies.
    struct End { let id: String; let lat: Double; let lon: Double; let heading: Double }
    struct Runway { let name: String; let a: End; let b: End }
    /// Thresholds and true headings from OurAirports (public domain, matches the AIP to a few metres).
    nonisolated static let runways: [Runway] = [
        Runway(name: "Polderbaan", a: End(id: "18R", lat: 52.36270, lon: 4.71193, heading: 183), b: End(id: "36L", lat: 52.32860, lon: 4.70884, heading: 3)),
        Runway(name: "Kaagbaan", a: End(id: "06", lat: 52.28790, lon: 4.73402, heading: 58), b: End(id: "24", lat: 52.30460, lon: 4.77752, heading: 238)),
        Runway(name: "Buitenveldertbaan", a: End(id: "09", lat: 52.31660, lon: 4.74635, heading: 87), b: End(id: "27", lat: 52.31840, lon: 4.79689, heading: 267)),
        Runway(name: "Aalsmeerbaan", a: End(id: "18L", lat: 52.32130, lon: 4.77996, heading: 183), b: End(id: "36R", lat: 52.29080, lon: 4.77735, heading: 3)),
        Runway(name: "Zwanenburgbaan", a: End(id: "18C", lat: 52.33140, lon: 4.74003, heading: 183), b: End(id: "36C", lat: 52.30180, lon: 4.73750, heading: 3)),
        Runway(name: "Oostbaan", a: End(id: "04", lat: 52.30040, lon: 4.78348, heading: 41), b: End(id: "22", lat: 52.31400, lon: 4.80302, heading: 221)),
    ]
    /// The airport reference point; the schematic's (0, 0).
    nonisolated static let ref = (lat: 52.3086, lon: 4.7639)
    /// Kilometres east and north of the reference point (flat earth is fine over 40 km).
    nonisolated static func xy(_ lat: Double, _ lon: Double) -> (x: Double, y: Double) {
        ((lon - ref.lon) * 111.32 * cos(ref.lat * .pi / 180), (lat - ref.lat) * 110.574)
    }
    nonisolated static func angle(_ a: Double, _ b: Double) -> Double { let d = abs((a - b).truncatingRemainder(dividingBy: 360)); return d > 180 ? 360 - d : d }

    /// What an aircraft is doing relative to one runway direction, with a score (lower fits better).
    enum Phase: String { case arriving = "arr", departing = "dep" }
    struct Fit { let end: End; let runway: Runway; let phase: Phase; let score: Double; let km: Double }

    /// Position of a point along and across a runway direction: `along` in km from the threshold in the direction
    /// of flight (negative: still before it), `cross` the distance from the extended centre line.
    nonisolated static func relative(_ p: (x: Double, y: Double), to e: End) -> (along: Double, cross: Double) {
        let t = xy(e.lat, e.lon), h = e.heading * .pi / 180, ux = sin(h), uy = cos(h)
        let dx = p.x - t.x, dy = p.y - t.y
        return (dx * ux + dy * uy, abs(dx * uy - dy * ux))
    }
    nonisolated static func length(_ r: Runway) -> Double { let a = xy(r.a.lat, r.a.lon), b = xy(r.b.lat, r.b.lon); return hypot(a.x - b.x, a.y - b.y) }

    /// The runway direction an airborne aircraft is landing on or climbing out from, if any. Heights are feet above
    /// the field. An approach is the extended centre line up to 25 km out, within a funnel that widens with
    /// distance, at most a generous 3° glide path high, not climbing; a departure is beyond the middle of the runway,
    /// on the centre line widening to 2.6 km at 20 km out, climbing.
    nonisolated static func classify(x: Double, y: Double, track: Double?, height: Double, rate: Double?, climbing: Bool?) -> Fit? {
        guard let track else { return nil }
        var best: Fit?
        for r in runways {
            let len = length(r)
            for e in [r.a, r.b] {
                let off = angle(track, e.heading)
                guard off <= 25 else { continue }
                let (along, cross) = relative((x, y), to: e)
                var fit: Fit?
                if along >= -25, along <= 0.5, height <= 3500, height <= 500 + 230 * abs(along), (rate ?? 0) <= 300, climbing != true {
                    let funnel = 0.5 + 0.07 * abs(along)
                    if cross <= funnel { fit = Fit(end: e, runway: r, phase: .arriving, score: cross / funnel + off / 25, km: -along) }
                } else if along >= len * 0.4, along <= len + 20, height <= 6000, height <= 1000 + 500 * max(0, along - len * 0.4),
                          (rate.map { $0 >= 300 } ?? climbing ?? false) {
                    let funnel = 0.6 + 0.1 * max(0, along - len)
                    if cross <= funnel { fit = Fit(end: e, runway: r, phase: .departing, score: cross / funnel + off / 25, km: along - len) }
                }
                if let f = fit, f.score < (best?.score ?? .infinity) { best = f }
            }
        }
        return best
    }

    // MARK: state

    struct Plane {
        var callsign = "", type = "", reg = ""
        var lat = 0.0, lon = 0.0
        var track: Double?
        var ground = false
        var height = 0.0, gs = 0.0
        var rate: Double?
        var seen = Date()
        var phase: Phase?
        var end: String?
    }
    /// One landing or take-off seen on ADS-B.
    struct Movement { let hex: String; let callsign: String; let type: String; let phase: Phase; let end: String; let runway: String; let at: Date }
    /// A route from adsbdb.com for an ICAO callsign: the IATA flight number and the other airport's town.
    struct Route { let flight: String?; let from: String?; let to: String?; let at: Date }

    private var planes: [String: Plane] = [:]
    private var movements: [Movement] = []
    private var routes: [String: Route] = [:]
    private var routeQueue: [String] = []
    private(set) var lastFetch = Date.distantPast
    /// When the counts started: the first poll after a gap of more than two minutes.
    private var movementsSince = Date.distantPast
    private(set) var trafficError: String?
    private(set) var aircraftCount = 0
    private var loops: [Task<Void, Never>] = []

    // Timetable (Schiphol Public Flight API).
    struct Flight { let name: String; let sched: Date; let est: Date?; let place: String; let states: [String]; let gate: String?; let cancelled: Bool }
    private(set) var arrivals: [Flight] = []
    private(set) var departures: [Flight] = []
    private(set) var boardError: String?
    private(set) var boardAt = Date.distantPast
    private var token: (value: String, until: Date)?
    /// Which kind of credentials Schiphol took: OAuth client credentials (developer portal since 2026) or the
    /// older app_id/app_key headers. nil until a call succeeded.
    private var legacy: Bool?
    private var places: [String: String] = SchipholFeed.loadPlaces()
    private var credentialsChanged = false

    nonisolated static let secretID = "schiphol-id", secretKey = "schiphol-key"
    nonisolated static var hasCredentials: Bool { !(Store.shared.loadSecret(name: secretID) ?? "").isEmpty && !(Store.shared.loadSecret(name: secretKey) ?? "").isEmpty }
    /// Called by the settings when the ID or secret changed: forget the token and fetch the timetable at once.
    func credentialsDidChange() { token = nil; legacy = nil; credentialsChanged = true; boardError = nil; if !Self.hasCredentials { arrivals = []; departures = [] } }

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15; c.timeoutIntervalForResource = 25   // a hard cap, so a call can never hang the loop
        c.httpAdditionalHeaders = ["User-Agent": "Deckhand (+https://denoronha.github.io/UltraWorkspaceMac/)"]
        return URLSession(configuration: c)
    }()

    /// `open()`: the page asked within the last two minutes; `installed()`: the app is on the bar.
    /// ADS-B: every 10 s while the page is open, every 30 s while it is only installed (so the 15-minute counts are
    /// right the moment it is opened), not at all otherwise. Timetable: every 3 minutes while open, every 15 otherwise.
    func start(open: @escaping @MainActor () -> Bool, installed: @escaping @MainActor () -> Bool) {
        stop()
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let o = open()
                if o || installed() { await self.pollTraffic(); await self.resolveRoutes() }
                for _ in 0..<(o ? 2 : 6) { try? await Task.sleep(nanoseconds: 5_000_000_000); if !o && open() { break } }
            }
        })
        loops.append(Task { [weak self] in
            var last = Date.distantPast
            while !Task.isCancelled {
                guard let self else { return }
                let o = open(), every: TimeInterval = o ? 180 : 900
                if (o || installed()) && Self.hasCredentials && (self.credentialsChanged || Date().timeIntervalSince(last) >= every) {
                    self.credentialsChanged = false; last = Date()
                    await self.pollBoard()
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        })
    }

    func stop() { loops.forEach { $0.cancel() }; loops.removeAll() }

    // MARK: ADS-B

    private func pollTraffic() async {
        // 20 NM around the field: the whole final approach (25 km) of every runway and the first part of every climb-out.
        guard let url = URL(string: String(format: "https://api.adsb.lol/v2/point/%.4f/%.4f/20", Self.ref.lat, Self.ref.lon)) else { return }
        do {
            let (data, resp) = try await session.data(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { trafficError = "adsb.lol answered \((resp as? HTTPURLResponse)?.statusCode ?? 0)"; return }
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let ac = obj["ac"] as? [[String: Any]] else { trafficError = "adsb.lol sent something unexpected"; return }
            // After a gap (Mac asleep, app just installed) the counts start over from here.
            if Date().timeIntervalSince(lastFetch) > 120 { movementsSince = Date() }
            ingest(ac)
            trafficError = nil; lastFetch = Date()
        } catch { trafficError = "adsb.lol: \(error.localizedDescription)" }
    }

    private func ingest(_ ac: [[String: Any]]) {
        let now = Date()
        func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
        var seen = Set<String>()
        for a in ac {
            guard let hex = a["hex"] as? String, let lat = num(a["lat"]), let lon = num(a["lon"]) else { continue }
            if let s = num(a["seen_pos"]), s > 30 { continue }   // a stale position would put the plane somewhere it left
            seen.insert(hex)
            var p = planes[hex] ?? Plane()
            let before = p
            p.callsign = (a["flight"] as? String)?.trimmingCharacters(in: .whitespaces) ?? p.callsign
            p.type = (a["t"] as? String) ?? p.type; p.reg = (a["r"] as? String) ?? p.reg
            p.lat = lat; p.lon = lon
            p.track = num(a["track"]) ?? num(a["true_heading"]) ?? p.track
            p.ground = (a["alt_baro"] as? String) == "ground"
            // Height above the field: GNSS height minus the geoid (about 43 m here) when there is one, else pressure
            // altitude, which is off by up to a few hundred feet with the day's air pressure.
            if p.ground { p.height = 0 } else if let g = num(a["alt_geom"]) { p.height = g - 140 } else if let b = num(a["alt_baro"]) { p.height = b }
            p.gs = num(a["gs"]) ?? 0
            p.rate = num(a["baro_rate"]) ?? num(a["geom_rate"])
            let climbing: Bool? = before.seen < now && now.timeIntervalSince(before.seen) < 90 && !before.ground && !p.ground ? p.height > before.height + 50 : nil
            p.seen = now
            let pos = Self.xy(lat, lon)
            p.phase = nil; p.end = nil
            if !p.ground, let f = Self.classify(x: pos.x, y: pos.y, track: p.track, height: p.height, rate: p.rate, climbing: climbing) {
                p.phase = f.phase; p.end = f.end.id
                record(hex: hex, plane: p, phase: f.phase, end: f.end.id, runway: f.runway.name, at: now)
            } else if p.ground, p.gs >= 40, let t = p.track {
                // Fast on a runway: a landing roll-out when it was on the approach just now, else a take-off run.
                for r in Self.runways { for e in [r.a, r.b] where Self.angle(t, e.heading) < 15 {
                    let (along, cross) = Self.relative(pos, to: e)
                    guard cross < 0.12, along > -0.2, along < Self.length(r) + 0.2 else { continue }
                    if before.phase == .arriving && before.end == e.id { p.phase = .arriving; p.end = e.id }
                    else if p.gs > before.gs + 5 { p.phase = .departing; p.end = e.id; record(hex: hex, plane: p, phase: .departing, end: e.id, runway: r.name, at: now) }
                } }
            }
            planes[hex] = p
        }
        planes = planes.filter { seen.contains($0.key) || now.timeIntervalSince($0.value.seen) < 60 }
        movements.removeAll { now.timeIntervalSince($0.at) > 3600 }
        aircraftCount = planes.count
    }

    /// One landing or take-off per aircraft: the first time it is seen on the approach or climbing out. A
    /// take-off within 15 minutes of the same aircraft's approach is a go-around, not a departure.
    private func record(hex: String, plane p: Plane, phase: Phase, end: String, runway: String, at: Date) {
        let recent = movements.filter { $0.hex == hex && at.timeIntervalSince($0.at) < 1800 }
        if recent.contains(where: { $0.phase == phase }) { return }
        if phase == .departing, recent.contains(where: { $0.phase == .arriving && at.timeIntervalSince($0.at) < 900 }) { return }
        movements.append(Movement(hex: hex, callsign: p.callsign, type: p.type, phase: phase, end: end, runway: runway, at: at))
        if !p.callsign.isEmpty, routes[p.callsign] == nil, !routeQueue.contains(p.callsign) { routeQueue.append(p.callsign) }
    }

    /// Routes for new movements from adsbdb.com, a few per round and each callsign once a day (it asks to be gentle).
    private func resolveRoutes() async {
        routes = routes.filter { Date().timeIntervalSince($0.value.at) < 86400 }
        for cs in routeQueue.prefix(3) {
            routeQueue.removeAll { $0 == cs }
            guard cs.count >= 3, cs.count <= 8, cs.allSatisfy({ $0.isLetter || $0.isNumber }),
                  let url = URL(string: "https://api.adsbdb.com/v0/callsign/\(cs)") else { continue }
            // Offline, rate-limited or a server error: try again next round. 404 means adsbdb does not know the callsign.
            guard let (data, resp) = try? await session.data(from: url) else { routeQueue.append(cs); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 || code == 404 else { routeQueue.append(cs); return }
            var r = Route(flight: nil, from: nil, to: nil, at: Date())
            if let fr = (((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["response"] as? [String: Any])?["flightroute"] as? [String: Any] {
                func town(_ k: String) -> String? { let a = fr[k] as? [String: Any]; return (a?["municipality"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? a?["name"] as? String }
                r = Route(flight: fr["callsign_iata"] as? String, from: town("origin"), to: town("destination"), at: Date())
            }
            routes[cs] = r
        }
    }

    // MARK: Schiphol Public Flight API

    nonisolated static let tokenURL = "https://api.auth.schiphol.nl/oauth/token"
    nonisolated static let audience = "https://api.schiphol.nl/public"
    nonisolated static let flightsBase = "https://api.schiphol.nl/public/public-flights/v4"
    /// The pre-2026 gateway that takes `app_id`/`app_key` headers.
    nonisolated static let legacyBase = "https://api.schiphol.nl/public-flights"

    enum BoardError: LocalizedError {
        case refused, status(Int), limited
        var errorDescription: String? {
            switch self {
            case .refused: return "Schiphol did not accept this ID and key."
            case .status(let s): return "Schiphol answered \(s)."
            case .limited: return "Schiphol's rate limit; trying again later."
            }
        }
    }

    /// A bearer token for the OAuth client credentials, refreshed a minute before it runs out (they last 30 min).
    private func bearer(id: String, secret: String) async throws -> String? {
        if let t = token, t.until > Date().addingTimeInterval(60) { return t.value }
        guard let url = URL(string: Self.tokenURL) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "grant_type", value: "client_credentials"), URLQueryItem(name: "client_id", value: id),
                           URLQueryItem(name: "client_secret", value: secret), URLQueryItem(name: "audience", value: Self.audience)]
        req.httpBody = (form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if [400, 401, 403].contains(code) { return nil }
        guard code == 200, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let t = obj["access_token"] as? String else { throw BoardError.status(code) }
        token = (t, Date().addingTimeInterval((obj["expires_in"] as? Double) ?? 1800))
        return t
    }

    /// GET on the flight API with whichever credentials work: OAuth first, the old headers when the token endpoint
    /// does not know the client. Nil on 204 (nothing found).
    private func get(_ path: String, _ query: [URLQueryItem]) async throws -> [String: Any]? {
        let id = Store.shared.loadSecret(name: Self.secretID) ?? "", secret = Store.shared.loadSecret(name: Self.secretKey) ?? ""
        guard !id.isEmpty, !secret.isEmpty else { throw BoardError.refused }
        func request(legacy: Bool, bearer: String?) -> URLRequest? {
            guard var c = URLComponents(string: (legacy ? Self.legacyBase : Self.flightsBase) + path) else { return nil }
            if !query.isEmpty {
                c.queryItems = query
                // "+scheduleDateTime" must arrive as a plus, not as a space.
                let q = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
                c.percentEncodedQuery = q
            }
            guard let url = c.url else { return nil }
            var r = URLRequest(url: url)
            r.setValue("application/json", forHTTPHeaderField: "Accept")
            if legacy { r.setValue(id, forHTTPHeaderField: "app_id"); r.setValue(secret, forHTTPHeaderField: "app_key"); r.setValue("v4", forHTTPHeaderField: "ResourceVersion") }
            else if let bearer { r.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
            return r
        }
        var useLegacy = legacy ?? false
        var tok: String?
        if !useLegacy { tok = try await bearer(id: id, secret: secret); if tok == nil { if legacy == false { throw BoardError.refused }; useLegacy = true } }
        guard let req = request(legacy: useLegacy, bearer: tok) else { return nil }
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: legacy = useLegacy; return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        case 204: legacy = useLegacy; return nil
        case 401, 403: if !useLegacy { token = nil }; throw BoardError.refused
        case 429: throw BoardError.limited
        default: throw BoardError.status(code)
        }
    }

    nonisolated static let amsterdam = TimeZone(identifier: "Europe/Amsterdam") ?? .current
    nonisolated static func parseDate(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// The next few flights each way: scheduled from half an hour ago (late ones) up to three hours ahead, codeshare
    /// duplicates dropped, those that already landed or left skipped. At most five pages of 20 per direction.
    private func pollBoard() async {
        let local = DateFormatter(); local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; local.timeZone = Self.amsterdam; local.locale = Locale(identifier: "en_US_POSIX")
        let now = Date()
        do {
            var out: [String: [Flight]] = [:]
            for dir in ["A", "D"] {
                var list: [Flight] = []
                for page in 0..<5 {
                    let q = [URLQueryItem(name: "flightDirection", value: dir), URLQueryItem(name: "includedelays", value: "false"),
                             URLQueryItem(name: "fromDateTime", value: local.string(from: now.addingTimeInterval(-1800))),
                             URLQueryItem(name: "toDateTime", value: local.string(from: now.addingTimeInterval(3 * 3600))),
                             URLQueryItem(name: "searchDateTimeField", value: "scheduleDateTime"),
                             URLQueryItem(name: "sort", value: "+scheduleDateTime"), URLQueryItem(name: "page", value: String(page))]
                    guard let obj = try await get("/flights", q), let flights = obj["flights"] as? [[String: Any]] else { break }
                    for f in flights {
                        guard let name = f["flightName"] as? String, let sched = Self.parseDate(f["scheduleDateTime"]) else { continue }
                        if let main = f["mainFlight"] as? String, main != name { continue }   // a codeshare of a flight in the list
                        let states = ((f["publicFlightState"] as? [String: Any])?["flightStates"] as? [String]) ?? []
                        let done = dir == "A" ? (f["actualLandingTime"] != nil || !Set(states).isDisjoint(with: ["LND", "FIB", "ARR"]))
                                              : (f["actualOffBlockTime"] != nil || states.contains("DEP"))
                        if done { continue }
                        let est = Self.parseDate(dir == "A" ? f["estimatedLandingTime"] : f["publicEstimatedOffBlockTime"])
                        if (est ?? sched) < now.addingTimeInterval(-600) { continue }
                        let route = ((f["route"] as? [String: Any])?["destinations"] as? [String]) ?? []
                        let iata = (dir == "A" ? route.first : route.last) ?? ""
                        list.append(Flight(name: name, sched: sched, est: est, place: iata, states: states, gate: f["gate"] as? String, cancelled: states.contains("CNX")))
                    }
                    if flights.count < 20 || list.count >= 8 { break }
                }
                out[dir] = Array(list.sorted { ($0.est ?? $0.sched) < ($1.est ?? $1.sched) }.prefix(6))
            }
            // Town names for the airports shown, once each (kept in a file next to haven.json).
            for iata in Set(((out["A"] ?? []) + (out["D"] ?? [])).map(\.place)) where places[iata] == nil && iata.count == 3 {
                if let d = try? await get("/destinations/\(iata)", []) {
                    let name = (d["city"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ((d["publicName"] as? [String: Any])?["english"] as? String)
                    places[iata] = name ?? iata
                }
            }
            Self.savePlaces(places)
            arrivals = out["A"] ?? []; departures = out["D"] ?? []
            boardError = nil; boardAt = Date()
        } catch BoardError.limited {
            boardError = BoardError.limited.errorDescription
        } catch {
            boardError = error.localizedDescription
            if case BoardError.refused = error { arrivals = []; departures = [] }
        }
    }

    nonisolated static var placesURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UltraWorkspaceMac", isDirectory: true).appendingPathComponent("schiphol-places.json")
    }
    nonisolated static func loadPlaces() -> [String: String] {
        (try? Data(contentsOf: placesURL)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }
    nonisolated static func savePlaces(_ p: [String: String]) {
        try? FileManager.default.createDirectory(at: placesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(p).write(to: placesURL, options: .atomic)
    }

    // MARK: what the bar gets

    nonisolated static func status(_ states: [String], arrival: Bool) -> String {
        let names: [String: String] = arrival
            ? ["SCH": "", "AIR": "Airborne", "EXP": "Expected", "FIR": "Approaching", "LND": "Landed", "FIB": "Bags", "ARR": "Arrived", "DIV": "Diverted", "CNX": "Cancelled", "TOM": "Tomorrow"]
            : ["SCH": "", "DEL": "Delayed", "WIL": "Wait in lounge", "GTO": "Gate open", "BRD": "Boarding", "GCL": "Gate closing", "GTD": "Gate closed", "DEP": "Departed", "CNX": "Cancelled", "GCH": "Gate change", "TOM": "Tomorrow"]
        return states.compactMap { names[$0] }.last { !$0.isEmpty } ?? ""
    }

    func snapshot(clock24h: Bool) -> [String: Any] {
        let now = Date()
        let tf = DateFormatter(); tf.dateFormat = clock24h ? "HH:mm" : "h:mm"; tf.timeZone = Self.amsterdam
        func ago(_ d: Date) -> Int { Int(now.timeIntervalSince(d)) }
        func runwayName(_ end: String) -> String { Self.runways.first { $0.a.id == end || $0.b.id == end }?.name ?? "" }
        let last15 = movements.filter { now.timeIntervalSince($0.at) < 900 }
        // In use: a runway direction with a movement in the last 20 minutes or an aircraft on it right now.
        func inUse(_ phase: Phase) -> [[String: Any]] {
            var n: [String: Int] = [:], latest: [String: Date] = [:]
            for m in movements where m.phase == phase && now.timeIntervalSince(m.at) < 1200 { n[m.end, default: 0] += 1; latest[m.end] = max(latest[m.end] ?? .distantPast, m.at) }
            for p in planes.values where p.phase == phase { if let e = p.end { n[e, default: 0] += 0; latest[e] = now } }
            return n.keys.sorted { (n[$0]!, latest[$0]!) > (n[$1]!, latest[$1]!) }.map { e in
                ["rwy": e, "name": runwayName(e), "n": n[e]!, "now": planes.values.filter { $0.phase == phase && $0.end == e }.count]
            }
        }
        let aircraft: [[String: Any]] = planes.values.compactMap { p in
            let pos = Self.xy(p.lat, p.lon)
            guard abs(pos.x) < 30, abs(pos.y) < 30 else { return nil }
            var o: [String: Any] = ["x": (pos.x * 100).rounded() / 100, "y": (pos.y * 100).rounded() / 100, "st": p.phase?.rawValue ?? (p.ground ? "gnd" : "air"),
                                    "cs": p.callsign, "h": Int(p.height)]
            if let t = p.track { o["trk"] = Int(t) }
            if let e = p.end { o["rwy"] = e }
            return o
        }
        func recent(_ phase: Phase) -> [[String: Any]] {
            movements.filter { $0.phase == phase }.suffix(6).reversed().map { m in
                let r = routes[m.callsign]
                var o: [String: Any] = ["cs": m.callsign, "f": r?.flight ?? m.callsign, "rwy": m.end, "ago": ago(m.at), "type": m.type]
                if let t = phase == .arriving ? r?.from : r?.to { o["place"] = t }
                if let p = planes[m.hex], p.phase == m.phase { o["live"] = true }   // still on final or climbing out
                return o
            }
        }
        // ADS-B aircraft on final or climbing out, by IATA flight number, to show on the timetable.
        var live: [String: String] = [:]
        for p in planes.values { if let ph = p.phase, let e = p.end, let f = routes[p.callsign]?.flight { live[f] = (ph == .arriving ? "Landing " : "Taking off ") + e } }
        func board(_ list: [Flight], arrival: Bool) -> [[String: Any]] {
            list.map { f in
                var o: [String: Any] = ["f": f.name, "t": tf.string(from: f.sched), "place": places[f.place] ?? f.place, "iata": f.place,
                                        "st": live[f.name] ?? Self.status(f.states, arrival: arrival), "x": f.cancelled]
                if let e = f.est, abs(e.timeIntervalSince(f.sched)) >= 300 { o["est"] = tf.string(from: e); o["late"] = e.timeIntervalSince(f.sched) >= 900 }
                if live[f.name] != nil { o["live"] = true }
                if let g = f.gate, !arrival { o["gate"] = g }
                return o
            }
        }
        var out: [String: Any] = [
            "at": Int(now.timeIntervalSince1970), "age": lastFetch == .distantPast ? -1 : ago(lastFetch),
            "runways": Self.runways.map { r -> [String: Any] in
                let a = Self.xy(r.a.lat, r.a.lon), b = Self.xy(r.b.lat, r.b.lon)
                return ["name": r.name, "a": ["id": r.a.id, "x": a.x, "y": a.y], "b": ["id": r.b.id, "x": b.x, "y": b.y]]
            },
            "landing": inUse(.arriving), "takeoff": inUse(.departing),
            "arr15": last15.filter { $0.phase == .arriving }.count, "dep15": last15.filter { $0.phase == .departing }.count,
            // How long the counts have been watching, so a fresh start does not pass for a quiet quarter of an hour.
            "watching": movementsSince == .distantPast ? 0 : min(900, ago(movementsSince)),
            "aircraft": aircraft, "recentArr": recent(.arriving), "recentDep": recent(.departing),
            "hasKey": Self.hasCredentials,
        ]
        if let e = trafficError { out["error"] = e }
        if Self.hasCredentials {
            out["arrivals"] = board(arrivals, arrival: true); out["departures"] = board(departures, arrival: false)
            if let e = boardError { out["boardError"] = e }
            if boardAt != .distantPast { out["boardAge"] = ago(boardAt) }
        }
        return out
    }

}
