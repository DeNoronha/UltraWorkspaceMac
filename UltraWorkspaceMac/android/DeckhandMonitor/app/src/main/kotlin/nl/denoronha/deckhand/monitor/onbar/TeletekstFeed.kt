package nl.denoronha.deckhand.monitor.onbar

import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ConcurrentHashMap

/**
 * Teletekst: NOS Teletekst pages from teletekst-data.nos.nl, the JSON behind nos.nl/teletekst (no key). A page is
 * `GET /json/<nnn>` or `/json/<nnn>-<sub>` for a subpage, answered with `{prevPage, nextPage, prevSubPage,
 * nextSubPage, fastTextLinks, content}`; `content` is the page as 25 lines of 40 cells of HTML: spans with the
 * teletext colours as classes (`yellow`, `bg-blue`, …), links to other pages as `<a href="#104">`, and the mosaic
 * graphics as private-use characters U+F020–U+F07F (0xF000 + the G1 sextant code). A page that does not exist is 404.
 *
 * The rotation comes from `apps.teletekst` in the config (`{"pages":[{"page","stories"}…],"interval"}`, from
 * teletekst.json on the Mac; 101 with its stories, 601 and 702 by default). For each entry: the page and its subpages
 * (following `nextSubPage`), then, with `stories`, the pages its body links to (lines 1–22, so not the fast-text row
 * or the "nieuwsoverzicht 102,103" footer) with their subpages. The HTML goes to the page unchanged; teletekst.js
 * parses it into cells (one parser, and the colours stay exactly as NOS sends them).
 *
 * Gentle on NOS: each page is cached on its own, an index page (a configured one) for 2 minutes and a story for 10,
 * a missing page for 10; requests go one at a time, a quarter of a second apart, and only while the app is open
 * (the [Feed] asks every minute while the page polls). A failed refresh keeps the copy it had.
 */
internal object TeletekstFeed {
    private const val BASE = "https://teletekst-data.nos.nl/json/"
    private const val INDEX_AGE_MS = 120_000L
    private const val STORY_AGE_MS = 600_000L
    private const val GAP_MS = 250L
    private const val MAX_STORIES = 16
    private const val MAX_SUBPAGES = 6
    private const val MAX_PAGES = 48

    class Entry(val page: String, val stories: Boolean)

    private val defaults = listOf(Entry("101", true), Entry("601", false), Entry("702", false))

    /** The entries from `apps.teletekst.pages` (valid page numbers 100–899, once each, at most eight); the defaults without any. */
    fun entries(o: JSONObject): List<Entry> {
        val arr = o.optJSONObject("apps")?.optJSONObject("teletekst")?.optJSONArray("pages") ?: return defaults
        val out = (0 until arr.length()).mapNotNull { i ->
            val e = arr.optJSONObject(i) ?: return@mapNotNull null
            val p = e.optString("page", "").trim()
            if (!p.matches(Regex("^[1-8][0-9]{2}$"))) null else Entry(p, e.optBoolean("stories", false))
        }.distinctBy { it.page }.take(8)
        return out.ifEmpty { defaults }
    }

    /** One fetched page: the JSON, or null for a page NOS does not have (404). */
    private class Cached(val json: JSONObject?, val at: Long)
    private val cache = ConcurrentHashMap<String, Cached>()
    private var lastRequest = 0L

    /** `id` ("104" or "104-2") from the cache when younger than [maxAgeMs], else from NOS. A failed request keeps the old copy. */
    @Synchronized private fun page(id: String, maxAgeMs: Long): JSONObject? {
        val now = System.currentTimeMillis()
        val c = cache[id]
        if (c != null && now - c.at < maxAgeMs) return c.json
        val wait = lastRequest + GAP_MS - now
        if (wait > 0) Thread.sleep(wait)
        lastRequest = System.currentTimeMillis()
        return when (val r = get(BASE + id)) {
            is Answer.Ok -> try { JSONObject(r.body).also { cache[id] = Cached(it, System.currentTimeMillis()) } } catch (_: Exception) { c?.json }
            is Answer.Missing -> { cache[id] = Cached(null, System.currentTimeMillis()); null }
            is Answer.Failed -> c?.json
        }
    }

    private sealed class Answer { class Ok(val body: String) : Answer(); object Missing : Answer(); object Failed : Answer() }

    private fun get(url: String): Answer = try {
        val c = URL(url).openConnection() as HttpURLConnection
        c.connectTimeout = 8_000; c.readTimeout = 8_000
        c.setRequestProperty("User-Agent", USER_AGENT)
        c.setRequestProperty("Accept", "application/json")
        try {
            when (val code = c.responseCode) {
                in 200..299 -> Answer.Ok(c.inputStream.use { i -> ByteArrayOutputStream().also { i.copyTo(it) }.toString("UTF-8") })
                404 -> Answer.Missing
                else -> { Log.w(TAG, "GET $url → HTTP $code"); Answer.Failed }
            }
        } finally { c.disconnect() }
    } catch (e: Exception) {
        Log.w(TAG, "GET $url failed: ${e.message}"); Answer.Failed
    }

    /** A page and its subpages, in order: "104", "104-2", … as long as NOS names a next subpage. */
    private fun withSubpages(p: String, maxAgeMs: Long): List<Pair<String, JSONObject>> {
        val first = page(p, maxAgeMs) ?: return emptyList()
        val out = mutableListOf(p to first)
        var next = first.optString("nextSubPage", "")
        while (next.matches(Regex("^$p-[0-9]{1,2}$")) && out.size < MAX_SUBPAGES && out.none { it.first == next }) {
            val j = page(next, maxAgeMs) ?: break
            out.add(next to j)
            next = j.optString("nextSubPage", "")
        }
        return out
    }

    private val link = Regex("href=\"#([1-8][0-9]{2})(?:/[0-9]+)?\"")

    /** The pages an index links to from its body (lines 1–22), in reading order. */
    private fun storyLinks(content: String): List<String> =
        content.split('\n').drop(1).take(22).flatMap { line -> link.findAll(line).map { it.groupValues[1] } }.distinct()

    fun teletekst(cfg: BarConfig): JSONObject? {
        val o = try { if (cfg.raw.isEmpty()) JSONObject() else JSONObject(cfg.raw) } catch (_: Exception) { JSONObject() }
        val entries = entries(o)
        val interval = (o.optJSONObject("apps")?.optJSONObject("teletekst")?.optInt("interval", 20) ?: 20).coerceIn(8, 120)
        val shown = LinkedHashSet<String>()           // page numbers already in the rotation
        val configured = entries.map { it.page }.toSet()
        val pages = JSONArray()
        val missing = JSONArray()
        fun add(p: String, from: String?, maxAgeMs: Long): JSONObject? {
            if (!shown.add(p) || pages.length() >= MAX_PAGES) return null
            val subs = withSubpages(p, maxAgeMs)
            if (subs.isEmpty()) { if (from == null) missing.put(p); return null }
            subs.forEachIndexed { i, (id, j) ->
                if (pages.length() >= MAX_PAGES) return@forEachIndexed
                pages.put(JSONObject().put("id", id).put("page", p).put("sub", i + 1).put("subs", subs.size)
                    .put("from", nullable(from)).put("content", j.optString("content", "")))
            }
            return subs[0].second
        }
        for (e in entries) {
            val index = add(e.page, null, INDEX_AGE_MS) ?: continue
            if (!e.stories) continue
            // Stories that are themselves in the rotation keep their own place there.
            for (s in storyLinks(index.optString("content", "")).filter { it != e.page && it !in configured }.take(MAX_STORIES)) add(s, e.page, STORY_AGE_MS)
        }
        val out = JSONObject().put("pages", pages).put("missing", missing).put("interval", interval).put("at", System.currentTimeMillis() / 1000)
        if (pages.length() == 0) {
            if (missing.length() == entries.size) return out.put("error", "NOS Teletekst has none of these pages")
            return out.put("error", "NOS Teletekst did not answer")
        }
        return out
    }
}
