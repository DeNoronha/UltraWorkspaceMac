package nl.denoronha.deckhand.monitor.onbar

import java.util.Calendar
import kotlin.math.PI
import kotlin.math.asin
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.tan

/**
 * Sun and moon for one place, computed on the bar. A line-by-line port of the Mac app's `SkyMath.swift`
 * (Meeus; NOAA for the sun): positions, rise and set, twilight, golden hour, moon phase, next full and new
 * moon. Times are epoch milliseconds; "the day" is the bar's local day (its time zone is Europe/Amsterdam).
 */
internal object SkyMath {
    class Position(val elevation: Double, val azimuth: Double)
    class SunDay(val sunrise: Long?, val sunset: Long?, val solarNoon: Long, val civilDawn: Long?, val civilDusk: Long?,
                 val goldenEnd: Long?, val goldenStart: Long?, val dayLengthS: Double, val now: Position)
    class MoonInfo(val phase: Double, val illumination: Double, val ageDays: Double, val name: String, val waxing: Boolean,
                   val rise: Long?, val set: Long?, val nextFull: Long, val nextNew: Long, val now: Position, val distanceKm: Double)
    private class Equatorial(val ra: Double, val dec: Double, val distanceKm: Double, val eclipticLon: Double)

    private fun julianDay(ms: Long) = ms / 86_400_000.0 + 2440587.5
    private fun rad(d: Double) = d * PI / 180
    private fun deg(r: Double) = r * 180 / PI
    private fun norm(d: Double): Double { var x = d % 360; if (x < 0) x += 360; return x }
    private fun gmst(jd: Double) = norm(280.46061837 + 360.98564736629 * (jd - 2451545.0))

    private fun sun(jd: Double): Equatorial {
        val t = (jd - 2451545.0) / 36525
        val l0 = norm(280.46646 + 36000.76983 * t)
        val m = rad(norm(357.52911 + 35999.05029 * t))
        val c = (1.914602 - 0.004817 * t) * sin(m) + 0.019993 * sin(2 * m) + 0.000289 * sin(3 * m)
        val lon = norm(l0 + c)
        val eps = rad(23.439291 - 0.0130042 * t)
        val l = rad(lon)
        val ra = norm(deg(atan2(cos(eps) * sin(l), cos(l))))
        val dec = deg(asin(sin(eps) * sin(l)))
        return Equatorial(ra, dec, 149_598_000.0, lon)
    }

    private fun moon(jd: Double): Equatorial {
        val t = (jd - 2451545.0) / 36525
        val lp = norm(218.3164477 + 481267.88123421 * t)
        val d = rad(norm(297.8501921 + 445267.1114034 * t))
        val m = rad(norm(357.5291092 + 35999.0502909 * t))
        val mp = rad(norm(134.9633964 + 477198.8675055 * t))
        val f = rad(norm(93.2720950 + 483202.0175233 * t))
        var lon = lp
        lon += 6.288774 * sin(mp) + 1.274027 * sin(2 * d - mp) + 0.658314 * sin(2 * d) + 0.213618 * sin(2 * mp)
        lon += -0.185116 * sin(m) - 0.114332 * sin(2 * f) + 0.058793 * sin(2 * d - 2 * mp) + 0.057066 * sin(2 * d - m - mp)
        lon += 0.053322 * sin(2 * d + mp) + 0.045758 * sin(2 * d - m) - 0.040923 * sin(m - mp) - 0.034720 * sin(d)
        lon += -0.030383 * sin(m + mp) + 0.015327 * sin(2 * d - 2 * f) - 0.012528 * sin(mp + 2 * f) + 0.010980 * sin(mp - 2 * f)
        var lat = 5.128122 * sin(f) + 0.280602 * sin(mp + f) + 0.277693 * sin(mp - f) + 0.173237 * sin(2 * d - f)
        lat += 0.055413 * sin(2 * d - mp + f) + 0.046271 * sin(2 * d - mp - f) + 0.032573 * sin(2 * d + f) + 0.017198 * sin(2 * mp + f)
        val dist = 385000.56 - 20905.355 * cos(mp) - 3699.111 * cos(2 * d - mp) - 2955.968 * cos(2 * d) - 569.925 * cos(2 * mp)
        val eps = rad(23.439291 - 0.0130042 * t)
        val l = rad(norm(lon)); val b = rad(lat)
        val ra = norm(deg(atan2(sin(l) * cos(eps) - tan(b) * sin(eps), cos(l))))
        val dec = deg(asin(sin(b) * cos(eps) + cos(b) * sin(eps) * sin(l)))
        return Equatorial(ra, dec, dist, norm(lon))
    }

    private fun position(body: Equatorial, jd: Double, lat: Double, lon: Double): Position {
        val h = rad(norm(gmst(jd) + lon - body.ra))
        val phi = rad(lat); val dec = rad(body.dec)
        var alt = deg(asin(sin(phi) * sin(dec) + cos(phi) * cos(dec) * cos(h)))
        val az = norm(deg(atan2(sin(h), cos(h) * sin(phi) - tan(dec) * cos(phi))) + 180)
        if (body.distanceKm < 1_000_000) alt -= deg(asin(6378.14 / body.distanceKm)) * cos(rad(alt))
        return Position(alt, az)
    }

    private fun startOfDay(ms: Long): Long = Calendar.getInstance().apply {
        timeInMillis = ms; set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
    }.timeInMillis

    private fun startOfNextDay(start: Long): Long = Calendar.getInstance().apply { timeInMillis = start; add(Calendar.DAY_OF_MONTH, 1) }.timeInMillis

    /** Rising and setting crossings of [threshold] degrees within the local day, every 4 min, refined by bisection. */
    private fun crossings(body: (Double) -> Equatorial, day: Long, lat: Double, lon: Double, threshold: Double): Pair<Long?, Long?> {
        val start = startOfDay(day); val end = startOfNextDay(start)
        fun alt(t: Long): Double { val jd = julianDay(t); return position(body(jd), jd, lat, lon).elevation - threshold }
        var up: Long? = null; var down: Long? = null
        var t = start; var prev = alt(start)
        while (t < end) {
            val next = t + 240_000
            val a = alt(next)
            if ((prev < 0) != (a < 0)) {
                var lo = t; var hi = next
                repeat(12) { val mid = lo + (hi - lo) / 2; if ((alt(mid) < 0) == (prev < 0)) lo = mid else hi = mid }
                if (prev < 0) { if (up == null) up = hi } else { if (down == null) down = hi }
            }
            prev = a; t = next
        }
        return up to down
    }

    fun sunDay(now: Long, lat: Double, lon: Double): SunDay {
        val rs = crossings(::sun, now, lat, lon, -0.833)
        val civil = crossings(::sun, now, lat, lon, -6.0)
        val golden = crossings(::sun, now, lat, lon, 6.0)
        val start = startOfDay(now)
        var best = start; var bestAlt = -90.0
        for (m in 0 until 1440 step 2) {
            val t = start + m * 60_000L; val jd = julianDay(t)
            val a = position(sun(jd), jd, lat, lon).elevation
            if (a > bestAlt) { bestAlt = a; best = t }
        }
        val jd = julianDay(now)
        val pos = position(sun(jd), jd, lat, lon)
        val r = rs.first; val s = rs.second
        val length = if (r != null && s != null) (s - r) / 1000.0 else if (bestAlt > 0) 86400.0 else 0.0
        return SunDay(r, s, best, civil.first, civil.second, golden.first, golden.second, length, pos)
    }

    fun moonInfo(now: Long, lat: Double, lon: Double): MoonInfo {
        val jd = julianDay(now)
        val m = moon(jd); val s = sun(jd)
        val elong = norm(m.eclipticLon - s.eclipticLon)
        val phase = elong / 360
        val illumination = (1 - cos(rad(elong))) / 2
        val age = phase * 29.530588853
        val name = when {
            phase < 0.02 || phase >= 0.98 -> "New moon"
            phase < 0.23 -> "Waxing crescent"
            phase < 0.27 -> "First quarter"
            phase < 0.48 -> "Waxing gibbous"
            phase < 0.52 -> "Full moon"
            phase < 0.73 -> "Waning gibbous"
            phase < 0.77 -> "Last quarter"
            else -> "Waning crescent"
        }
        val rs = crossings(::moon, now, lat, lon, 0.125)
        fun nextElongation(target: Double): Long {
            fun e(t: Long): Double { val j = julianDay(t); return norm(moon(j).eclipticLon - sun(j).eclipticLon - target + 180) - 180 }
            var t = now; var prev = e(t)
            repeat(31 * 24) {
                val n = t + 3_600_000; val v = e(n)
                if (prev < 0 && v >= 0) {
                    var lo = t; var hi = n
                    repeat(16) { val mid = lo + (hi - lo) / 2; if (e(mid) < 0) lo = mid else hi = mid }
                    return hi
                }
                prev = v; t = n
            }
            return t
        }
        return MoonInfo(phase, illumination, age, name, phase < 0.5, rs.first, rs.second,
            nextElongation(180.0), nextElongation(0.0), position(m, jd, lat, lon), m.distanceKm)
    }
}
