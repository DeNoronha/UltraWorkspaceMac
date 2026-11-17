import Foundation
import EventKit
import UltraBarKit

/// The Walk bar app's data: when the dog was last out and when the next walk is due, the free gaps in today's
/// calendars (only when the user is busy, never what the meeting is), the rain for the next hours from Open-Meteo at
/// the configured location, and the best moment to go. Walks are logged from the bar (Going now, Back home, Walked
/// already, Undo) or from Apps → Walk, and kept for 60 days in walks.json in Deckhand's own folder (readable by this
/// user only). Calendar read every minute and the rain every 15 minutes, only while Walk is on the bar.
@MainActor
final class WalkFeed: ObservableObject {
    struct Config {
        var dog: String
        var interval: TimeInterval
        var length: TimeInterval
        var from: Int
        var to: Int
        var weather: Bool
        var calendars: [String]
        var metric: Bool
    }

    struct Log: Codable, Equatable {
        var walks: [Walk] = []
        var walking: Date?
    }
    struct Walk: Codable, Equatable { var start: Date; var end: Date }

    @Published private(set) var log = Log()
    @Published private(set) var lastError: String?
    @Published private(set) var updatedAt: Date?

    private var config: () -> Config = { Config(dog: "", interval: 4 * 3600, length: 1800, from: 7, to: 22, weather: true, calendars: [], metric: true) }
    private var location: () async -> (lat: Double, lon: Double, name: String)? = { nil }
    private var busy: [Walks.Span] = []
    private var rain: [(Date, Double)] = []
    private var temperature: Double?
    private var weatherCode: Int?
    private var rainAt: Date?
    private var loop: Task<Void, Never>?
    private let wake = WakeSignal()
    private let url: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("UltraWorkspaceMac", isDirectory: true)
        url = base.appendingPathComponent("walks.json")
        if let d = try? Data(contentsOf: url) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
            if let l = try? dec.decode(Log.self, from: d) { log = l }
        }
    }

    func start(config: @escaping @MainActor () -> Config, location: @escaping @MainActor () async -> (lat: Double, lon: Double, name: String)?,
               wanted: @escaping @MainActor () -> Bool) {
        self.config = config; self.location = location
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let active = wanted()
                if active { await self.refresh() }
                await self.wake.wait(active ? 60 : 600) { wanted() != active }
            }
        }
    }
    func stop() { loop?.cancel(); loop = nil }
    func poke() { wake.signal() }

    private func refresh() async {
        let c = config(), now = Date()
        // A walk started and never ended (the tap on Back home forgotten) ends by itself after three hours, logged
        // with the usual length.
        if let w = log.walking, now.timeIntervalSince(w) > 3 * 3600 { finish(at: w.addingTimeInterval(c.length)) }
        let day = Walks.window(on: now, from: c.from, to: c.to)
        busy = await Task.detached(priority: .utility) { Self.busy(from: min(day.start, now), to: max(day.end, now.addingTimeInterval(3600)), calendarIDs: c.calendars) }.value
        if c.weather, rainAt.map({ now.timeIntervalSince($0) > 900 }) ?? true { await fetchRain(metric: c.metric) }
        if !c.weather { rain = []; temperature = nil; weatherCode = nil; rainAt = nil }
        updatedAt = now
    }

    /// When the user is busy between `from` and `to`: timed events that are not free time, not declined, not cancelled.
    nonisolated static func busy(from: Date, to: Date, calendarIDs: [String]) -> [Walks.Span] {
        guard CalendarSource.authStatus() == .authorized else { return [] }
        let store = EKEventStore()
        let chosen = calendarIDs.isEmpty ? nil : store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        if let chosen, chosen.isEmpty { return [] }
        return store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: chosen)).compactMap { ev in
            guard !ev.isAllDay, ev.availability != .free, ev.status != .canceled, let s = ev.startDate, let e = ev.endDate, e > s,
                  ev.attendees?.first(where: { $0.isCurrentUser })?.participantStatus != .declined,
                  e.timeIntervalSince(s) < 12 * 3600 else { return nil }
            return Walks.Span(s, e)
        }
    }

    private func fetchRain(metric: Bool) async {
        guard let loc = await location() else { lastError = "No location for the rain. Set one in Settings → Location & Units."; return }
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(format: "%.3f", loc.lat)), .init(name: "longitude", value: String(format: "%.3f", loc.lon)),
            .init(name: "minutely_15", value: "precipitation"), .init(name: "past_minutely_15", value: "2"), .init(name: "forecast_minutely_15", value: "40"),
            .init(name: "current", value: "temperature_2m,weather_code"), .init(name: "timeformat", value: "unixtime"),
            .init(name: "temperature_unit", value: metric ? "celsius" : "fahrenheit"),
        ]
        var req = URLRequest(url: c.url!, timeoutInterval: 15)
        req.setValue("Deckhand (+https://openbarx.com/)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { lastError = "Open-Meteo didn't answer."; return }
        let m = j["minutely_15"] as? [String: Any]
        let times = (m?["time"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
        let mm = (m?["precipitation"] as? [Any] ?? []).map { ($0 as? NSNumber)?.doubleValue ?? 0 }
        rain = zip(times, mm).map { (Date(timeIntervalSince1970: $0), $1) }
        let cur = j["current"] as? [String: Any]
        temperature = (cur?["temperature_2m"] as? NSNumber)?.doubleValue
        weatherCode = (cur?["weather_code"] as? NSNumber)?.intValue
        rainAt = Date(); lastError = nil
    }

    // MARK: logging walks

    var lastWalk: Walk? { log.walks.last }

    /// Going now: the walk starts.
    func startWalk() { guard log.walking == nil else { return }; log.walking = Date(); save() }

    /// Back home: the walk that started ends now (a walk shorter than two minutes was a mistake and is dropped).
    func endWalk() { finish(at: Date()) }

    /// Walked already: a walk of the usual length that ended just now.
    func walkedAlready() {
        let now = Date()
        log.walking = nil
        log.walks.append(Walk(start: now.addingTimeInterval(-config().length), end: now)); save()
    }

    /// Undo: a walk going on is called off; otherwise the last walk logged in the past hour is removed.
    @discardableResult func undo() -> Bool {
        if log.walking != nil { log.walking = nil; save(); return true }
        guard let l = log.walks.last, Date().timeIntervalSince(l.end) < 3600 else { return false }
        log.walks.removeLast(); save(); return true
    }

    func remove(_ walk: Walk) { log.walks.removeAll { $0 == walk }; save() }

    private func finish(at end: Date) {
        guard let s = log.walking else { return }
        log.walking = nil
        if end.timeIntervalSince(s) >= 120 { log.walks.append(Walk(start: s, end: end)) }
        save()
    }

    private func save() {
        let cut = Date().addingTimeInterval(-60 * 86400)
        log.walks = log.walks.filter { $0.end > cut }.sorted { $0.end < $1.end }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        if let d = try? enc.encode(log), !Store.writePrivate(d, to: url) { NSLog("Deckhand: walks.json could not be saved") }
        poke()
    }

    // MARK: what the bar gets

    /// Where the day stands: walking, due (and whether a meeting is in the way), or when the next one is.
    struct State {
        var due: Date?
        var overdue: Bool
        var meetingUntil: Date?
        var suggestion: (span: Walks.Span, dry: Bool)?
        var sky: Walks.Sky?
    }

    func state(now: Date = Date()) -> State {
        let c = config()
        let due = Walks.due(lastEnd: lastWalk?.end, interval: c.interval, now: now, from: c.from, to: c.to)
        let window = Walks.window(on: now, from: c.from, to: c.to)
        let meeting = Walks.covering(now, in: busy)
        let gaps = Walks.freeGaps(busy: busy, from: max(now, window.start), to: window.end, minLength: c.length)
        let suggestion = due.flatMap { d in Walks.suggestion(gaps: gaps, rain: rain, length: c.length, earliest: max(now, d.addingTimeInterval(-30 * 60))) }
        return State(due: due, overdue: due.map { $0 <= now } ?? false, meetingUntil: meeting?.end, suggestion: suggestion, sky: Walks.sky(rain, now: now))
    }

    func snapshot() -> [String: Any] {
        let c = config(), now = Date(), cal = Calendar.current, st = state(now: now)
        let window = Walks.window(on: now, from: c.from, to: c.to)
        func t(_ d: Date) -> Int { Int(d.timeIntervalSince1970) }
        var out: [String: Any] = ["at": t(now), "dog": Walks.dogName(c.dog), "interval": Int(c.interval), "length": Int(c.length),
                                  "authorized": CalendarSource.authStatus() == .authorized, "active": now >= window.start && now < window.end,
                                  "from": t(window.start), "to": t(window.end)]
        // Before the active hours start, the timeline shows today's window still ahead; after they end, tomorrow's start.
        if now >= window.end { out["resume"] = t(Walks.window(on: cal.date(byAdding: .day, value: 1, to: now) ?? now, from: c.from, to: c.to).start) }
        if let w = log.walking { out["walking"] = t(w) }
        if let l = lastWalk { out["last"] = [t(l.start), t(l.end)] }
        if let d = st.due { out["due"] = t(d) }
        if let m = st.meetingUntil { out["meetingUntil"] = t(m) }
        if let s = st.suggestion { out["suggest"] = ["start": t(s.span.start), "end": t(s.span.end), "dry": s.dry] }
        switch st.sky {
        case .dry(let u): out["sky"] = ["wet": false, "until": u.map(t) as Any]
        case .wet(let u): out["sky"] = ["wet": true, "until": u.map(t) as Any]
        case nil: break
        }
        if let x = temperature { out["temp"] = Int(x.rounded()) }
        if let w = weatherCode { out["code"] = w }
        out["rain"] = rain.filter { $0.0.addingTimeInterval(900) > window.start && $0.0 < window.end }.map { [t($0.0), ($0.1 * 10).rounded() / 10] }
        out["busy"] = busy.filter { $0.end > window.start && $0.start < window.end }.map { [t($0.start), t($0.end)] }
        let today = cal.startOfDay(for: now)
        out["walks"] = log.walks.filter { $0.end > window.start.addingTimeInterval(-6 * 3600) }.map { [t($0.start), t($0.end)] }
        let todays = log.walks.filter { $0.end >= today }
        out["today"] = ["count": todays.count, "minutes": Int(todays.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } / 60)]
        out["week"] = (0..<7).reversed().map { back -> [String: Any] in
            let d = cal.date(byAdding: .day, value: -back, to: today) ?? today, e = cal.date(byAdding: .day, value: 1, to: d) ?? d
            let ws = log.walks.filter { $0.end >= d && $0.end < e }
            return ["day": cal.component(.weekday, from: d), "count": ws.count, "minutes": Int(ws.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } / 60)]
        }
        out["undo"] = log.walking != nil || (lastWalk.map { now.timeIntervalSince($0.end) < 3600 } ?? false)
        return out
    }

    /// Deckhand Home's line: out walking, the walk that is due (with a badge), or when the next one is.
    func homeLine() -> (line: String, tone: String, badge: Int)? {
        let c = config(), now = Date(), dog = Walks.dogName(c.dog), st = state(now: now)
        if let w = log.walking { return ("Out with \(dog), \(Walks.duration(now.timeIntervalSince(w)))", "live", 0) }
        guard let due = st.due else { return nil }
        if st.overdue {
            if let m = st.meetingUntil { return ("Walk \(dog) after this meeting (\(m.formatted(date: .omitted, time: .shortened)))", "", 0) }
            return ("Time to walk \(dog)", "warn", 1)
        }
        return ("Next walk around \(due.formatted(date: .omitted, time: .shortened))", "", 0)
    }

    /// For Apps → Walk.
    var summary: String {
        let now = Date()
        if let w = log.walking { return "Out walking for \(Walks.duration(now.timeIntervalSince(w)))." }
        guard let l = lastWalk else { return "No walks logged yet." }
        return "Last walk ended \(l.end.formatted(.relative(presentation: .named))), \(Walks.duration(l.end.timeIntervalSince(l.start)))."
    }
}
