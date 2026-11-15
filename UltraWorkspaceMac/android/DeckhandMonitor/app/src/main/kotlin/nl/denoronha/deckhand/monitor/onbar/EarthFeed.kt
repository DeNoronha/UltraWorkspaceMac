package nl.denoronha.deckhand.monitor.onbar

import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

/**
 * Earth: the whole planet live, from three open sources, all fetched by the bar itself (no key):
 *
 *  - Aircraft: OpenSky Network's `GET /api/states/all` (every aircraft it receives, about 12 000, 1.5 MB). Anonymous
 *    use is limited to 400 credits a day and this call costs 4, so it is asked at most every 15 minutes, and only while
 *    the app is open (the [Feed] asks while the page polls); after a refusal (429) not again for an hour. The page gets
 *    the counts and up to [MAX_AIRCRAFT] airborne positions at 0.1°, evenly spread over the list.
 *  - Earthquakes: USGS's GeoJSON feed of the last day, magnitude 2.5 and up (`2.5_day`) or 4.5 and up (`4.5_day`),
 *    as chosen in Deckhand (`apps.earth.minMag`), every 10 minutes.
 *  - Satellites: CelesTrak's mean elements (GP data, JSON) for the space stations and the hundred-odd brightest
 *    satellites (`stations`, `visual`), twice a day as CelesTrak asks. The page works out where they are from these.
 *
 * Each source is cached on its own; a failed refresh keeps the copy it had, and the page says how old it is.
 */
internal object EarthFeed {
    private const val OPENSKY = "https://opensky-network.org/api/states/all"
    private const val USGS = "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/"
    private const val CELESTRAK = "https://celestrak.org/NORAD/elements/gp.php?FORMAT=json&GROUP="
    private const val AIRCRAFT_AGE_MS = 15 * 60_000L
    private const val AIRCRAFT_BACKOFF_MS = 60 * 60_000L
    private const val QUAKE_AGE_MS = 10 * 60_000L
    private const val SAT_AGE_MS = 12 * 3_600_000L
    private const val MAX_AIRCRAFT = 2500
    private const val MAX_QUAKES = 60

    private class Cached(val json: JSONObject, val at: Long)

    @Volatile private var aircraft: Cached? = null
    @Volatile private var aircraftTriedAt = 0L
    @Volatile private var quakes: Cached? = null
    @Volatile private var quakesKey = ""
    @Volatile private var quakesTriedAt = 0L
    @Volatile private var sats: Cached? = null
    @Volatile private var satsTriedAt = 0L

    fun earth(cfg: BarConfig): JSONObject {
        val o = try { if (cfg.raw.isEmpty()) JSONObject() else JSONObject(cfg.raw) } catch (_: Exception) { JSONObject() }
        val minMag = if ((o.optJSONObject("apps")?.optJSONObject("earth")?.optDouble("minMag", 2.5) ?: 2.5) >= 4.5) "4.5" else "2.5"
        val now = System.currentTimeMillis()
        if (now - aircraftTriedAt > AIRCRAFT_AGE_MS) { aircraftTriedAt = now; fetchAircraft()?.let { aircraft = Cached(it, now) } }
        if (quakesKey != minMag || now - quakesTriedAt > QUAKE_AGE_MS) {
            quakesTriedAt = now
            fetchQuakes(minMag)?.let { quakes = Cached(it, now); quakesKey = minMag }
        }
        if (now - satsTriedAt > SAT_AGE_MS) { satsTriedAt = now; fetchSats()?.let { sats = Cached(it, now) } }
        val center = if (o.optJSONObject("apps")?.optJSONObject("earth")?.optString("center", "home") == "turn") "turn" else "home"
        val out = JSONObject().put("now", now / 1000).put("center", center)
        aircraft?.let { out.put("aircraft", it.json.put("at", it.at / 1000)) }
        quakes?.let { out.put("quakes", it.json.put("minMag", quakesKey.toDouble())) }
        sats?.let { out.put("sats", it.json.optJSONArray("list")) }
        if (cfg.lat != null && cfg.lon != null) out.put("home", JSONObject().put("lat", cfg.lat).put("lon", cfg.lon).put("place", cfg.place))
        return out
    }

    private fun fetchAircraft(): JSONObject? {
        val body = httpGet(OPENSKY, 20_000, "application/json") ?: run {
            // A refusal is most likely the daily allowance: wait an hour before asking again.
            aircraftTriedAt = System.currentTimeMillis() - AIRCRAFT_AGE_MS + AIRCRAFT_BACKOFF_MS
            return null
        }
        return try {
            val states = JSONObject(String(body, Charsets.UTF_8)).optJSONArray("states") ?: return null
            val airborne = ArrayList<Int>(states.length() * 2)
            var total = 0; var ground = 0
            for (i in 0 until states.length()) {
                val s = states.optJSONArray(i) ?: continue
                total++
                if (s.optBoolean(8, false)) { ground++; continue }
                val lon = (s.opt(5) as? Number)?.toDouble() ?: continue
                val lat = (s.opt(6) as? Number)?.toDouble() ?: continue
                airborne.add(Math.round(lat * 10).toInt()); airborne.add(Math.round(lon * 10).toInt())
            }
            val n = airborne.size / 2
            val step = if (n > MAX_AIRCRAFT) n.toDouble() / MAX_AIRCRAFT else 1.0
            val pos = JSONArray()
            var k = 0.0
            while (k < n) { val i = k.toInt(); pos.put(airborne[2 * i]); pos.put(airborne[2 * i + 1]); k += step }
            JSONObject().put("total", total).put("airborne", n).put("ground", ground).put("pos", pos)
        } catch (e: Exception) { Log.w(TAG, "earth: aircraft", e); null }
    }

    private fun fetchQuakes(minMag: String): JSONObject? {
        val j = httpJson("${USGS}${minMag}_day.geojson", 15_000) ?: return null
        val feats = j.optJSONArray("features") ?: return null
        val list = ArrayList<JSONObject>()
        for (i in 0 until feats.length()) {
            val f = feats.optJSONObject(i) ?: continue
            val p = f.optJSONObject("properties") ?: continue
            val c = f.optJSONObject("geometry")?.optJSONArray("coordinates") ?: continue
            val mag = p.dbl("mag") ?: continue
            list.add(JSONObject().put("mag", round1(mag)).put("place", p.optString("place", ""))
                .put("time", (p.opt("time") as? Number)?.toLong()?.div(1000) ?: 0L)
                .put("lon", c.optDouble(0)).put("lat", c.optDouble(1)).put("depth", Math.round(c.optDouble(2, 0.0)))
                .put("tsunami", p.optInt("tsunami", 0) == 1))
        }
        list.sortByDescending { it.optLong("time") }
        val arr = JSONArray(); list.take(MAX_QUAKES).forEach { arr.put(it) }
        return JSONObject().put("count", list.size).put("list", arr)
    }

    private fun fetchSats(): JSONObject? {
        val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }
        val seen = HashSet<Int>()
        val list = JSONArray()
        for (group in listOf("stations", "visual")) {
            val body = httpGet(CELESTRAK + group, 15_000, "application/json") ?: continue
            val arr = try { JSONArray(String(body, Charsets.UTF_8)) } catch (_: Exception) { continue }
            for (i in 0 until arr.length()) {
                val s = arr.optJSONObject(i) ?: continue
                val id = s.optInt("NORAD_CAT_ID", -1)
                if (id < 0 || !seen.add(id)) continue
                val epochText = s.optString("EPOCH", "")
                val epoch = try {
                    val whole = fmt.parse(epochText.substringBefore('.'))?.time ?: continue
                    whole + ((("0." + epochText.substringAfter('.', "0")).toDoubleOrNull() ?: 0.0) * 1000).toLong()
                } catch (_: Exception) { continue }
                val n = s.dbl("MEAN_MOTION") ?: continue
                if (n < 11) continue   // only low orbits: the globe shows them close to the surface
                list.put(JSONObject().put("id", id).put("name", s.optString("OBJECT_NAME", "").trim())
                    .put("station", group == "stations").put("epoch", epoch)
                    .put("n", n).put("e", s.optDouble("ECCENTRICITY")).put("i", s.optDouble("INCLINATION"))
                    .put("raan", s.optDouble("RA_OF_ASC_NODE")).put("argp", s.optDouble("ARG_OF_PERICENTER"))
                    .put("m", s.optDouble("MEAN_ANOMALY")))
            }
        }
        return if (list.length() == 0) null else JSONObject().put("list", list)
    }
}
