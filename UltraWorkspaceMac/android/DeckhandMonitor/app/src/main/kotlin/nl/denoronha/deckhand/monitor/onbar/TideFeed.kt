package nl.denoronha.deckhand.monitor.onbar

import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Calendar
import java.util.TimeZone
import java.util.concurrent.ConcurrentHashMap

/**
 * Tide: Dutch water levels from Rijkswaterstaat's open water data (WaterWebservices, the "DD-API 2.0" at
 * ddapi20-waterwebservices.rijkswaterstaat.nl that replaced waterwebservices.rijkswaterstaat.nl in 2025; no key),
 * plus a small almanac for the configured location computed with [SkyMath] (nothing fetched for that).
 *
 * Per station (at most four, `apps.tide.stations` in the config, Hoek van Holland, Rotterdam and Nijmegen by default):
 *  - measured water level, WATHTE in cm NAP, ProcesType `meting` (10-minute values), from midnight (or three hours
 *    back, whichever is earlier) to now: once per refresh, so every 10 minutes while the app is open;
 *  - for tidal stations the astronomical tide (ProcesType `astronomisch`, 10-minute values) and its high and low
 *    waters (the same with Groepering `GETETBRKD2`), today and tomorrow: once per station per day.
 * A river gauge (no astronomical series, Nijmegen) shows its level and trend only.
 *
 * The page gets epoch seconds and whole centimetres; it draws the local day 00:00–24:00.
 */
internal object TideFeed {
    private const val BASE = "https://ddapi20-waterwebservices.rijkswaterstaat.nl/ONLINEWAARNEMINGENSERVICES/OphalenWaarnemingen"

    class Station(val code: String, val name: String, val tide: Boolean)

    /** The default set: the sea at Hoek van Holland, the city at Rotterdam (still tidal), the river at Nijmegen. */
    private val defaults = listOf(
        Station("hoekvanholland", "Hoek van Holland", true),
        Station("rotterdam.nieuwemaas.boerengat", "Rotterdam, Nieuwe Maas, Boerengat", true),
        Station("nijmegen.waal", "Nijmegen, Waal", false))

    /** The stations from `apps.tide.stations` ([{code, name, tide}]), clamped; the defaults without one. */
    fun stations(raw: String): List<Station> {
        val o = try { if (raw.isEmpty()) JSONObject() else JSONObject(raw) } catch (_: Exception) { JSONObject() }
        val arr = o.optJSONObject("apps")?.optJSONObject("tide")?.optJSONArray("stations") ?: return defaults
        val out = (0 until arr.length()).mapNotNull { i ->
            val s = arr.optJSONObject(i) ?: return@mapNotNull null
            val code = s.optString("code", "").trim()
            if (!code.matches(Regex("^[a-z0-9._-]{2,80}$"))) return@mapNotNull null
            Station(code, s.optString("name", code).take(80).ifBlank { code }, s.optBoolean("tide", true))
        }.distinctBy { it.code }.take(4)
        return out.ifEmpty { defaults }
    }

    private class Point(val t: Long, val v: Int)
    private class Astro(val curve: List<Point>, val extremes: List<Point>, val at: Long)

    /** Astronomical tide per station and day ("code|yyyy-mm-dd"); it changes only with the day. */
    private val astro = ConcurrentHashMap<String, Astro>()
    /** The last good measured series per station, kept when a refresh fails so the page does not go blank. */
    private val lastMeasured = ConcurrentHashMap<String, List<Point>>()

    private val iso: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSSXXX")
    private fun stamp(ms: Long) = iso.format(Instant.ofEpochMilli(ms).atZone(ZoneId.systemDefault()))

    /**
     * POST one OphalenWaarnemingen request; the points of every series in the answer. Empty for HTTP 204 (the
     * station has no such data), null when the request failed.
     */
    private fun fetch(code: String, proces: String, groepering: String?, fromMs: Long, toMs: Long): List<Point>? {
        val meta = JSONObject().put("Compartiment", JSONObject().put("Code", "OW")).put("Grootheid", JSONObject().put("Code", "WATHTE"))
            .put("Hoedanigheid", JSONObject().put("Code", "NAP")).put("ProcesType", proces)
        if (groepering != null) meta.put("Groepering", JSONObject().put("Code", groepering))
        val body = JSONObject().put("Locatie", JSONObject().put("Code", code))
            .put("AquoPlusWaarnemingMetadata", JSONObject().put("AquoMetadata", meta))
            .put("Periode", JSONObject().put("Begindatumtijd", stamp(fromMs)).put("Einddatumtijd", stamp(toMs)))
        val text = try {
            val c = URL(BASE).openConnection() as HttpURLConnection
            c.connectTimeout = 12_000; c.readTimeout = 20_000; c.requestMethod = "POST"; c.doOutput = true
            c.setRequestProperty("User-Agent", USER_AGENT); c.setRequestProperty("Content-Type", "application/json"); c.setRequestProperty("Accept", "application/json")
            try {
                c.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
                when (c.responseCode) {
                    204 -> return emptyList()
                    in 200..299 -> c.inputStream.use { i -> ByteArrayOutputStream().also { i.copyTo(it) }.toString("UTF-8") }
                    else -> { Log.w(TAG, "Tide $code $proces → HTTP ${c.responseCode}"); return null }
                }
            } finally { c.disconnect() }
        } catch (e: Exception) { Log.w(TAG, "Tide $code $proces failed: ${e.message}"); return null }
        val o = try { JSONObject(text) } catch (_: Exception) { return null }
        if (!o.optBoolean("Succesvol", false)) return if (o.has("WaarnemingenLijst")) null else emptyList()
        val out = ArrayList<Point>()
        val series = o.optJSONArray("WaarnemingenLijst") ?: JSONArray()
        for (i in 0 until series.length()) {
            val list = series.optJSONObject(i)?.optJSONArray("MetingenLijst") ?: continue
            for (j in 0 until list.length()) {
                val m = list.optJSONObject(j) ?: continue
                val v = m.optJSONObject("Meetwaarde")?.dbl("Waarde_Numeriek") ?: continue
                // 999999999 marks a missing value; quality code 99 an unreliable one.
                if (kotlin.math.abs(v) > 5000 || m.optJSONObject("WaarnemingMetadata")?.optString("Kwaliteitswaardecode") == "99") continue
                val t = try { OffsetDateTime.parse(m.optString("Tijdstip")).toInstant().toEpochMilli() } catch (_: Exception) { continue }
                out.add(Point(t / 1000, Math.round(v).toInt()))
            }
        }
        return out.sortedBy { it.t }.distinctBy { it.t }
    }

    private fun startOfDay(ms: Long): Long = Calendar.getInstance().apply {
        timeInMillis = ms; set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
    }.timeInMillis
    private fun addDays(ms: Long, n: Int): Long = Calendar.getInstance().apply { timeInMillis = ms; add(Calendar.DAY_OF_MONTH, n) }.timeInMillis

    /** Today's and tomorrow's astronomical tide, fetched once per day; null when Rijkswaterstaat did not answer. */
    private fun astroFor(code: String, day0: Long): Astro? {
        val key = code + "|" + day0
        astro[key]?.let { return it }
        val end = addDays(day0, 2)
        val curve = fetch(code, "astronomisch", null, day0, end) ?: return null
        val ext = if (curve.isEmpty()) emptyList() else fetch(code, "astronomisch", "GETETBRKD2", day0, end) ?: return null
        astro.keys.removeAll { it.startsWith("$code|") }
        return Astro(curve, ext, System.currentTimeMillis()).also { astro[key] = it }
    }

    /** cm per hour over the last hour of [pts] (least squares), or null with too few points. */
    private fun trend(pts: List<Point>): Double? {
        val last = pts.lastOrNull() ?: return null
        val w = pts.filter { it.t >= last.t - 3600 }
        if (w.size < 3) return null
        val mt = w.map { it.t.toDouble() }.average(); val mv = w.map { it.v.toDouble() }.average()
        var num = 0.0; var den = 0.0
        for (p in w) { num += (p.t - mt) * (p.v - mv); den += (p.t - mt) * (p.t - mt) }
        return if (den == 0.0) null else num / den * 3600
    }

    private fun arr(pts: List<Point>): JSONArray = JSONArray().also { a -> pts.forEach { a.put(JSONArray().put(it.t).put(it.v)) } }

    fun tide(cfg: BarConfig): JSONObject? {
        val now = System.currentTimeMillis()
        val day0 = startOfDay(now); val day1 = addDays(day0, 1)
        val out = JSONArray()
        var anyAnswer = false
        for (s in stations(cfg.raw)) {
            val from = minOf(day0, now - 3 * 3_600_000L)
            val fresh = fetch(s.code, "meting", null, from, now)
            if (fresh != null) { anyAnswer = true; lastMeasured[s.code] = fresh }
            val meas = (fresh ?: lastMeasured[s.code] ?: emptyList())
            val a = if (s.tide) astroFor(s.code, day0) else null
            val tidal = a != null && a.curve.isNotEmpty()
            val o = JSONObject().put("code", s.code).put("name", s.name).put("tide", tidal || (s.tide && a == null))
            val last = meas.lastOrNull()
            o.put("now", nullable(last?.let { JSONObject().put("t", it.t).put("v", it.v) }))
            o.put("trend", nullable(trend(meas)?.let { round1(it) }))
            o.put("meas", arr(meas.filter { it.t * 1000 >= day0 }))
            if (fresh == null) o.put("error", "Rijkswaterstaat did not answer")
            // The low and high of the day so far, so a river gauge has something besides its trend.
            meas.filter { it.t * 1000 >= day0 }.takeIf { it.isNotEmpty() }?.let { d -> o.put("min", d.minOf { it.v }).put("max", d.maxOf { it.v }) }
            if (tidal && a != null) {
                o.put("astro", arr(a.curve.filter { it.t * 1000 in day0..day1 }))
                // High or low: higher or lower than its neighbours in the alternating list of extremes.
                val ex = a.extremes
                val marked = JSONArray()
                ex.forEachIndexed { i, p ->
                    val n = listOfNotNull(ex.getOrNull(i - 1), ex.getOrNull(i + 1))
                    val high = n.isEmpty() || n.all { p.v > it.v }
                    marked.put(JSONObject().put("t", p.t).put("v", p.v).put("hw", high))
                }
                o.put("extremes", marked)
                // Measured minus predicted at the last reading: wind set-up (positive) or set-down.
                if (last != null) a.curve.minByOrNull { kotlin.math.abs(it.t - last.t) }?.takeIf { kotlin.math.abs(it.t - last.t) <= 600 }
                    ?.let { o.put("surge", last.v - it.v) }
            }
            out.put(o)
        }
        if (!anyAnswer && lastMeasured.isEmpty()) return null   // nothing yet: the page keeps "Loading…" and asks again
        val lat = cfg.lat; val lon = cfg.lon
        val alm = JSONObject().put("place", cfg.place)
        if (lat != null && lon != null) {
            val s = SkyMath.sunDay(now, lat, lon); val y = SkyMath.sunDay(addDays(now, -1), lat, lon)
            val m = SkyMath.moonInfo(now, lat, lon)
            fun t(ms: Long?): Any = ms?.let { it / 1000 } ?: JSONObject.NULL
            alm.put("rise", t(s.sunrise)).put("set", t(s.sunset)).put("dayLength", s.dayLengthS.toInt()).put("dayChange", (s.dayLengthS - y.dayLengthS).toInt())
                .put("moon", JSONObject().put("name", m.name).put("illumination", m.illumination).put("waxing", m.waxing).put("phase", m.phase)
                    .put("nextFull", t(m.nextFull)).put("nextNew", t(m.nextNew)))
        }
        return JSONObject().put("stations", out).put("almanac", alm).put("day", JSONObject().put("start", day0 / 1000).put("end", day1 / 1000))
            .put("now", now / 1000).put("tz", TimeZone.getDefault().getOffset(now) / 1000).put("at", now / 1000)
    }
}
