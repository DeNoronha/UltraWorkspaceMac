import Foundation

/// Sun and moon for one place, computed locally (no service): positions, rise and set times, twilight,
/// golden hour, moon phase and the next full and new moon. Low-precision algorithms (Meeus; NOAA for the
/// sun), good to about a minute for rise/set and a degree for positions — plenty for a card on the bar.
public enum SkyMath {
    public struct Position: Sendable { public var elevation: Double; public var azimuth: Double }

    public struct SunDay: Sendable {
        public var sunrise: Date?, sunset: Date?, solarNoon: Date
        public var civilDawn: Date?, civilDusk: Date?
        /// Morning golden hour ends / evening golden hour starts when the sun crosses 6° above the horizon.
        public var goldenEnd: Date?, goldenStart: Date?
        public var dayLength: TimeInterval
        public var now: Position
    }

    public struct MoonInfo: Sendable {
        /// 0 = new, 0.5 = full, 1 = new again.
        public var phase: Double
        public var illumination: Double
        public var ageDays: Double
        public var name: String
        public var waxing: Bool
        public var rise: Date?, set: Date?
        public var nextFull: Date, nextNew: Date
        public var now: Position
        public var distanceKm: Double
    }

    // MARK: - Time helpers

    static func julianDay(_ d: Date) -> Double { d.timeIntervalSince1970 / 86400 + 2440587.5 }
    static func rad(_ d: Double) -> Double { d * .pi / 180 }
    static func deg(_ r: Double) -> Double { r * 180 / .pi }
    static func norm(_ d: Double) -> Double { var x = d.truncatingRemainder(dividingBy: 360); if x < 0 { x += 360 }; return x }

    /// Greenwich mean sidereal time in degrees.
    static func gmst(_ jd: Double) -> Double { norm(280.46061837 + 360.98564736629 * (jd - 2451545.0)) }

    struct Equatorial { var ra: Double; var dec: Double; var distanceKm: Double; var eclipticLon: Double }

    /// Apparent geocentric sun (Meeus ch. 25, low precision).
    static func sun(_ jd: Double) -> Equatorial {
        let T = (jd - 2451545.0) / 36525
        let L0 = norm(280.46646 + 36000.76983 * T)
        let M = rad(norm(357.52911 + 35999.05029 * T))
        let C = (1.914602 - 0.004817 * T) * sin(M) + 0.019993 * sin(2 * M) + 0.000289 * sin(3 * M)
        let lon = norm(L0 + C)
        let eps = rad(23.439291 - 0.0130042 * T)
        let l = rad(lon)
        let ra = norm(deg(atan2(cos(eps) * sin(l), cos(l))))
        let dec = deg(asin(sin(eps) * sin(l)))
        return Equatorial(ra: ra, dec: dec, distanceKm: 149_598_000, eclipticLon: lon)
    }

    /// Geocentric moon (Meeus ch. 47, truncated: the largest terms; ~0.3° accuracy).
    static func moon(_ jd: Double) -> Equatorial {
        let T = (jd - 2451545.0) / 36525
        let Lp = norm(218.3164477 + 481267.88123421 * T)
        let D = rad(norm(297.8501921 + 445267.1114034 * T))
        let M = rad(norm(357.5291092 + 35999.0502909 * T))
        let Mp = rad(norm(134.9633964 + 477198.8675055 * T))
        let F = rad(norm(93.2720950 + 483202.0175233 * T))
        var lon = Lp
        lon += 6.288774 * sin(Mp) + 1.274027 * sin(2 * D - Mp) + 0.658314 * sin(2 * D) + 0.213618 * sin(2 * Mp)
        lon += -0.185116 * sin(M) - 0.114332 * sin(2 * F) + 0.058793 * sin(2 * D - 2 * Mp) + 0.057066 * sin(2 * D - M - Mp)
        lon += 0.053322 * sin(2 * D + Mp) + 0.045758 * sin(2 * D - M) - 0.040923 * sin(M - Mp) - 0.034720 * sin(D)
        lon += -0.030383 * sin(M + Mp) + 0.015327 * sin(2 * D - 2 * F) - 0.012528 * sin(Mp + 2 * F) + 0.010980 * sin(Mp - 2 * F)
        var lat = 5.128122 * sin(F) + 0.280602 * sin(Mp + F) + 0.277693 * sin(Mp - F) + 0.173237 * sin(2 * D - F)
        lat += 0.055413 * sin(2 * D - Mp + F) + 0.046271 * sin(2 * D - Mp - F) + 0.032573 * sin(2 * D + F) + 0.017198 * sin(2 * Mp + F)
        let dist = 385000.56 - 20905.355 * cos(Mp) - 3699.111 * cos(2 * D - Mp) - 2955.968 * cos(2 * D) - 569.925 * cos(2 * Mp)
        let eps = rad(23.439291 - 0.0130042 * T)
        let l = rad(norm(lon)), b = rad(lat)
        let ra = norm(deg(atan2(sin(l) * cos(eps) - tan(b) * sin(eps), cos(l))))
        let dec = deg(asin(sin(b) * cos(eps) + cos(b) * sin(eps) * sin(l)))
        return Equatorial(ra: ra, dec: dec, distanceKm: dist, eclipticLon: norm(lon))
    }

    /// Topocentric-ish altitude/azimuth (parallax applied to the altitude only, which is what rise/set needs).
    static func position(_ body: Equatorial, jd: Double, lat: Double, lon: Double) -> Position {
        let H = rad(norm(gmst(jd) + lon - body.ra))
        let phi = rad(lat), dec = rad(body.dec)
        var alt = deg(asin(sin(phi) * sin(dec) + cos(phi) * cos(dec) * cos(H)))
        let az = norm(deg(atan2(sin(H), cos(H) * sin(phi) - tan(dec) * cos(phi))) + 180)
        if body.distanceKm < 1_000_000 { alt -= deg(asin(6378.14 / body.distanceKm)) * cos(rad(alt)) } // moon parallax
        return Position(elevation: alt, azimuth: az)
    }

    /// Times within the local day `day` at which the body's altitude crosses `threshold` (degrees),
    /// scanning every 4 minutes and refining by bisection. Returns (rising, setting) crossings.
    static func crossings(_ body: @escaping (Double) -> Equatorial, day: Date, lat: Double, lon: Double, threshold: Double, calendar: Calendar) -> (up: Date?, down: Date?) {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        func alt(_ t: Date) -> Double { let jd = julianDay(t); return position(body(jd), jd: jd, lat: lat, lon: lon).elevation - threshold }
        var up: Date?, down: Date?
        var t = start, prev = alt(start)
        while t < end {
            let next = t.addingTimeInterval(240)
            let a = alt(next)
            if (prev < 0) != (a < 0) {
                var lo = t, hi = next
                for _ in 0..<12 { let mid = lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2); if (alt(mid) < 0) == (prev < 0) { lo = mid } else { hi = mid } }
                if prev < 0 { if up == nil { up = hi } } else { if down == nil { down = hi } }
            }
            prev = a; t = next
        }
        return (up, down)
    }

    // MARK: - Public

    public static func sunDay(at date: Date, lat: Double, lon: Double, calendar: Calendar = .current) -> SunDay {
        let rs = crossings(sun, day: date, lat: lat, lon: lon, threshold: -0.833, calendar: calendar)
        let civil = crossings(sun, day: date, lat: lat, lon: lon, threshold: -6, calendar: calendar)
        let golden = crossings(sun, day: date, lat: lat, lon: lon, threshold: 6, calendar: calendar)
        // Solar noon: when the sun's hour angle is 0 (local sidereal time == RA), found by scanning the day.
        let start = calendar.startOfDay(for: date)
        var best = start, bestAlt = -90.0
        for m in stride(from: 0, to: 1440, by: 2) {
            let t = start.addingTimeInterval(Double(m) * 60); let jd = julianDay(t)
            let a = position(sun(jd), jd: jd, lat: lat, lon: lon).elevation
            if a > bestAlt { bestAlt = a; best = t }
        }
        let jd = julianDay(date)
        let now = position(sun(jd), jd: jd, lat: lat, lon: lon)
        let length: TimeInterval
        if let r = rs.up, let s = rs.down { length = s.timeIntervalSince(r) } else { length = bestAlt > 0 ? 86400 : 0 }
        return SunDay(sunrise: rs.up, sunset: rs.down, solarNoon: best, civilDawn: civil.up, civilDusk: civil.down,
                      goldenEnd: golden.up, goldenStart: golden.down, dayLength: length, now: now)
    }

    public static func moonInfo(at date: Date, lat: Double, lon: Double, calendar: Calendar = .current) -> MoonInfo {
        let jd = julianDay(date)
        let m = moon(jd), s = sun(jd)
        let elong = norm(m.eclipticLon - s.eclipticLon)         // 0 new … 180 full … 360 new
        let phase = elong / 360
        let illumination = (1 - cos(rad(elong))) / 2
        let age = phase * 29.530588853
        let waxing = phase < 0.5
        let name: String
        switch phase {
        case ..<0.02, 0.98...: name = "New moon"
        case ..<0.23: name = "Waxing crescent"
        case ..<0.27: name = "First quarter"
        case ..<0.48: name = "Waxing gibbous"
        case ..<0.52: name = "Full moon"
        case ..<0.73: name = "Waning gibbous"
        case ..<0.77: name = "Last quarter"
        default: name = "Waning crescent"
        }
        let rs = crossings(moon, day: date, lat: lat, lon: lon, threshold: 0.125, calendar: calendar)
        func nextElongation(_ target: Double) -> Date {
            // Scan forward hourly for the elongation to pass `target`, then refine.
            func e(_ t: Date) -> Double { let j = julianDay(t); return norm(moon(j).eclipticLon - sun(j).eclipticLon - target + 180) - 180 } // signed distance to target
            var t = date, prev = e(t)
            for _ in 0..<(31 * 24) {
                let n = t.addingTimeInterval(3600); let v = e(n)
                if prev < 0 && v >= 0 {
                    var lo = t, hi = n
                    for _ in 0..<16 { let mid = lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2); if e(mid) < 0 { lo = mid } else { hi = mid } }
                    return hi
                }
                prev = v; t = n
            }
            return t
        }
        return MoonInfo(phase: phase, illumination: illumination, ageDays: age, name: name, waxing: waxing,
                        rise: rs.up, set: rs.down, nextFull: nextElongation(180), nextNew: nextElongation(0),
                        now: position(m, jd: jd, lat: lat, lon: lon), distanceKm: m.distanceKm)
    }
}
