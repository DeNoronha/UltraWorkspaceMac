package nl.denoronha.deckhand.monitor.onbar

import android.net.Uri
import android.util.Xml
import org.json.JSONArray
import org.json.JSONObject
import org.xmlpull.v1.XmlPullParser
import java.text.DateFormat
import java.text.SimpleDateFormat
import java.time.OffsetDateTime
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.ConcurrentHashMap

/**
 * The data behind the six on-bar pages, fetched by the bar itself. Each function returns the same JSON the
 * Mac's `BarPages.swift` serves as `/<page>/data.json`, so the page scripts are shared unchanged. Ports of the
 * Mac's `Flights.swift`, `CryptoStats.swift`, `OpenMeteo.swift`, `NewsFeed.swift` and `DailyVerse.swift`.
 */
internal object Feeds {

    private fun nowS() = System.currentTimeMillis() / 1000

    // ---- flights (adsb.lol + adsbdb.com, no keys) ----------------------------------------------------------

    /** Route per callsign, kept for the app's lifetime (adsbdb asks to be gentle); JSONObject.NULL = unknown. */
    private val routes = ConcurrentHashMap<String, Any>()

    private val compassNames = arrayOf("N", "NE", "E", "SE", "S", "SW", "W", "NW")
    private fun compass(b: Double): String { if (!b.isFinite()) return "N"; var x = (b + 22.5) % 360; if (x < 0) x += 360; return compassNames[(x / 45).toInt() % 8] }

    private fun route(callsign: String): Any {
        val cs = callsign.uppercase().trim()
        if (cs.length !in 3..10 || !cs.all { it in 'A'..'Z' || it in '0'..'9' }) return JSONObject.NULL
        routes[cs]?.let { return it }
        val fr = httpJson("https://api.adsbdb.com/v0/callsign/$cs")?.optJSONObject("response")?.optJSONObject("flightroute")
        val out: Any = if (fr == null) JSONObject.NULL else {
            fun ap(k: String): Any {
                val a = fr.optJSONObject(k) ?: return JSONObject.NULL
                val iata = a.optString("iata_code", ""); if (iata.isEmpty()) return JSONObject.NULL
                return JSONObject().put("iata", iata).put("name", a.optString("name", "")).put("city", a.optString("municipality", "")).put("country", a.optString("country_name", ""))
            }
            JSONObject().put("airline", nullable(fr.optJSONObject("airline")?.optString("name")?.ifEmpty { null })).put("from", ap("origin")).put("to", ap("destination"))
        }
        routes[cs] = out
        return out
    }

    fun flights(cfg: BarConfig): JSONObject? {
        val lat = cfg.lat ?: return JSONObject().put("aircraft", JSONArray()).put("radius", cfg.radiusKm).put("place", "location unknown")
        val lon = cfg.lon ?: return null
        val radius = cfg.radiusKm.toDouble()
        val wide = maxOf(radius, 25.0)   // a wider circle, so "nearest beyond" can be shown when nothing is overhead
        val nm = maxOf(1, Math.ceil(wide / 1.852).toInt())
        val obj = httpJson(String.format(Locale.US, "https://api.adsb.lol/v2/point/%.3f/%.3f/%d", lat, lon, nm), 10_000) ?: return null
        val ac = obj.optJSONArray("ac") ?: JSONArray()
        class A(val o: JSONObject, val km: Double)
        val list = (0 until ac.length()).mapNotNull { i ->
            val a = ac.optJSONObject(i) ?: return@mapNotNull null
            val dst = a.dbl("dst") ?: return@mapNotNull null
            val km = dst * 1.852
            if (km > wide) null else A(a, km)
        }.sortedBy { it.km }
        val out = JSONArray()
        for (x in list.take(8)) {
            val a = x.o
            val callsign = a.optString("flight", "").trim()
            val altRaw = a.opt("alt_baro")
            val ground = altRaw == "ground"
            val altM: Any = (altRaw as? Number)?.let { Math.round(it.toDouble() * 0.3048).toInt() } ?: JSONObject.NULL
            val r = if (callsign.isNotEmpty()) route(callsign) else JSONObject.NULL
            val ro = r as? JSONObject
            val bearing = a.dbl("dir") ?: 0.0
            out.put(JSONObject()
                .put("callsign", callsign).put("reg", a.optString("r", "")).put("type", a.optString("t", ""))
                .put("alt", altM).put("ground", ground)
                .put("speed", nullable(a.dbl("gs")?.let { Math.round(it * 1.852).toInt() }))
                .put("vs", nullable(a.dbl("baro_rate")?.let { it * 0.00508 }))
                .put("track", nullable(a.dbl("track")))
                .put("km", round1(x.km)).put("bearing", bearing).put("dir", compass(bearing)).put("inside", x.km <= radius)
                .put("airline", ro?.opt("airline") ?: JSONObject.NULL).put("from", ro?.opt("from") ?: JSONObject.NULL).put("to", ro?.opt("to") ?: JSONObject.NULL))
        }
        return JSONObject().put("aircraft", out).put("radius", cfg.radiusKm).put("place", cfg.place).put("lat", lat).put("lon", lon).put("at", nowS())
    }

    // ---- crypto (CoinGecko, keyless: a few calls a minute, so calls are spaced and a 429 retried once) ------

    private val knownCoins = mapOf(
        "bitcoin" to "BTC", "ethereum" to "ETH", "ripple" to "XRP", "solana" to "SOL", "cardano" to "ADA", "dogecoin" to "DOGE",
        "litecoin" to "LTC", "polkadot" to "DOT", "chainlink" to "LINK", "binancecoin" to "BNB", "tron" to "TRX", "avalanche-2" to "AVAX",
        "stellar" to "XLM", "monero" to "XMR", "polygon-ecosystem-token" to "POL")
    private fun symbol(id: String) = knownCoins[id.lowercase()] ?: id.uppercase().take(5)
    private fun suffix(cur: String) = when (cur.lowercase()) { "eur" -> "€"; "usd" -> "$"; "gbp" -> "£"; "chf" -> "CHF "; "jpy" -> "¥"; "btc" -> "₿"; else -> cur.uppercase() }

    private var lastGecko = 0L
    @Synchronized private fun gecko(url: String): JSONObject? {
        repeat(2) { attempt ->
            val gap = 1500 - (System.currentTimeMillis() - lastGecko)
            if (gap > 0) Thread.sleep(gap)
            lastGecko = System.currentTimeMillis()
            val body = httpGet(url, 15_000, "application/json") ?: return null
            val text = String(body, Charsets.UTF_8)
            if (text.take(80).contains("\"error_code\":429")) { if (attempt == 0) Thread.sleep(10_000); return@repeat }
            return try { JSONObject(text) } catch (_: Exception) { null }
        }
        return null
    }

    private fun thin(p: List<Double>, n: Int): List<Double> = if (p.size <= n || n < 2) p else (0 until n).map { p[it * (p.size - 1) / (n - 1)] }

    private fun midnightMs(): Long = Calendar.getInstance().apply { set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0) }.timeInMillis

    fun crypto(cfg: BarConfig): JSONObject? {
        val ids = cfg.coins.map { it.trim().lowercase() }.filter { it.isNotEmpty() }
        val cur = cfg.currency.lowercase()
        if (ids.isEmpty()) return JSONObject().put("coins", JSONArray()).put("suffix", suffix(cur))
        val prices = gecko("https://api.coingecko.com/api/v3/simple/price?ids=${Uri.encode(ids.joinToString(","))}&vs_currencies=$cur&include_24hr_change=true")
        val out = JSONArray()
        var any = false
        for (id in ids) {
            val chart = gecko("https://api.coingecko.com/api/v3/coins/${Uri.encode(id)}/market_chart?vs_currency=$cur&days=1")
            val mid = midnightMs()
            val pts = ArrayList<Double>(); var lastBefore: Double? = null
            chart?.optJSONArray("prices")?.let { arr ->
                for (i in 0 until arr.length()) {
                    val p = arr.optJSONArray(i) ?: continue
                    val t = p.optDouble(0, Double.NaN); val v = p.optDouble(1, Double.NaN)
                    if (!t.isFinite() || !v.isFinite()) continue
                    if (t < mid) lastBefore = v else pts.add(v)
                }
            }
            if (pts.isEmpty()) lastBefore?.let { pts.add(it) }
            val entry = prices?.optJSONObject(id)
            val price = entry?.dbl(cur) ?: pts.lastOrNull() ?: 0.0
            if (entry != null || pts.isNotEmpty()) any = true
            out.put(JSONObject().put("symbol", symbol(id)).put("price", price).put("change", entry?.dbl("${cur}_24h_change") ?: 0.0)
                .put("points", JSONArray(thin(pts, 90))).put("open", lastBefore ?: pts.firstOrNull() ?: 0.0))
        }
        if (!any) return null   // CoinGecko said nothing useful: keep the last good answer
        return JSONObject().put("coins", out).put("suffix", suffix(cur)).put("at", nowS())
    }

    // ---- weather (Open-Meteo, no key) -------------------------------------------------------------------------

    private fun sky(code: Int) = when (code) {
        0 -> "clear"; 1, 2 -> "partlyCloudy"; 3 -> "cloudy"; 45, 48 -> "fog"; 51, 53, 55, 56, 57 -> "drizzle"
        61, 63, 65, 66, 67 -> "rain"; 71, 73, 75, 77, 85, 86 -> "snow"; 80, 81, 82 -> "showers"; 95, 96, 99 -> "thunder"; else -> "unknown"
    }

    fun weather(cfg: BarConfig): JSONObject? {
        val lat = cfg.lat ?: return JSONObject()
        val lon = cfg.lon ?: return JSONObject()
        val tu = if (cfg.metric) "celsius" else "fahrenheit"; val wu = if (cfg.metric) "kmh" else "mph"
        val now = httpJson("https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon&current=temperature_2m,relative_humidity_2m,weather_code,is_day,wind_speed_10m&temperature_unit=$tu&wind_speed_unit=$wu&timezone=auto")
            ?.optJSONObject("current") ?: return null
        val daily = httpJson("https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max&temperature_unit=$tu&forecast_days=4&timezone=auto")
            ?.optJSONObject("daily")
        val code = now.int("weather_code") ?: 0
        val days = JSONArray()
        if (daily != null) {
            val dates = daily.optJSONArray("time") ?: JSONArray()
            fun num(k: String, i: Int): Double? = daily.optJSONArray(k)?.opt(i).let { (it as? Number)?.toDouble() }
            for (i in 0 until dates.length()) {
                val c = num("weather_code", i)?.toInt() ?: 0
                days.put(JSONObject().put("date", dates.optString(i)).put("sky", sky(c)).put("code", c)
                    .put("max", Math.round(num("temperature_2m_max", i) ?: 0.0).toDouble()).put("min", Math.round(num("temperature_2m_min", i) ?: 0.0).toDouble())
                    .put("rain", (num("precipitation_probability_max", i) ?: 0.0).toInt()))
            }
        }
        return JSONObject().put("place", cfg.place).put("temp", Math.round(now.dbl("temperature_2m") ?: 0.0).toDouble()).put("unit", if (cfg.metric) "°C" else "°F")
            .put("sky", sky(code)).put("code", code).put("isDay", (now.int("is_day") ?: 1) == 1).put("humidity", now.int("relative_humidity_2m") ?: 0)
            .put("wind", Math.round(now.dbl("wind_speed_10m") ?: 0.0).toInt()).put("windUnit", if (cfg.metric) "km/h" else "mph").put("days", days)
    }

    // ---- sun & moon (computed here, no service) -------------------------------------------------------------

    fun sky(cfg: BarConfig): JSONObject? {
        val lat = cfg.lat ?: return JSONObject().put("place", cfg.place)
        val lon = cfg.lon ?: return JSONObject().put("place", cfg.place)
        val now = System.currentTimeMillis()
        val s = SkyMath.sunDay(now, lat, lon); val m = SkyMath.moonInfo(now, lat, lon)
        fun t(ms: Long?): Any = ms?.let { it / 1000 } ?: JSONObject.NULL
        return JSONObject().put("place", cfg.place).put("lat", lat).put("now", now / 1000).put("tz", TimeZone.getDefault().getOffset(now) / 1000)
            .put("sun", JSONObject().put("rise", t(s.sunrise)).put("set", t(s.sunset)).put("noon", t(s.solarNoon)).put("dawn", t(s.civilDawn)).put("dusk", t(s.civilDusk))
                .put("goldenEnd", t(s.goldenEnd)).put("goldenStart", t(s.goldenStart)).put("dayLength", s.dayLengthS.toInt())
                .put("elevation", round1(s.now.elevation)).put("azimuth", Math.round(s.now.azimuth).toDouble()))
            .put("moon", JSONObject().put("phase", m.phase).put("illumination", m.illumination).put("age", round1(m.ageDays)).put("name", m.name).put("waxing", m.waxing)
                .put("rise", t(m.rise)).put("set", t(m.set)).put("nextFull", t(m.nextFull)).put("nextNew", t(m.nextNew))
                .put("elevation", round1(m.now.elevation)).put("azimuth", Math.round(m.now.azimuth).toDouble()).put("distanceKm", m.distanceKm.toInt()))
    }

    // ---- headlines (RSS, or CNN's text-only front page) -----------------------------------------------------

    private class Source(val id: String, val name: String, val url: String, val cnnLite: Boolean = false)
    private val sources = listOf(
        Source("cnn", "CNN", "https://lite.cnn.com/", cnnLite = true),
        Source("bbc", "BBC World", "https://feeds.bbci.co.uk/news/world/rss.xml"),
        Source("nyt", "New York Times", "https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml"),
        Source("guardian", "The Guardian", "https://www.theguardian.com/world/rss"),
        Source("nos", "NOS", "https://feeds.nos.nl/nosnieuwsalgemeen"),
        Source("nu", "NU.nl", "https://www.nu.nl/rss/Algemeen"))

    private class Item(val title: String, val dateMs: Long?, val summary: String, val dayMs: Long? = null)

    private val entities = listOf("&amp;" to "&", "&lt;" to "<", "&gt;" to ">", "&quot;" to "\"", "&#39;" to "'", "&#x27;" to "'", "&apos;" to "'", "&nbsp;" to " ")
    private fun clean(s: String): String {
        var t = s.replace(Regex("<[^>]+>"), " ")
        for ((a, b) in entities) t = t.replace(a, b)
        return t.replace(Regex("\\s+"), " ").trim()
    }

    private fun parseDate(s: String): Long? {
        val t = s.trim(); if (t.isEmpty()) return null
        try { return ZonedDateTime.parse(t, DateTimeFormatter.RFC_1123_DATE_TIME).toInstant().toEpochMilli() } catch (_: Exception) {}
        try { return OffsetDateTime.parse(t).toInstant().toEpochMilli() } catch (_: Exception) {}
        for (f in listOf("EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz")) {
            try { return SimpleDateFormat(f, Locale.US).parse(t)?.time } catch (_: Exception) {}
        }
        return null
    }

    private fun parseRss(body: ByteArray): List<Item> {
        val out = ArrayList<Item>()
        val p = Xml.newPullParser()
        p.setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, false)
        p.setInput(body.inputStream(), null)
        var inItem = false; var field: String? = null
        val cur = HashMap<String, String>()
        try {
            while (true) {
                when (p.next()) {
                    XmlPullParser.START_TAG -> {
                        val n = p.name
                        if (n == "item" || n == "entry") { inItem = true; cur.clear() }
                        else if (inItem) {
                            if (n == "link" && cur["link"] == null) p.getAttributeValue(null, "href")?.let { cur["link"] = it }
                            field = n
                        }
                    }
                    XmlPullParser.TEXT -> if (inItem) field?.let { cur[it] = (cur[it] ?: "") + p.text }
                    XmlPullParser.END_TAG -> {
                        val n = p.name
                        if (n == "item" || n == "entry") {
                            inItem = false
                            val title = clean(cur["title"] ?: "")
                            if (title.isNotEmpty()) {
                                val date = parseDate(cur["pubDate"] ?: cur["published"] ?: cur["updated"] ?: cur["dc:date"] ?: "")
                                out.add(Item(title, date, clean(cur["description"] ?: cur["summary"] ?: "")))
                            }
                        }
                        field = null
                    }
                    XmlPullParser.END_DOCUMENT -> return out
                }
            }
        } catch (e: Exception) { return out }
    }

    private fun parseCnnLite(html: String): List<Item> {
        val re = Regex("<li class=\"card--lite\">\\s*<a href=\"([^\"]+)\">\\s*([^<]+?)\\s*</a>")
        val df = SimpleDateFormat("yyyy/MM/dd", Locale.US).apply { timeZone = TimeZone.getTimeZone("America/New_York") }
        val now = System.currentTimeMillis()
        return re.findAll(html).mapNotNull { m ->
            val path = m.groupValues[1]; val title = clean(m.groupValues[2])
            val day = Regex("^/(\\d{4}/\\d{2}/\\d{2})/").find(path)?.groupValues?.get(1)?.let { try { df.parse(it)?.time } catch (_: Exception) { null } }
            if (day != null && now - day > 2 * 86_400_000L) null else Item(title, null, "", day)
        }.toList()
    }

    private fun dayLabel(ms: Long): String {
        val c = Calendar.getInstance(); val today = midnightMs()
        c.timeInMillis = ms
        return when {
            ms >= today -> "today"
            ms >= today - 86_400_000L -> "yesterday"
            else -> DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(ms))
        }
    }

    fun news(cfg: BarConfig): JSONObject? {
        val src = sources.firstOrNull { it.id == cfg.news } ?: sources[0]
        val body = httpGet(src.url, 15_000) ?: return null
        val items = (if (src.cnnLite) parseCnnLite(String(body, Charsets.UTF_8)) else parseRss(body)).take(14)
        if (items.isEmpty()) return null
        val now = System.currentTimeMillis()
        val arr = JSONArray()
        for (i in items) arr.put(JSONObject().put("title", i.title).put("ago", nullable(i.dateMs?.let { (now - it) / 1000 }))
            .put("summary", i.summary.take(160)).put("day", nullable(i.dayMs?.let { dayLabel(it) })))
        return JSONObject().put("source", src.name).put("at", nowS()).put("items", arr)
    }

    // ---- verse of the day (bible-api.com, World English Bible) ----------------------------------------------

    private val references = listOf(
        "John 3:16", "Psalm 23:1-4", "Philippians 4:6-7", "Proverbs 3:5-6", "Isaiah 41:10", "Romans 8:28", "Jeremiah 29:11",
        "Matthew 11:28-30", "Psalm 46:1", "Joshua 1:9", "Psalm 119:105", "Romans 12:2", "1 Corinthians 13:4-7", "Galatians 5:22-23",
        "Hebrews 11:1", "Philippians 4:13", "Psalm 27:1", "Matthew 6:33-34", "Isaiah 40:31", "2 Timothy 1:7", "Psalm 37:4-5",
        "Proverbs 16:3", "Romans 15:13", "Ephesians 2:8-10", "1 Peter 5:7", "Psalm 139:13-14", "Micah 6:8", "John 14:27",
        "Lamentations 3:22-23", "Psalm 118:24", "James 1:5", "Colossians 3:23-24", "Deuteronomy 31:6", "Psalm 121:1-2",
        "Matthew 5:14-16", "1 John 4:7-8", "Isaiah 26:3", "Romans 5:8", "Psalm 100:4-5", "Proverbs 18:10", "Ephesians 4:32",
        "John 16:33", "Psalm 34:8", "Philippians 1:6", "Hebrews 13:8", "2 Corinthians 5:17", "Psalm 91:1-2", "Matthew 7:7-8",
        "Nahum 1:7", "1 Thessalonians 5:16-18", "Psalm 19:1", "Romans 8:38-39", "Proverbs 22:6", "John 15:5", "Psalm 51:10",
        "Isaiah 43:2", "Galatians 6:9", "Psalm 103:2-4", "Matthew 28:19-20", "Ecclesiastes 3:1", "Hebrews 4:16", "Psalm 16:11",
        "James 1:2-4", "1 Corinthians 10:13", "Psalm 62:1-2", "Zephaniah 3:17", "John 8:12", "Ephesians 6:10-11", "Psalm 90:12",
        "Proverbs 4:23", "Romans 12:12", "Psalm 56:3", "Matthew 22:37-39", "Isaiah 55:8-9", "Colossians 3:2", "Psalm 32:8",
        "Luke 1:37", "2 Chronicles 7:14", "Psalm 145:18", "Titus 3:5", "John 10:10", "Habakkuk 3:17-18", "Psalm 4:8",
        "Proverbs 15:1", "Mark 12:30-31", "1 John 1:9", "Psalm 73:26", "Revelation 21:4", "Matthew 19:26", "Psalm 147:3",
        "Isaiah 9:6", "Luke 6:31", "Psalm 150:6", "Romans 10:9", "Proverbs 17:17", "Acts 1:8", "Psalm 143:8", "John 1:5")

    /** Same sequence as the Mac: day of year plus the year, so both show the same verse on the same day. */
    fun verseReference(): String {
        val c = Calendar.getInstance()
        return references[(c.get(Calendar.DAY_OF_YEAR) + c.get(Calendar.YEAR) * 97) % references.size]
    }

    fun verse(@Suppress("UNUSED_PARAMETER") cfg: BarConfig): JSONObject? {
        val ref = verseReference()
        val o = httpJson("https://bible-api.com/${Uri.encode(ref, ":")}?translation=web", 15_000) ?: return null
        val v = o.optJSONArray("verses") ?: return null
        val text = (0 until v.length()).mapNotNull { v.optJSONObject(it)?.optString("text") }.joinToString(" ").replace(Regex("\\s+"), " ").trim()
        if (text.isEmpty()) return null
        return JSONObject().put("reference", o.optString("reference", ref)).put("text", text).put("translation", "World English Bible")
            .put("date", DateFormat.getDateInstance(DateFormat.LONG).format(Date()))
    }
}
