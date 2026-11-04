import Foundation

/// Aircraft overhead, from the free ADS-B aggregator adsb.lol (no key), with the flight's airline and
/// route from adsbdb.com (no key, cached per callsign). Departure and arrival *times* are not available
/// without a paid API; the route is.
public enum Flights {
    public struct Airport: Sendable, Equatable { public var iata: String; public var name: String; public var city: String; public var country: String }
    public struct Aircraft: Sendable {
        public var hex: String
        public var callsign: String
        public var registration: String
        public var type: String
        public var altitudeM: Int?
        public var onGround: Bool
        public var speedKmh: Int?
        public var verticalMps: Double?
        public var track: Double?
        public var distanceKm: Double
        public var bearing: Double
        public var lat: Double, lon: Double
        public var airline: String?
        public var origin: Airport?
        public var destination: Airport?
    }

    /// Aircraft within `radiusKm` of a point, nearest first.
    public static func nearby(lat: Double, lon: Double, radiusKm: Double) async throws -> [Aircraft] {
        let nm = max(1, Int((radiusKm / 1.852).rounded(.up)))
        // Three decimals (about 100 m) is all a radius in kilometres needs; the exact position stays on the Mac.
        let url = URL(string: String(format: "https://api.adsb.lol/v2/point/%.3f/%.3f/%d", lat, lon, nm))!
        var req = URLRequest(url: url); req.timeoutInterval = 10
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any], let ac = obj["ac"] as? [[String: Any]] else { return [] }
        var out: [Aircraft] = []
        for a in ac {
            let dstNm = (a["dst"] as? Double) ?? Double.nan
            guard dstNm.isFinite else { continue }
            let km = dstNm * 1.852
            guard km <= radiusKm else { continue }
            let altRaw = a["alt_baro"]
            let onGround = (altRaw as? String) == "ground"
            let altFt = (altRaw as? Double) ?? (altRaw as? Int).map(Double.init)
            out.append(Aircraft(
                hex: (a["hex"] as? String) ?? "",
                callsign: ((a["flight"] as? String) ?? "").trimmingCharacters(in: .whitespaces),
                registration: (a["r"] as? String) ?? "",
                type: (a["t"] as? String) ?? "",
                altitudeM: altFt.map { Int(($0 * 0.3048).rounded()) },
                onGround: onGround,
                speedKmh: (a["gs"] as? Double).map { Int(($0 * 1.852).rounded()) },
                verticalMps: (a["baro_rate"] as? Double).map { $0 * 0.00508 },
                track: a["track"] as? Double,
                distanceKm: km,
                bearing: (a["dir"] as? Double) ?? 0,
                lat: (a["lat"] as? Double) ?? lat, lon: (a["lon"] as? Double) ?? lon,
                airline: nil, origin: nil, destination: nil))
        }
        return out.sorted { $0.distanceKm < $1.distanceKm }
    }

    public struct Route: Sendable { public var airline: String?; public var origin: Airport?; public var destination: Airport? }

    private actor RouteCache {
        var routes: [String: Route?] = [:]
        func get(_ k: String) -> Route?? { routes[k] }
        func put(_ k: String, _ r: Route?) { routes[k] = .some(r) }
    }
    private static let cache = RouteCache()

    /// Airline and route for a callsign (nil when adsbdb does not know it). Cached for the app's lifetime.
    public static func route(callsign: String) async -> Route? {
        let cs = callsign.uppercased().trimmingCharacters(in: .whitespaces)
        // The callsign comes from the ADS-B feed and goes into a URL path: letters and digits only.
        guard cs.count >= 3, cs.count <= 10, cs.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        if let hit = await cache.get(cs) { return hit }
        var result: Route? = nil
        if let url = URL(string: "https://api.adsbdb.com/v0/callsign/\(cs)") {
            var req = URLRequest(url: url); req.timeoutInterval = 10
            if let (data, _) = try? await URLSession.shared.data(for: req),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let resp = obj["response"] as? [String: Any], let fr = resp["flightroute"] as? [String: Any] {
                func airport(_ k: String) -> Airport? {
                    guard let a = fr[k] as? [String: Any], let iata = a["iata_code"] as? String else { return nil }
                    return Airport(iata: iata, name: (a["name"] as? String) ?? "", city: (a["municipality"] as? String) ?? "", country: (a["country_name"] as? String) ?? "")
                }
                result = Route(airline: (fr["airline"] as? [String: Any])?["name"] as? String, origin: airport("origin"), destination: airport("destination"))
            }
        }
        await cache.put(cs, result)
        return result
    }

    /// Compass point for a bearing in degrees ("NE").
    public static func compass(_ bearing: Double) -> String {
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        guard bearing.isFinite else { return "N" } // Int(nan) traps
        var b = (bearing + 22.5).truncatingRemainder(dividingBy: 360)
        if b < 0 { b += 360 }
        return names[Int(b / 45) % 8]
    }
}
