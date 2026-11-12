import Foundation

// Strava API v3 shapes and what the Training bar app gets from them. Foundation only and free of state, so the
// decoding and the snapshot can be checked against Strava's documented sample responses on their own
// (see the scratch decode test in the app's notes). The network side, OAuth and the tokens are in StravaFeed.swift.

/// What Deckhand keeps after the athlete connected: a user-only secret file (`Store.saveSecret(name: "strava-tokens")`),
/// never settings.json, never logged.
struct StravaTokens: Codable, Equatable, Sendable {
    var access: String
    var refresh: String
    /// Epoch seconds; Strava's access tokens live six hours.
    var expiresAt: Int
    var athleteID: Int
    var firstName: String
    /// The scopes the athlete granted (they can untick some on Strava's page).
    var scope: String
}

/// `POST /oauth/token` (both the code exchange and a refresh). The refresh answer has no athlete.
struct StravaTokenResponse: Decodable, Sendable {
    struct Athlete: Decodable, Sendable { var id: Int; var firstname: String? }
    var access_token: String
    var refresh_token: String
    var expires_at: Int
    var athlete: Athlete?
}

/// One entry of `GET /athlete/activities` (SummaryActivity); only the fields the page shows. Strava sends nulls freely
/// (polyline, heart rate, workout type), so everything but the core is optional.
struct StravaActivity: Decodable, Sendable {
    struct Map: Decodable, Sendable { var summary_polyline: String? }
    var id: Int
    var name: String
    var distance: Double
    var moving_time: Int
    var elapsed_time: Int
    var total_elevation_gain: Double?
    var type: String
    var sport_type: String?
    /// UTC.
    var start_date: String
    /// The wall-clock time where the activity happened, written with a misleading "Z".
    var start_date_local: String?
    var average_speed: Double?
    var max_speed: Double?
    var average_heartrate: Double?
    var max_heartrate: Double?
    var kudos_count: Int?
    var achievement_count: Int?
    var pr_count: Int?
    var kilojoules: Double?
    var trainer: Bool?
    var manual: Bool?
    var map: Map?

    var sport: String { sport_type ?? type }
}

/// One `ActivityTotal` of `GET /athletes/{id}/stats`.
struct StravaTotal: Decodable, Sendable {
    var count: Int = 0
    var distance: Double = 0
    var moving_time: Int = 0
    var elevation_gain: Double = 0
}

/// `GET /athletes/{id}/stats`. Strava's own sample sends `""` for a total with nothing in it, so a total that is
/// not an object decodes as empty instead of failing the whole response. Only activities visible to Everyone count.
struct StravaStats: Decodable, Sendable {
    var ytdRun = StravaTotal(), ytdRide = StravaTotal(), ytdSwim = StravaTotal()
    var recentRun = StravaTotal(), recentRide = StravaTotal(), recentSwim = StravaTotal()
    init() {}
    private enum K: String, CodingKey {
        case ytd_run_totals, ytd_ride_totals, ytd_swim_totals, recent_run_totals, recent_ride_totals, recent_swim_totals
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        func t(_ k: K) -> StravaTotal { ((try? c.decodeIfPresent(StravaTotal.self, forKey: k)) ?? nil) ?? StravaTotal() }
        ytdRun = t(.ytd_run_totals); ytdRide = t(.ytd_ride_totals); ytdSwim = t(.ytd_swim_totals)
        recentRun = t(.recent_run_totals); recentRide = t(.recent_ride_totals); recentSwim = t(.recent_swim_totals)
    }
}

enum StravaData {
    // MARK: decoding

    static func activities(_ data: Data) throws -> [StravaActivity] { try JSONDecoder().decode([StravaActivity].self, from: data) }
    static func stats(_ data: Data) throws -> StravaStats { try JSONDecoder().decode(StravaStats.self, from: data) }
    static func token(_ data: Data) throws -> StravaTokenResponse { try JSONDecoder().decode(StravaTokenResponse.self, from: data) }

    /// Strava's `{"message":…,"errors":[{"resource","field","code"}]}` as one line, for the status text.
    static func errorMessage(_ data: Data) -> String? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let msg = o["message"] as? String
        let errs = (o["errors"] as? [[String: Any]])?.compactMap { e -> String? in
            [e["resource"], e["field"], e["code"]].compactMap { $0 as? String }.filter { !$0.isEmpty }.joined(separator: " ")
        }.filter { !$0.isEmpty } ?? []
        let all = ([msg].compactMap { $0 } + errs).joined(separator: ": ")
        return all.isEmpty ? nil : all
    }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()
    static func date(_ s: String?) -> Date? { s.flatMap { iso.date(from: $0) } }

    // MARK: the route

    /// Google's encoded polyline (precision 5) to [lat, lon] pairs. Stops at the first malformed character.
    static func decodePolyline(_ s: String) -> [(lat: Double, lon: Double)] {
        var out: [(Double, Double)] = []
        let bytes = Array(s.utf8)
        var i = 0, lat = 0, lon = 0
        func next() -> Int? {
            var result = 0, shift = 0
            while i < bytes.count {
                let b = Int(bytes[i]) - 63; i += 1
                guard b >= 0, shift < 32 else { return nil }
                result |= (b & 0x1f) << shift; shift += 5
                if b < 0x20 { return (result & 1) != 0 ? ~(result >> 1) : result >> 1 }
            }
            return nil
        }
        while i < bytes.count {
            guard let dLat = next(), let dLon = next() else { break }
            lat += dLat; lon += dLon
            out.append((Double(lat) / 1e5, Double(lon) / 1e5))
        }
        return out
    }

    /// The route's shape for the bar: at most `max` points in a unit box (x right, y down, aspect kept, centred),
    /// three decimals. Only the shape leaves the Mac, never a coordinate.
    static func routeShape(_ polyline: String?, max: Int = 100) -> [[Double]] {
        guard let polyline, !polyline.isEmpty else { return [] }
        let pts = decodePolyline(polyline)
        guard pts.count >= 2 else { return [] }
        let midLat = (pts.map(\.lat).min()! + pts.map(\.lat).max()!) / 2, k = cos(midLat * .pi / 180)
        let xy = pts.map { (x: $0.lon * k, y: -$0.lat) }
        let x0 = xy.map(\.x).min()!, x1 = xy.map(\.x).max()!, y0 = xy.map(\.y).min()!, y1 = xy.map(\.y).max()!
        let span = Swift.max(x1 - x0, y1 - y0, 1e-9), ox = (span - (x1 - x0)) / 2, oy = (span - (y1 - y0)) / 2
        let step = Swift.max(1, Int((Double(xy.count) / Double(max)).rounded(.up)))
        var picked = stride(from: 0, to: xy.count, by: step).map { xy[$0] }
        if (xy.count - 1) % step != 0 { picked.append(xy[xy.count - 1]) }
        func r(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
        return picked.map { [r(($0.x - x0 + ox) / span), r(($0.y - y0 + oy) / span)] }
    }

    // MARK: sports

    /// The page groups sports as Strava's own weekly view does.
    static func group(_ sport: String) -> String {
        switch sport {
        case "Run", "TrailRun", "VirtualRun": return "run"
        case "Ride", "MountainBikeRide", "GravelRide", "EBikeRide", "EMountainBikeRide", "VirtualRide", "Velomobile", "Handcycle": return "ride"
        case "Swim": return "swim"
        case "Walk", "Hike": return "walk"
        default: return "other"
        }
    }
    static func groupLabel(_ g: String) -> String { ["run": "Run", "ride": "Ride", "swim": "Swim", "walk": "Walk", "other": "Other"][g] ?? "Other" }
    /// "TrailRun" → "Trail run", "EBikeRide" → "E-bike ride".
    static func sportLabel(_ s: String) -> String {
        let special = ["EBikeRide": "E-bike ride", "EMountainBikeRide": "E-mountain bike ride", "MountainBikeRide": "Mountain bike ride",
                       "VirtualRide": "Virtual ride", "VirtualRun": "Virtual run", "HighIntensityIntervalTraining": "HIIT",
                       "StandUpPaddling": "Stand-up paddling", "RockClimbing": "Rock climbing"]
        if let v = special[s] { return v }
        var out = ""
        for (i, ch) in s.enumerated() { if i > 0, ch.isUppercase { out += " " + ch.lowercased() } else { out.append(ch) } }
        return out.isEmpty ? "Activity" : out
    }

    // MARK: formatting

    struct Units: Sendable { var metric = true; var clock24h = true }

    static func distance(_ m: Double, group g: String, _ u: Units) -> String {
        if g == "swim" { return u.metric ? "\(Int(m.rounded())) m" : "\(Int((m / 0.9144).rounded())) yd" }
        let v = u.metric ? m / 1000 : m / 1609.344
        return (v >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v)) + (u.metric ? " km" : " mi")
    }
    /// 3725 → "1:02:05", 1930 → "32:10".
    static func duration(_ s: Int) -> String {
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
    /// 45 h 12 min for the totals, where seconds do not matter.
    static func hours(_ s: Int) -> String { s >= 3600 ? "\(s / 3600) h \(String(format: "%02d", (s % 3600) / 60)) min" : "\(s / 60) min" }
    static func elevation(_ m: Double, _ u: Units) -> String { u.metric ? "\(Int(m.rounded())) m" : "\(Int((m * 3.28084).rounded())) ft" }
    /// Pace for running and walking (per km or mile), per 100 m (or yards) for swimming, speed for the rest.
    static func pace(_ mps: Double?, group g: String, _ u: Units) -> String? {
        guard let v = mps, v > 0.05 else { return nil }
        func mmss(_ sec: Double) -> String { let s = Int(sec.rounded()); return "\(s / 60):\(String(format: "%02d", s % 60))" }
        switch g {
        case "run", "walk": return mmss((u.metric ? 1000 : 1609.344) / v) + (u.metric ? " /km" : " /mi")
        case "swim": return mmss((u.metric ? 100 : 91.44) / v) + (u.metric ? " /100 m" : " /100 yd")
        default: return String(format: "%.1f", v * (u.metric ? 3.6 : 2.236936)) + (u.metric ? " km/h" : " mph")
        }
    }

    /// "Today · 07:12", "Yesterday · 18:40", else the Mac's locale ("wo 11 nov · 07:12"), from the local wall time.
    static func when(_ a: StravaActivity, now: Date, _ u: Units, calendar: Calendar = .current) -> String {
        guard let utc = date(a.start_date) else { return "" }
        // start_date_local is the wall time at the start; read it as UTC and print it as UTC to keep it as is.
        let wall = date(a.start_date_local) ?? utc
        var cu = Calendar(identifier: .gregorian); cu.timeZone = TimeZone(identifier: "UTC")!
        let t = DateFormatter(); t.timeZone = cu.timeZone; t.dateFormat = u.clock24h ? "HH:mm" : "h:mm a"
        let d = DateFormatter(); d.timeZone = cu.timeZone; d.locale = calendar.locale ?? .current; d.setLocalizedDateFormatFromTemplate("EEEd MMM")
        let day = calendar.isDate(utc, inSameDayAs: now) ? "Today" : calendar.isDate(utc, inSameDayAs: now.addingTimeInterval(-86400)) ? "Yesterday" : d.string(from: wall)
        return day + " · " + t.string(from: wall)
    }

    // MARK: what the bar gets

    /// Start of this week and of last week in the Mac's calendar (Monday in NL).
    static func weekStarts(now: Date, calendar: Calendar = .current) -> (this: Date, last: Date) {
        let this = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        return (this, calendar.date(byAdding: .day, value: -7, to: this) ?? this.addingTimeInterval(-7 * 86400))
    }

    static func activityRow(_ a: StravaActivity, now: Date, _ u: Units, calendar: Calendar = .current) -> [String: Any] {
        let g = group(a.sport)
        var r: [String: Any] = ["id": a.id, "name": a.name, "sport": g, "label": sportLabel(a.sport), "when": when(a, now: now, u, calendar: calendar),
                                "dist": a.distance > 0 ? distance(a.distance, group: g, u) : "", "moving": duration(a.moving_time),
                                "elapsed": duration(a.elapsed_time), "route": routeShape(a.map?.summary_polyline)]
        if let p = pace(a.average_speed, group: g, u), a.distance > 0 { r["pace"] = p }
        if let e = a.total_elevation_gain, e >= 1 { r["elev"] = elevation(e, u) }
        if let h = a.average_heartrate { r["hr"] = Int(h.rounded()) }
        if let h = a.max_heartrate { r["hrMax"] = Int(h.rounded()) }
        if let m = a.max_speed, m > 0, g != "swim" { r["maxSpeed"] = String(format: "%.1f", m * (u.metric ? 3.6 : 2.236936)) + (u.metric ? " km/h" : " mph") }
        if let k = a.kudos_count { r["kudos"] = k }
        if let p = a.pr_count, p > 0 { r["prs"] = p }
        if let kj = a.kilojoules, kj > 0 { r["kj"] = Int(kj.rounded()) }
        if a.trainer == true { r["indoor"] = true }
        return r
    }

    /// The page's document, without the connection state (StravaFeed adds that): the latest five activities, this
    /// week against last week per sport, and the year so far per sport from the stats.
    static func snapshot(activities: [StravaActivity], stats: StravaStats?, now: Date, units u: Units, calendar: Calendar = .current) -> [String: Any] {
        let sorted = activities.sorted { (date($0.start_date) ?? .distantPast) > (date($1.start_date) ?? .distantPast) }
        let (thisStart, lastStart) = weekStarts(now: now, calendar: calendar)
        struct Sum { var n = 0, dist = 0.0, time = 0, elev = 0.0 }
        var this: [String: Sum] = [:], last: [String: Sum] = [:]
        for a in sorted {
            guard let d = date(a.start_date), d >= lastStart else { continue }
            let g = group(a.sport)
            func add(_ s: inout Sum) { s.n += 1; s.dist += a.distance; s.time += a.moving_time; s.elev += a.total_elevation_gain ?? 0 }
            if d >= thisStart { add(&this[g, default: Sum()]) } else { add(&last[g, default: Sum()]) }
        }
        func sumDict(_ s: Sum, _ g: String) -> [String: Any] {
            ["n": s.n, "distM": (s.dist).rounded(), "time": s.time, "dist": s.dist > 0 ? distance(s.dist, group: g, u) : "",
             "timeText": hours(s.time), "elev": elevation(s.elev, u)]
        }
        // The sports of either week, most time this week first, then last week's.
        let groups = Set(this.keys).union(last.keys).sorted { a, b in
            let ta = this[a]?.time ?? 0, tb = this[b]?.time ?? 0
            return ta != tb ? ta > tb : (last[a]?.time ?? 0) > (last[b]?.time ?? 0)
        }
        let weeks: [[String: Any]] = groups.map { g in
            ["sport": g, "label": groupLabel(g), "this": sumDict(this[g] ?? Sum(), g), "last": sumDict(last[g] ?? Sum(), g)]
        }
        var ytd: [[String: Any]] = []
        if let s = stats {
            for (g, t) in [("run", s.ytdRun), ("ride", s.ytdRide), ("swim", s.ytdSwim)] where t.count > 0 {
                ytd.append(["sport": g, "label": groupLabel(g), "n": t.count, "dist": distance(t.distance, group: g, u),
                            "time": hours(t.moving_time), "elev": elevation(t.elevation_gain, u)])
            }
        }
        let df = DateFormatter(); df.locale = calendar.locale ?? .current; df.setLocalizedDateFormatFromTemplate("yyyy")
        return ["latest": sorted.prefix(5).map { activityRow($0, now: now, u, calendar: calendar) }, "weeks": weeks,
                "ytd": ytd, "year": df.string(from: now), "hasStats": stats != nil]
    }
}
