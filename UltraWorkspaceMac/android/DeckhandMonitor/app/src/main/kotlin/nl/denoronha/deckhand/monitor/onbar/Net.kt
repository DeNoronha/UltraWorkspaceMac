package nl.denoronha.deckhand.monitor.onbar

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

internal const val TAG = "DeckhandMonitor"
internal const val USER_AGENT = "Deckhand-bar/2.0 (+https://denoronha.github.io/UltraWorkspaceMac/)"

/** Background work for feed refreshes; three threads are plenty for one page per app. */
internal val pool: ExecutorService = Executors.newFixedThreadPool(3)

/** Plain GET with a timeout. Returns the body for a 2xx answer, else null. Never throws. */
internal fun httpGet(url: String, timeoutMs: Int = 12_000, accept: String? = null): ByteArray? = try {
    val c = URL(url).openConnection() as HttpURLConnection
    c.connectTimeout = timeoutMs; c.readTimeout = timeoutMs
    c.instanceFollowRedirects = true
    c.setRequestProperty("User-Agent", USER_AGENT)
    if (accept != null) c.setRequestProperty("Accept", accept)
    try {
        if (c.responseCode !in 200..299) { Log.w(TAG, "GET $url → HTTP ${c.responseCode}"); null }
        else c.inputStream.use { input -> ByteArrayOutputStream().also { input.copyTo(it) }.toByteArray() }
    } finally { c.disconnect() }
} catch (e: Exception) {
    Log.w(TAG, "GET $url failed: ${e.message}")
    null
}

internal fun httpJson(url: String, timeoutMs: Int = 12_000): JSONObject? =
    httpGet(url, timeoutMs, "application/json")?.let { try { JSONObject(String(it, Charsets.UTF_8)) } catch (_: Exception) { null } }

internal fun JSONObject.dbl(k: String): Double? = (opt(k) as? Number)?.toDouble()?.takeIf { it.isFinite() }
internal fun JSONObject.int(k: String): Int? = (opt(k) as? Number)?.toInt()
internal fun nullable(v: Any?): Any = v ?: JSONObject.NULL
internal fun round1(v: Double) = Math.round(v * 10) / 10.0

/**
 * What Deckhand says the apps should show: pushed over adb ([ConfigReceiver]) or picked up as `/config.json` when
 * its beacon is heard, and kept in preferences, so the apps keep working while the Mac is off. Without any Mac ever seen: the Mac app's own
 * defaults, and the position from the bar's public IP (ipwho.is), as Deckhand itself falls back to.
 */
internal class BarConfig(
    val lat: Double?, val lon: Double?, val place: String,
    val metric: Boolean, val clock24h: Boolean,
    val coins: List<String>, val currency: String,
    val news: String, val radiusKm: Int,
    val raw: String,
) {
    companion object {
        private const val PREFS = "onbar"
        private const val KEY = "config"
        private const val KEY_IP = "iploc"
        private const val KEY_IP_AT = "iplocAt"

        /** The stored document as text ("" when none), cheap: SharedPreferences are held in memory. */
        fun stored(ctx: Context): String = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, null) ?: ""

        /**
         * The settings for [page] from the stored document. v2 (Deckhand 0.2.4+): shared `location` and `units`,
         * `apps.<page>` for the app's own settings, and an optional `apps.<page>.location` that overrides the shared
         * one. v1 (flat, only ever served as /config.json during development) is read too. Every value is clamped.
         */
        fun load(ctx: Context, page: String): BarConfig {
            val raw = stored(ctx)
            val o = try { if (raw.isEmpty()) JSONObject() else JSONObject(raw) } catch (_: Exception) { JSONObject() }
            val v2 = o.optInt("v", 1) >= 2
            val app = if (v2) o.optJSONObject("apps")?.optJSONObject(page) ?: JSONObject() else o
            val units = if (v2) o.optJSONObject("units") ?: JSONObject() else o
            val loc = app.optJSONObject("location") ?: (if (v2) o.optJSONObject("location") else o) ?: JSONObject()
            var lat = loc.dbl("lat")?.takeIf { it in -90.0..90.0 }; var lon = loc.dbl("lon")?.takeIf { it in -180.0..180.0 }
            var place = loc.optString("place", "").take(60)
            if (lat == null || lon == null) {
                val ip = ipLocation(ctx)
                if (ip != null) { lat = ip.dbl("lat"); lon = ip.dbl("lon"); place = ip.optString("city", "") }
            }
            val cr = if (v2) o.optJSONObject("apps")?.optJSONObject("crypto") else o.optJSONObject("crypto")
            val coins = cr?.optJSONArray("coins")?.let { a -> (0 until a.length()).map { a.optString(it).trim().lowercase() } }
                ?.filter { it.matches(Regex("^[a-z0-9-]{1,40}$")) }?.take(5) ?: listOf("ethereum", "ripple")
            val currency = cr?.optString("currency", "eur")?.lowercase()?.takeIf { it.matches(Regex("^[a-z]{3,4}$")) } ?: "eur"
            val news = (if (v2) o.optJSONObject("apps")?.optJSONObject("news")?.optString("source") else o.optString("news"))?.takeIf { it.isNotBlank() } ?: "cnn"
            val radius = if (v2) o.optJSONObject("apps")?.optJSONObject("flights")?.optInt("radiusKm", 3) ?: 3 else o.optInt("flightsRadiusKm", 3)
            return BarConfig(lat, lon, place, units.optBoolean("metric", true), units.optBoolean("clock24h", true),
                coins, currency, news, radius.coerceIn(1, 50), raw)
        }

        /** Store a config.json from the Mac; returns true when it differs from what was stored. */
        fun save(ctx: Context, json: JSONObject): Boolean {
            val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val s = json.toString()
            if (p.getString(KEY, null) == s) return false
            p.edit().putString(KEY, s).apply()
            return true
        }

        /** The bar's public-IP position, cached for a day. Only used while no Mac has given a location. */
        private fun ipLocation(ctx: Context): JSONObject? {
            val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val cached = p.getString(KEY_IP, null)
            if (cached != null && System.currentTimeMillis() - p.getLong(KEY_IP_AT, 0) < 86_400_000) return try { JSONObject(cached) } catch (_: Exception) { null }
            val o = httpJson("https://ipwho.is/") ?: return cached?.let { try { JSONObject(it) } catch (_: Exception) { null } }
            if (o.optBoolean("success", true) == false) return null
            val out = JSONObject().put("lat", o.dbl("latitude")).put("lon", o.dbl("longitude")).put("city", o.optString("city", ""))
            p.edit().putString(KEY_IP, out.toString()).putLong(KEY_IP_AT, System.currentTimeMillis()).apply()
            return out
        }
    }
}

/**
 * One page's data: computed on demand, kept for [ttlMs]. The first request waits for the first answer; after
 * that a request always gets the last answer at once and a stale one triggers a refresh in the background.
 * A change of [key] (new config, a new day) counts as stale and is waited for, so the page never shows the
 * old place or coins after Deckhand changed them.
 */
internal class Feed(private val ttlMs: Long, private val compute: (BarConfig) -> JSONObject?) {
    @Volatile private var value: JSONObject? = null
    @Volatile private var at = 0L
    @Volatile private var key: String? = null
    private val refreshing = AtomicBoolean(false)

    fun get(cfg: BarConfig, k: String = cfg.raw): JSONObject {
        val v = value
        if (v == null || key != k) {
            synchronized(this) { if (value == null || key != k) refresh(cfg, k) }
            return value ?: JSONObject()
        }
        if (System.currentTimeMillis() - at > ttlMs && refreshing.compareAndSet(false, true)) {
            pool.execute { try { refresh(cfg, k) } finally { refreshing.set(false) } }
        }
        return v
    }

    private fun refresh(cfg: BarConfig, k: String) {
        val r = try { compute(cfg) } catch (e: Exception) { Log.w(TAG, "feed failed", e); null }
        if (r != null) { value = r; at = System.currentTimeMillis(); key = k }
    }
}

internal fun JSONArray.strings(): List<String> = (0 until length()).map { optString(it) }
