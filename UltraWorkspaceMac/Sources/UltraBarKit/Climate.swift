import Foundation

/// The pure parts of the Climate bar app: tado's zone state and overlay (the heating, one zone for the whole house) and
/// Netatmo's weather station (`getstationsdata`, `getmeasure`), parsed into what the bar shows.
public enum Climate {

    // MARK: tado

    public struct Heating: Equatable, Sendable {
        /// The heating is asked to run (power ON), with this target.
        public var on: Bool
        public var target: Double?
        /// tado's own room reading.
        public var inside: Double?
        public var humidity: Double?
        /// How hard the boiler is asked to heat, 0–100.
        public var power: Int?
        /// A manual setting (Deckhand's or the tado app's) instead of the schedule.
        public var manual: Bool
        /// When the manual setting ends by itself (a timer), nil for "until the next schedule change" or for ever.
        public var manualEnds: Date?
        /// The manual setting ends at the next schedule change.
        public var untilSchedule: Bool
        /// The next schedule change: when, and on/off with its target.
        public var nextAt: Date?
        public var nextOn: Bool?
        public var nextTarget: Double?
        public var online: Bool
        public var openWindow: Bool
        /// Away mode (geofencing or the app): the schedule is replaced by the away temperature.
        public var away: Bool
        public init(on: Bool, target: Double?, inside: Double?, humidity: Double?, power: Int?, manual: Bool, manualEnds: Date?,
                    untilSchedule: Bool, nextAt: Date?, nextOn: Bool?, nextTarget: Double?, online: Bool, openWindow: Bool, away: Bool) {
            self.on = on; self.target = target; self.inside = inside; self.humidity = humidity; self.power = power; self.manual = manual
            self.manualEnds = manualEnds; self.untilSchedule = untilSchedule; self.nextAt = nextAt; self.nextOn = nextOn
            self.nextTarget = nextTarget; self.online = online; self.openWindow = openWindow; self.away = away
        }
    }

    /// `GET /api/v2/homes/{home}/zones/{zone}/state` → the heating.
    public static func heating(_ j: [String: Any], now: Date = Date()) -> Heating? {
        guard let setting = j["setting"] as? [String: Any] else { return nil }
        let on = (setting["power"] as? String) == "ON"
        let target = ((setting["temperature"] as? [String: Any])?["celsius"] as? NSNumber)?.doubleValue
        let sensors = (j["sensorDataPoints"] as? [String: Any]) ?? [:]
        let inside = ((sensors["insideTemperature"] as? [String: Any])?["celsius"] as? NSNumber)?.doubleValue
        let humidity = ((sensors["humidity"] as? [String: Any])?["percentage"] as? NSNumber)?.doubleValue
        let power = (((j["activityDataPoints"] as? [String: Any])?["heatingPower"] as? [String: Any])?["percentage"] as? NSNumber)?.doubleValue
        let overlay = j["overlay"] as? [String: Any]
        let manual = overlay != nil || (j["overlayType"] as? String) == "MANUAL"
        let term = (overlay?["termination"] as? [String: Any]) ?? [:]
        let termType = (term["typeSkillBasedApp"] as? String) ?? (term["type"] as? String) ?? ""
        var ends = (term["projectedExpiry"] as? String).flatMap(date) ?? (term["expiry"] as? String).flatMap(date)
        if ends == nil, let r = (term["remainingTimeInSeconds"] as? NSNumber)?.doubleValue { ends = now.addingTimeInterval(r) }
        let untilSchedule = termType == "NEXT_TIME_BLOCK" || termType == "TADO_MODE"
        if termType == "MANUAL" { ends = nil }
        let next = j["nextScheduleChange"] as? [String: Any]
        let nextSetting = next?["setting"] as? [String: Any]
        let link = ((j["link"] as? [String: Any])?["state"] as? String) ?? "ONLINE"
        return Heating(on: on, target: on ? target : nil, inside: inside, humidity: humidity, power: power.map { Int($0.rounded()) },
                       manual: manual, manualEnds: ends, untilSchedule: untilSchedule,
                       nextAt: (next?["start"] as? String).flatMap(date),
                       nextOn: nextSetting.map { ($0["power"] as? String) == "ON" },
                       nextTarget: ((nextSetting?["temperature"] as? [String: Any])?["celsius"] as? NSNumber)?.doubleValue,
                       online: link == "ONLINE", openWindow: j["openWindow"] != nil && !(j["openWindow"] is NSNull),
                       away: (j["tadoMode"] as? String) == "AWAY")
    }

    /// What the bar may ask for: a temperature from 15 to 25 °C in half degrees, for 30, 60, 120 or 240 minutes or until
    /// the next schedule change ("next"). Anything else is refused.
    public static func heatRequest(celsius: String, duration: String) -> (celsius: Double, minutes: Int?)? {
        guard let c = Double(celsius), c >= 15, c <= 25, (c * 2).rounded() == c * 2 else { return nil }
        if duration == "next" { return (c, nil) }
        guard let m = Int(duration), [30, 60, 120, 240].contains(m) else { return nil }
        return (c, m)
    }

    /// The body of `PUT …/zones/{zone}/overlay`: heating on at `celsius`, for `minutes` or until the next schedule change.
    public static func overlayBody(celsius: Double, minutes: Int?) -> [String: Any] {
        let termination: [String: Any] = minutes.map { ["typeSkillBasedApp": "TIMER", "durationInSeconds": $0 * 60] }
            ?? ["typeSkillBasedApp": "NEXT_TIME_BLOCK"]
        return ["setting": ["type": "HEATING", "power": "ON", "temperature": ["celsius": celsius]], "termination": termination]
    }

    /// tado's `RateLimit` header (`"perday";r=87;t=3600`): the calls left today and the seconds until the quota resets.
    public static func rateLimit(_ header: String?) -> (remaining: Int, resetIn: Int?)? {
        guard let h = header else { return nil }
        var r: Int?, t: Int?
        for part in h.split(whereSeparator: { $0 == ";" || $0 == "," }) {
            let kv = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            if kv[0] == "r" { r = Int(kv[1]) } else if kv[0] == "t" { t = Int(kv[1]) }
        }
        return r.map { ($0, t) }
    }

    /// The first heating zone in `GET /api/v2/homes/{home}/zones` (the house has one: the whole house is one zone).
    public static func heatingZone(_ zones: [[String: Any]]) -> (id: Int, name: String)? {
        for z in zones where (z["type"] as? String) == "HEATING" {
            if let id = (z["id"] as? NSNumber)?.intValue { return (id, (z["name"] as? String) ?? "Heating") }
        }
        return nil
    }

    // MARK: Netatmo

    public enum Kind: String, Sendable { case indoor, outdoor, extra, rain, wind }

    public struct Module: Equatable, Sendable {
        public var id: String
        /// The station (NAMain) the module belongs to, for getmeasure.
        public var station: String
        public var name: String
        public var kind: Kind
        public var temperature: Double?
        public var humidity: Double?
        public var co2: Int?
        public var pressure: Double?
        public var noise: Int?
        public var min: Double?
        public var max: Double?
        public var trend: String?
        public var rain1h: Double?
        public var rain24h: Double?
        public var wind: Int?
        public var gust: Int?
        public var battery: Int?
        public var reachable: Bool
        public var time: Date?
        public init(id: String, station: String, name: String, kind: Kind, temperature: Double? = nil, humidity: Double? = nil, co2: Int? = nil,
                    pressure: Double? = nil, noise: Int? = nil, min: Double? = nil, max: Double? = nil, trend: String? = nil, rain1h: Double? = nil,
                    rain24h: Double? = nil, wind: Int? = nil, gust: Int? = nil, battery: Int? = nil, reachable: Bool = true, time: Date? = nil) {
            self.id = id; self.station = station; self.name = name; self.kind = kind; self.temperature = temperature; self.humidity = humidity
            self.co2 = co2; self.pressure = pressure; self.noise = noise; self.min = min; self.max = max; self.trend = trend
            self.rain1h = rain1h; self.rain24h = rain24h; self.wind = wind; self.gust = gust; self.battery = battery
            self.reachable = reachable; self.time = time
        }
    }

    /// `GET /api/getstationsdata` → every station's main module and its modules, the main (indoor) first.
    public static func modules(_ j: [String: Any]) -> [Module] {
        let devices = ((j["body"] as? [String: Any])?["devices"] as? [[String: Any]]) ?? []
        var out: [Module] = []
        for d in devices {
            guard let sid = d["_id"] as? String else { continue }
            out.append(module(d, station: sid, kind: .indoor, fallback: "Indoor"))
            for m in (d["modules"] as? [[String: Any]]) ?? [] {
                let kind: Kind
                switch m["type"] as? String {
                case "NAModule1": kind = .outdoor
                case "NAModule4": kind = .extra
                case "NAModule3": kind = .rain
                case "NAModule2": kind = .wind
                default: continue
                }
                out.append(module(m, station: sid, kind: kind, fallback: kind == .outdoor ? "Outdoor" : kind == .rain ? "Rain" : kind == .wind ? "Wind" : "Room"))
            }
        }
        return out
    }

    /// A module's name as a room: "Netatmo Kantoor" → "Kantoor" (the brand adds nothing on the tile); a name that is
    /// only the brand stays as it is.
    public static func roomName(_ raw: String) -> String {
        let n = raw.trimmingCharacters(in: .whitespaces)
        guard n.lowercased().hasPrefix("netatmo ") else { return n }
        let rest = n.dropFirst("netatmo ".count).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? n : rest
    }

    private static func module(_ m: [String: Any], station: String, kind: Kind, fallback: String) -> Module {
        let d = (m["dashboard_data"] as? [String: Any]) ?? [:]
        func num(_ k: String) -> Double? { (d[k] as? NSNumber)?.doubleValue }
        let name = roomName((m["module_name"] as? String) ?? "")
        return Module(id: (m["_id"] as? String) ?? station, station: station, name: name.isEmpty ? fallback : name, kind: kind,
                      temperature: num("Temperature"), humidity: num("Humidity"), co2: num("CO2").map { Int($0) },
                      pressure: num("Pressure"), noise: num("Noise").map { Int($0) }, min: num("min_temp"), max: num("max_temp"),
                      trend: (d["temp_trend"] as? String) ?? (d["pressure_trend"] as? String),
                      rain1h: num("sum_rain_1"), rain24h: num("sum_rain_24"), wind: num("WindStrength").map { Int($0) },
                      gust: num("GustStrength").map { Int($0) }, battery: (m["battery_percent"] as? NSNumber)?.intValue,
                      reachable: (m["reachable"] as? Bool) ?? true, time: num("time_utc").map { Date(timeIntervalSince1970: $0) })
    }

    /// `GET /api/getmeasure?…&optimize=false` (`body` is `{"<unix time>": [value]}`) → the values in time order.
    public static func measure(_ j: [String: Any]) -> [(Date, Double)] {
        guard let body = j["body"] as? [String: Any] else { return [] }
        return body.compactMap { k, v -> (Date, Double)? in
            guard let t = Double(k), let x = ((v as? [Any])?.first as? NSNumber)?.doubleValue else { return nil }
            return (Date(timeIntervalSince1970: t), x)
        }.sorted { $0.0 < $1.0 }
    }

    /// CO₂ as the bar colours it: up to 1000 ppm fine, up to 1400 stuffy, above that open a window.
    public static func co2Level(_ ppm: Int) -> String { ppm <= 1000 ? "good" : ppm <= 1400 ? "stuffy" : "bad" }

    // MARK: helpers

    public static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}
