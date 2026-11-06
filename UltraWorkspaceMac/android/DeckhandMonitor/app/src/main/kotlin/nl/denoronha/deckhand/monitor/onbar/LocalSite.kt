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
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit

/**
 * The page and its data, served inside the app for an on-bar page (1.9). The WebView loads
 * `https://deckhand.invalid/<page>`; `.invalid` never resolves, and every request to that host is answered here
 * from `shouldInterceptRequest`, so nothing about it reaches the network:
 *
 *  - `/<page>`                    the Mac's `shell.html` + `<page>.js` (APK assets, the same files Deckhand serves)
 *  - `/<page>/data.json`          [Feeds], fetched by the bar itself and cached ([Feed])
 *  - `/flights/tile/z/x/y.png`    OpenStreetMap tiles, toned down like the Mac's `MapTiles`, cached 30 days
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
        else -> null
    }

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

    fun handle(uri: Uri): WebResourceResponse {
        val parts = (uri.path ?: "").split('/').filter { it.isNotEmpty() }
        return try {
            when {
                parts == listOf(page) -> text(shell(), "text/html")
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

    private var shellCache: String? = null
    private fun shell(): String = shellCache ?: run {
        fun asset(n: String) = ctx.assets.open(n).use { String(it.readBytes(), Charsets.UTF_8) }.removeSuffix("\n")
        asset("shell.html").replace("{{TITLE}}", title).replace("{{WAIT}}", "Loading…").replace("\n{{JS}}\n", "\n" + asset("$page.js") + "\n")
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
