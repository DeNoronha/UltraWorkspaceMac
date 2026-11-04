import Foundation

/// Minimal Open-Meteo client (no API key). Geocoding + current weather.
public enum OpenMeteo {
    public struct Place: Sendable {
        public var name: String
        public var country: String
        public var latitude: Double
        public var longitude: Double
    }

    public enum Sky: String, Sendable {
        case clear, partlyCloudy, cloudy, fog, drizzle, rain, snow, showers, thunder, unknown
        public var label: String {
            switch self {
            case .clear: return "Clear"
            case .partlyCloudy: return "Partly cloudy"
            case .cloudy: return "Cloudy"
            case .fog: return "Fog"
            case .drizzle: return "Drizzle"
            case .rain: return "Rain"
            case .snow: return "Snow"
            case .showers: return "Showers"
            case .thunder: return "Thunderstorm"
            case .unknown: return "—"
            }
        }
    }

    public struct Now: Sendable {
        public var temperature: Double     // in requested units
        public var unitSuffix: String      // "°C" / "°F"
        public var code: Int               // WMO weather code
        public var sky: Sky
        public var isDay: Bool
        public var humidity: Int?
        public var windSpeed: Double?
        public var windSuffix: String
        public var place: String

        public init(temperature: Double, unitSuffix: String, code: Int, sky: Sky, isDay: Bool,
                    humidity: Int?, windSpeed: Double?, windSuffix: String, place: String) {
            self.temperature = temperature
            self.unitSuffix = unitSuffix
            self.code = code
            self.sky = sky
            self.isDay = isDay
            self.humidity = humidity
            self.windSpeed = windSpeed
            self.windSuffix = windSuffix
            self.place = place
        }
    }

    public static func geocode(_ query: String) async throws -> Place? {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [
            .init(name: "name", value: query),
            .init(name: "count", value: "1"),
            .init(name: "language", value: "en"),
            .init(name: "format", value: "json"),
        ]
        let (data, _) = try await URLSession.shared.data(for: timed(c.url!))
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]], let r = results.first,
              let lat = r["latitude"] as? Double, let lon = r["longitude"] as? Double else { return nil }
        return Place(name: (r["name"] as? String) ?? query,
                     country: (r["country"] as? String) ?? "",
                     latitude: lat, longitude: lon)
    }

    public static func current(latitude: Double, longitude: Double, metric: Bool, placeName: String) async throws -> Now {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(latitude)),
            .init(name: "longitude", value: String(longitude)),
            .init(name: "current", value: "temperature_2m,relative_humidity_2m,weather_code,is_day,wind_speed_10m"),
            .init(name: "temperature_unit", value: metric ? "celsius" : "fahrenheit"),
            .init(name: "wind_speed_unit", value: metric ? "kmh" : "mph"),
            .init(name: "timezone", value: "auto"),
        ]
        WireLog.shared.event("weather GET forecast lat=\(latitude) lon=\(longitude)")
        let (data, _) = try await URLSession.shared.data(for: timed(c.url!))
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cur = obj["current"] as? [String: Any] else {
            WireLog.shared.event("weather: bad response (\(data.count) B)")
            throw UltraBarError.protocolError("weather: bad response")
        }
        func dbl(_ k: String) -> Double? { (cur[k] as? Double) ?? (cur[k] as? NSNumber)?.doubleValue }
        func int(_ k: String) -> Int? { (cur[k] as? Int) ?? (cur[k] as? NSNumber)?.intValue }
        let code = int("weather_code") ?? 0
        return Now(
            temperature: dbl("temperature_2m") ?? 0,
            unitSuffix: metric ? "°C" : "°F",
            code: code,
            sky: sky(for: code),
            isDay: (int("is_day") ?? 1) == 1,
            humidity: int("relative_humidity_2m"),
            windSpeed: dbl("wind_speed_10m"),
            windSuffix: metric ? "km/h" : "mph",
            place: placeName
        )
    }

    /// One forecast day for the bar's Weather page (2026-11-04).
    public struct Day: Sendable {
        public var date: String        // "2026-11-04"
        public var code: Int
        public var sky: Sky
        public var tmax: Double
        public var tmin: Double
        public var precipProb: Int?    // %
    }

    /// Daily forecast, today first.
    public static func daily(latitude: Double, longitude: Double, metric: Bool, days: Int = 4) async throws -> [Day] {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(latitude)), .init(name: "longitude", value: String(longitude)),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            .init(name: "temperature_unit", value: metric ? "celsius" : "fahrenheit"),
            .init(name: "forecast_days", value: String(days)), .init(name: "timezone", value: "auto"),
        ]
        let (data, _) = try await URLSession.shared.data(for: timed(c.url!))
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let d = obj["daily"] as? [String: Any],
              let dates = d["time"] as? [String] else { throw UltraBarError.protocolError("weather: bad daily response") }
        func nums(_ k: String) -> [Double?] { (d[k] as? [Any] ?? []).map { ($0 as? NSNumber)?.doubleValue } }
        let codes = nums("weather_code"), tmax = nums("temperature_2m_max"), tmin = nums("temperature_2m_min"), pp = nums("precipitation_probability_max")
        return dates.indices.map { i in
            let code = Int(codes[safe: i] ?? 0)
            return Day(date: dates[i], code: code, sky: sky(for: code), tmax: tmax[safe: i] ?? 0, tmin: tmin[safe: i] ?? 0, precipProb: (pp[safe: i]).map { Int($0) })
        }
    }

    /// Approximate location from this machine's public IP (no permission, no key).
    /// Used as a fallback when CoreLocation is unavailable (e.g. an ad-hoc-signed
    /// app that was never granted Location access).
    public struct IPLoc: Sendable { public var lat: Double; public var lon: Double; public var city: String }
    public static func ipLocate() async -> IPLoc? {
        guard let url = URL(string: "https://ipwho.is/") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(for: timed(url)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["success"] as? Bool) != false else { return nil }
        func dbl(_ k: String) -> Double? { (obj[k] as? Double) ?? (obj[k] as? NSNumber)?.doubleValue }
        guard let lat = dbl("latitude"), let lon = dbl("longitude") else { return nil }
        let city = (obj["city"] as? String) ?? ""
        WireLog.shared.event("weather: IP geolocation → \(city.isEmpty ? "?" : city) (\(lat),\(lon))")
        return IPLoc(lat: lat, lon: lon, city: city)
    }

    /// Every call gets a 15 s timeout (URLSession's default is 60 s per idle gap, which on a flaky
    /// link kept a weather refresh hanging for a minute).
    static func timed(_ url: URL) -> URLRequest { var r = URLRequest(url: url); r.timeoutInterval = 15; return r }

    public static func sky(for code: Int) -> Sky {
        switch code {
        case 0: return .clear
        case 1, 2: return .partlyCloudy
        case 3: return .cloudy
        case 45, 48: return .fog
        case 51, 53, 55, 56, 57: return .drizzle
        case 61, 63, 65, 66, 67: return .rain
        case 71, 73, 75, 77: return .snow
        case 80, 81, 82: return .showers
        case 85, 86: return .snow
        case 95, 96, 99: return .thunder
        default: return .unknown
        }
    }
}

private extension Array where Element == Double? {
    subscript(safe i: Int) -> Double? { i < count ? self[i] : nil }
}
