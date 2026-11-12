package nl.denoronha.deckhand.monitor.onbar

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.Paint
import android.net.Uri
import android.util.Log
import android.webkit.WebResourceResponse
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit

/**
 * Every bar app (1.9) carries its own page; this class answers the page's requests. The WebView loads
 * `https://deckhand.invalid/<page>`; `.invalid` never resolves, and every request to that host is answered here
 * from `shouldInterceptRequest`, so nothing for that host reaches the network itself:
 *
 *  - `/<page>`                    the Mac's `shell.html` + `<page>.js`, or `monitor.html` (APK assets, the same files Deckhand serves)
 *
 * On-bar pages (flights, crypto, weather, sky, news, verse, tide, teletekst) also get their data here:
 *  - `/<page>/data.json`          [Feeds], fetched by the bar itself and cached ([Feed])
 *  - `/flights/tile/z/x/y.png`    OpenStreetMap tiles, toned down like the Mac's `MapTiles`, cached 30 days
 *
 * Mac pages (monitor, claude, music, calendar, tasks, haven, strava, cask, schiphol, zeekr) show what only the Mac knows, so their data requests are
 * passed on to Deckhand's data API at the address its beacon names ([macBase]): `/monitor/stats.json`,
 * `/<page>/data.json`, `/music/art.jpg`, `/zeekr/car/<normal|charging|trunk>.png` (the owner's own car picture), and the two actions (POST `/music/cmd/…`, `/tasks/done/…`, with the
 * `X-Deckhand: action` header the Mac requires). Nothing else is forwarded. While no Mac is known the answer is
 * 503 and the page shows "Waiting for the Mac…".
 */
internal class LocalSite(private val ctx: Context, private val page: String, private val title: String) {
    companion object {
        const val HOST = "deckhand.invalid"
        const val ORIGIN = "https://$HOST"
        private const val TILE_MAX_AGE_MS = 30L * 86_400_000
    }

    private val feed: Feed? = when (page) {
        "flights" -> Feed(10_000, Feeds::flights)
        "crypto" -> Feed(120_000, Feeds::crypto)
        "weather" -> Feed(900_000, Feeds::weather)
        "sky" -> Feed(60_000, Feeds::sky)
        "news" -> Feed(600_000, Feeds::news)
        "verse" -> Feed(3_600_000, Feeds::verse)
        "tide" -> Feed(600_000, TideFeed::tide)
        "teletekst" -> Feed(60_000, TeletekstFeed::teletekst)   // each NOS page has its own, longer cache
        else -> null
    }

    /** `http://<mac>:7432`, from the beacon (and remembered across restarts); null until a Mac was heard. */
    @Volatile var macBase: String? = null

    @Volatile private var config: BarConfig? = null
    /** Drop the parsed config; the next data request reads the stored document again. */
    fun reloadConfig() { config = null }
    /** The parsed config, read again whenever the stored document changed (a push or a beacon fetch). */
    private fun cfg(): BarConfig {
        val c = config
        if (c != null && c.raw == BarConfig.stored(ctx)) return c
        return BarConfig.load(ctx, page).also { config = it }
    }

    private val tileDir = File(ctx.cacheDir, "tiles-v3").apply { mkdirs() }
    private val tileSlots = Semaphore(4)

    fun handle(uri: Uri, method: String = "GET"): WebResourceResponse {
        val parts = (uri.path ?: "").split('/').filter { it.isNotEmpty() }
        return try {
            when {
                parts == listOf(page) -> text(shell(), "text/html")
                feed == null -> forward(parts, uri.encodedQuery, method)
                parts == listOf(page, "data.json") && feed != null -> {
                    val c = cfg()
                    val key = if (page == "verse") Feeds.verseReference() + c.raw else c.raw
                    text(feed.get(c, key).toString(), "application/json")
                }
                page == "flights" && parts.size == 5 && parts[1] == "tile" -> tile(parts[2].toIntOrNull(), parts[3].toIntOrNull(), parts[4].removeSuffix(".png").toIntOrNull())
                else -> notFound()
            }
        } catch (e: Exception) {
            Log.w(TAG, "local ${uri.path} failed", e); notFound()
        }
    }

    /** The Mac pages' data requests, passed to Deckhand unchanged. Only these shapes are forwarded. */
    private fun forward(parts: List<String>, query: String?, method: String): WebResourceResponse {
        val allowed = when {
            method == "GET" && parts == listOf(page, "data.json") && page != "monitor" -> true
            method == "GET" && page == "monitor" && parts == listOf("monitor", "stats.json") -> true
            method == "GET" && page == "music" && parts == listOf("music", "art.jpg") -> true
            method == "GET" && page == "zeekr" && parts.size == 3 && parts[1] == "car" && parts[2] in setOf("normal.png", "charging.png", "trunk.png") -> true
            method == "POST" && page == "music" && parts.size == 3 && parts[1] == "cmd" && parts[2] in setOf("play", "next", "previous") -> true
            method == "POST" && page == "tasks" && parts.size == 3 && parts[1] == "done" && parts[2].matches(Regex("^[0-9a-fA-F-]{36}$")) -> true
            else -> false
        }
        if (!allowed) return notFound()
        val base = macBase ?: return status(503, "Service Unavailable")
        val target = base + "/" + parts.joinToString("/") + (if (query.isNullOrEmpty()) "" else "?$query")
        return try {
            val c = URL(target).openConnection() as HttpURLConnection
            c.connectTimeout = 4_000; c.readTimeout = 6_000; c.requestMethod = method
            c.setRequestProperty("User-Agent", USER_AGENT)
            if (method == "POST") { c.setRequestProperty("X-Deckhand", "action"); c.doOutput = true; c.setFixedLengthStreamingMode(0); c.outputStream.close() }
            val code = c.responseCode
            val body = (if (code in 200..299) c.inputStream else c.errorStream)?.use { it.readBytes() } ?: ByteArray(0)
            val type = (c.contentType ?: "application/octet-stream").substringBefore(';').trim()
            c.disconnect()
            WebResourceResponse(type, "utf-8", code, if (code in 200..299) "OK" else "Error", mapOf("Cache-Control" to "no-store"), ByteArrayInputStream(body))
        } catch (e: Exception) {
            status(502, "Bad Gateway")
        }
    }

    private fun status(code: Int, reason: String) = WebResourceResponse("text/plain", "utf-8", code, reason, mapOf("Cache-Control" to "no-store"), ByteArrayInputStream(ByteArray(0)))

    private var shellCache: String? = null
    private fun shell(): String = shellCache ?: run {
        fun asset(n: String) = ctx.assets.open(n).use { String(it.readBytes(), Charsets.UTF_8) }.removeSuffix("\n")
        if (page == "monitor") return@run asset("monitor.html").also { shellCache = it }
        asset("shell.html").replace("{{TITLE}}", title).replace("{{WAIT}}", if (feed != null) "Loading…" else "Waiting for the Mac…").replace("\n{{JS}}\n", "\n" + asset("$page.js") + "\n")
            .also { shellCache = it }
    }

    private fun text(body: String, type: String) = WebResourceResponse(type, "utf-8", 200, "OK",
        mapOf("Cache-Control" to "no-store"), ByteArrayInputStream(body.toByteArray(Charsets.UTF_8)))

    private fun notFound() = WebResourceResponse("text/plain", "utf-8", 404, "Not Found", emptyMap(), ByteArrayInputStream(ByteArray(0)))

    private fun png(b: ByteArray) = WebResourceResponse("image/png", null, 200, "OK", mapOf("Cache-Control" to "max-age=86400"), ByteArrayInputStream(b))

    private fun tile(z: Int?, x: Int?, y: Int?): WebResourceResponse {
        if (z == null || x == null || y == null || z !in 2..17 || x < 0 || y < 0 || x >= (1 shl z) || y >= (1 shl z)) return notFound()
        val f = File(tileDir, "$z-$x-$y.png")
        var stale: ByteArray? = null
        if (f.exists() && f.length() > 0) {
            val b = f.readBytes()
            if (System.currentTimeMillis() - f.lastModified() < TILE_MAX_AGE_MS) return png(b)
            stale = b   // older than 30 days: try to refresh, but an old map beats no map
        }
        if (!tileSlots.tryAcquire(2, TimeUnit.SECONDS)) return stale?.let(::png) ?: notFound()
        try {
            val raw = httpGet("https://tile.openstreetmap.org/$z/$x/$y.png", 8_000) ?: return stale?.let(::png) ?: notFound()
            val toned = tone(raw) ?: return stale?.let(::png) ?: notFound()
            f.writeBytes(toned)
            return png(toned)
        } finally { tileSlots.release() }
    }

    /** The Mac's filter: saturation 0.8, brightness −0.08 (CIColorControls), so the map does not glare at night. */
    private fun tone(pngBytes: ByteArray): ByteArray? {
        val src = BitmapFactory.decodeByteArray(pngBytes, 0, pngBytes.size) ?: return null
        val out = Bitmap.createBitmap(src.width, src.height, Bitmap.Config.ARGB_8888)
        val m = ColorMatrix().apply { setSaturation(0.8f) }
        m.postConcat(ColorMatrix(floatArrayOf(1f, 0f, 0f, 0f, -20.4f, 0f, 1f, 0f, 0f, -20.4f, 0f, 0f, 1f, 0f, -20.4f, 0f, 0f, 0f, 1f, 0f)))
        Canvas(out).drawBitmap(src, 0f, 0f, Paint().apply { colorFilter = ColorMatrixColorFilter(m) })
        src.recycle()
        return ByteArrayOutputStream().also { out.compress(Bitmap.CompressFormat.PNG, 100, it); out.recycle() }.toByteArray()
    }
}
