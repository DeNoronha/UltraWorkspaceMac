package nl.denoronha.deckhand.monitor.onbar

import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.time.OffsetDateTime
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap

/**
 * Cloud Status: whether the big cloud services are up, from their own public status pages (no key, nothing about
 * the user is sent). The services to show come from `apps.status.services` in the config (ids, in order, at most
 * twelve; unknown ids are ignored, an empty list means the defaults). Per service:
 *
 *  - m365: status.cloud.microsoft `api/posts/mac` (one post; Status "Available" = fine, Message is HTML) and
 *    `api/posts/m365Consumer` (Outlook.com, Teams Free, Copilot, …; anything not "Operational" is named).
 *  - azure: `api/posts/azure` (as above) and the RSS feed of azure.status.microsoft (an `<item>` per active incident).
 *  - aws: the RSS feed of status.aws.amazon.com. An item per update; the guid names the service and region
 *    (`#ec2-us-east-1_1794754409`). Per service and region the newest item counts: an issue when it is less than six
 *    hours old and is not "Service is operating normally" / "[RESOLVED]".
 *  - gcp, workspace: Google's `incidents.json` (all incidents of the last year); active = `end` is null.
 *  - slack: `api/v2.0.0/current` (`status`, `active_incidents`).
 *  - Statuspage sites (GitHub, Cloudflare, Claude, OpenAI, Atlassian, Zoom, …): `api/v2/status.json` (200 bytes);
 *    only when its indicator is not "none" also `api/v2/incidents/unresolved.json`, or `summary.json` where that
 *    does not exist (OpenAI's page is incident.io's, which answers 404 there; its summary is a few kB). Never
 *    Cloudflare's summary.json, which is over 200 kB.
 *
 * Gentle on the status pages: each service is checked at most every 3 or 5 minutes, and only while the app is open
 * (the [Feed] asks every minute while the page polls). Requests go one at a time, a quarter of a second apart, and
 * send If-None-Match / If-Modified-Since from the last answer, so an unchanged 290 kB incidents.json costs a 304.
 * A failed check keeps the last answer; after 30 minutes without one the service shows as "unknown".
 */
internal object StatusFeed {
    private const val GAP_MS = 250L
    private const val SHORT_MS = 3 * 60_000L
    private const val LONG_MS = 5 * 60_000L
    private const val UNKNOWN_AFTER_MS = 30 * 60_000L
    private const val MAX = 12
    private const val DETAIL_MAX = 400

    private enum class Kind { M365, AZURE, AWS, GOOGLE, SLACK, STATUSPAGE }
    private class Svc(val id: String, val name: String, val kind: Kind, val base: String, val ageMs: Long)

    private val known = listOf(
        Svc("m365", "Microsoft 365", Kind.M365, "https://status.cloud.microsoft/api/posts/", SHORT_MS),
        Svc("azure", "Azure", Kind.AZURE, "https://status.cloud.microsoft/api/posts/", SHORT_MS),
        Svc("aws", "AWS", Kind.AWS, "https://status.aws.amazon.com/rss/all.rss", LONG_MS),
        Svc("gcp", "Google Cloud", Kind.GOOGLE, "https://status.cloud.google.com/incidents.json", LONG_MS),
        Svc("workspace", "Google Workspace", Kind.GOOGLE, "https://www.google.com/appsstatus/dashboard/incidents.json", LONG_MS),
        Svc("github", "GitHub", Kind.STATUSPAGE, "https://www.githubstatus.com", SHORT_MS),
        Svc("cloudflare", "Cloudflare", Kind.STATUSPAGE, "https://www.cloudflarestatus.com", SHORT_MS),
        Svc("slack", "Slack", Kind.SLACK, "https://status.slack.com/api/v2.0.0/current", SHORT_MS),
        Svc("zoom", "Zoom", Kind.STATUSPAGE, "https://www.zoomstatus.com", SHORT_MS),
        Svc("atlassian", "Atlassian", Kind.STATUSPAGE, "https://status.atlassian.com", SHORT_MS),
        Svc("claude", "Claude", Kind.STATUSPAGE, "https://status.claude.com", SHORT_MS),
        Svc("openai", "OpenAI", Kind.STATUSPAGE, "https://status.openai.com", SHORT_MS),
        Svc("digitalocean", "DigitalOcean", Kind.STATUSPAGE, "https://status.digitalocean.com", SHORT_MS),
        Svc("vercel", "Vercel", Kind.STATUSPAGE, "https://www.vercel-status.com", SHORT_MS),
        Svc("netlify", "Netlify", Kind.STATUSPAGE, "https://www.netlifystatus.com", SHORT_MS),
        Svc("npm", "npm", Kind.STATUSPAGE, "https://status.npmjs.org", SHORT_MS),
    )
    private val byId = known.associateBy { it.id }
    private val defaults = listOf("m365", "azure", "aws", "gcp", "workspace", "github", "cloudflare", "slack", "zoom", "atlassian", "claude", "openai")

    /** The ids from `apps.status.services`: known ones, once each, at most twelve; the defaults without any. */
    fun services(o: JSONObject): List<String> {
        val arr = o.optJSONObject("apps")?.optJSONObject("status")?.optJSONArray("services") ?: return defaults
        val out = (0 until arr.length()).map { arr.optString(it, "").trim().lowercase() }.filter { it in byId }.distinct().take(MAX)
        return out.ifEmpty { defaults }
    }

    // --- HTTP: one request at a time, conditional, keeping the last body of every URL

    private class Doc(val body: String, val etag: String?, val modified: String?)
    private val docs = ConcurrentHashMap<String, Doc>()
    private var lastRequest = 0L

    private sealed class Answer { class Ok(val body: String) : Answer(); object Missing : Answer(); object Failed : Answer() }

    @Synchronized private fun get(url: String, accept: String = "application/json"): Answer {
        val wait = lastRequest + GAP_MS - System.currentTimeMillis()
        if (wait > 0) Thread.sleep(wait)
        lastRequest = System.currentTimeMillis()
        val old = docs[url]
        return try {
            val c = URL(url).openConnection() as HttpURLConnection
            c.connectTimeout = 8_000; c.readTimeout = 12_000
            c.instanceFollowRedirects = true
            c.setRequestProperty("User-Agent", USER_AGENT)
            c.setRequestProperty("Accept", accept)
            old?.etag?.let { c.setRequestProperty("If-None-Match", it) }
            old?.modified?.let { c.setRequestProperty("If-Modified-Since", it) }
            try {
                val code = c.responseCode
                when {
                    code == 304 && old != null -> Answer.Ok(old.body)
                    code in 200..299 -> {
                        val body = c.inputStream.use { i -> ByteArrayOutputStream().also { i.copyTo(it) }.toString("UTF-8") }
                        docs[url] = Doc(body, c.getHeaderField("ETag"), c.getHeaderField("Last-Modified"))
                        Answer.Ok(body)
                    }
                    code == 404 -> Answer.Missing
                    else -> { Log.w(TAG, "GET $url → HTTP $code"); Answer.Failed }
                }
            } finally { c.disconnect() }
        } catch (e: Exception) {
            Log.w(TAG, "GET $url failed: ${e.message}"); Answer.Failed
        }
    }
    private fun body(url: String, accept: String = "application/json"): String? = (get(url, accept) as? Answer.Ok)?.body

    // --- one service's state

    /** What a check found: state ok|minor|major|maintenance, and for an issue its title, detail, start and part. */
    private class State(val state: String, val title: String? = null, val detail: String? = null, val since: Long? = null, val part: String? = null)
    private class Result(val state: State, val checkedAt: Long)
    private val results = ConcurrentHashMap<String, Result>()
    private val triedAt = ConcurrentHashMap<String, Long>()

    fun status(cfg: BarConfig): JSONObject {
        val o = try { if (cfg.raw.isEmpty()) JSONObject() else JSONObject(cfg.raw) } catch (_: Exception) { JSONObject() }
        val ids = services(o)
        val out = JSONArray()
        var issues = 0
        for (id in ids) {
            val s = byId[id] ?: continue
            val now = System.currentTimeMillis()
            if (now - (triedAt[id] ?: 0L) >= s.ageMs) {
                triedAt[id] = now
                val st = try { check(s) } catch (e: Exception) { Log.w(TAG, "status $id failed", e); null }
                if (st != null) results[id] = Result(st, System.currentTimeMillis())
            }
            val r = results[id]
            val j = JSONObject().put("id", id).put("name", s.name)
            if (r == null || System.currentTimeMillis() - r.checkedAt > UNKNOWN_AFTER_MS) {
                j.put("state", "unknown")
                r?.let { j.put("checked", it.checkedAt / 1000) }
            } else {
                val st = r.state
                j.put("state", st.state).put("checked", r.checkedAt / 1000)
                st.title?.let { j.put("title", it) }
                st.detail?.let { j.put("detail", it) }
                st.since?.let { j.put("since", it / 1000) }
                st.part?.let { j.put("part", it) }
                if (st.state == "minor" || st.state == "major") issues++
            }
            out.put(j)
        }
        return JSONObject().put("at", System.currentTimeMillis() / 1000).put("issues", issues).put("clock24h", cfg.clock24h).put("services", out)
    }

    private fun check(s: Svc): State? = when (s.kind) {
        Kind.M365 -> m365(s.base)
        Kind.AZURE -> azure(s.base)
        Kind.AWS -> aws(s.base)
        Kind.GOOGLE -> google(s.base)
        Kind.SLACK -> slack(s.base)
        Kind.STATUSPAGE -> statuspage(s.base)
    }

    /** "Available" is fine; the rest is an issue, an outage or interruption a major one. */
    private fun postState(status: String): String = when {
        status.equals("Available", true) || status.equals("Operational", true) -> "ok"
        Regex("outage|interruption|unavailable", RegexOption.IGNORE_CASE).containsMatchIn(status) -> "major"
        else -> "minor"
    }

    private fun m365(base: String): State? {
        val mac = body(base + "mac")?.let { JSONObject(it) } ?: return null
        val consumer = body(base + "m365Consumer")?.let { JSONArray(it) } ?: return null
        val macState = postState(mac.optString("Status", "Available"))
        if (macState != "ok") {
            val msg = plain(mac.optString("Message", ""))
            return State(macState, mac.optString("Title", "").ifBlank { null }?.let(::plain) ?: firstSentence(msg), clip(msg), iso(mac.optString("AuthoredDateTime", "")), "Microsoft 365")
        }
        val bad = (0 until consumer.length()).mapNotNull { consumer.optJSONObject(it) }.filter { postState(it.optString("Status", "Operational")) != "ok" }
        if (bad.isEmpty()) return State("ok")
        val first = bad[0]
        val names = bad.map { it.optString("ServiceDisplayName", "").removeSuffix(" (Consumer)") }.filter { it.isNotBlank() }
        val msg = plain(first.optString("Message", ""))
        val title = plain(first.optString("Title", "")).ifBlank { null } ?: firstSentence(msg) ?: (names.firstOrNull() ?: "Microsoft 365") + " has an issue"
        return State(if (bad.any { postState(it.optString("Status")) == "major" }) "major" else "minor", title, clip(msg),
            iso(first.optString("AuthoredDateTime", "")), names.take(2).joinToString(", ") + if (names.size > 2) " +${names.size - 2}" else "")
    }

    private fun azure(base: String): State? {
        val post = body(base + "azure")?.let { JSONObject(it) } ?: return null
        val rss = body("https://azure.status.microsoft/en-us/status/feed/", "application/rss+xml, application/xml") ?: return null
        val items = rssItems(rss)
        if (items.isNotEmpty()) {
            val i = items[0]
            val more = if (items.size > 1) " (and ${items.size - 1} more)" else ""
            return State("minor", i.title + more, clip(i.description), i.date, null)
        }
        val st = postState(post.optString("Status", "Available"))
        if (st == "ok") return State("ok")
        val msg = plain(post.optString("Message", ""))
        return State(st, firstSentence(msg) ?: "Azure has an issue", clip(msg), iso(post.optString("AuthoredDateTime", "")))
    }

    private fun aws(url: String): State? {
        val rss = body(url, "application/rss+xml, application/xml") ?: return null
        val now = System.currentTimeMillis()
        // The newest item per service and region; the guid ends in "#<service>-<region>_<epoch>".
        val newest = LinkedHashMap<String, RssItem>()
        for (i in rssItems(rss)) {
            val key = i.guid.substringAfterLast('#').substringBeforeLast('_')
            val prev = newest[key]
            if (prev == null || (i.date ?: 0) > (prev.date ?: 0)) newest[key] = i
        }
        val open = newest.entries.filter { (_, i) ->
            val d = i.date ?: return@filter false
            now - d < 6 * 3_600_000L && !i.title.startsWith("Service is operating normally", true) && !i.title.contains("[RESOLVED]", true)
        }.sortedByDescending { it.value.date }
        if (open.isEmpty()) return State("ok")
        val (key, i) = open[0]
        val region = Regex("[a-z]{2}(?:-gov)?-[a-z]+-[0-9]").find(key)?.value
        val title = i.title.replace(Regex("^(Informational message|Service degradation|Service disruption|Service impact):\\s*", RegexOption.IGNORE_CASE), "")
        val more = if (open.size > 1) " (and ${open.size - 1} more)" else ""
        return State(if (i.title.startsWith("Service disruption", true)) "major" else "minor", title + more, clip(i.description), i.date, region)
    }

    private fun google(url: String): State? {
        val all = body(url)?.let { JSONArray(it) } ?: return null
        val active = (0 until all.length()).mapNotNull { all.optJSONObject(it) }.filter { it.isNull("end") }
        if (active.isEmpty()) return State("ok")
        fun major(x: JSONObject) = x.optString("severity") == "high" || x.optString("status_impact") == "SERVICE_OUTAGE"
        val i = active.sortedWith(compareByDescending<JSONObject> { major(it) }.thenByDescending { it.optString("begin") })[0]
        val desc = markdown(i.optString("external_desc", ""))
        val update = markdown(i.optJSONObject("most_recent_update")?.optString("text", "") ?: "")
        val locs = i.optJSONArray("currently_affected_locations")
        val loc = if (locs != null && locs.length() > 0) locs.optJSONObject(0)?.optString("id", "")?.ifBlank { null } else null
        val names = active.map { it.optString("service_name", "") }.filter { it.isNotBlank() }.distinct()
        val part = (names.take(2).joinToString(", ") + if (names.size > 2) " +${names.size - 2}" else "").ifBlank { null }
            ?.let { if (loc != null && names.size == 1) "$it · $loc" else it }
        return State(if (active.any { major(it) }) "major" else "minor", firstSentence(desc) ?: (names.firstOrNull() ?: "An incident"),
            clip(summary(update).ifBlank { desc }), iso(i.optString("begin", "")), part)
    }

    private fun slack(url: String): State? {
        val o = body(url)?.let { JSONObject(it) } ?: return null
        val list = o.optJSONArray("active_incidents") ?: JSONArray()
        if (o.optString("status", "ok") == "ok" && list.length() == 0) return State("ok")
        val i = list.optJSONObject(0)
        val types = (0 until list.length()).map { list.optJSONObject(it)?.optString("type", "") ?: "" }
        val state = when {
            types.any { it == "outage" } -> "major"
            types.isNotEmpty() && types.all { it == "maintenance" } -> "maintenance"
            else -> "minor"
        }
        val services = i?.optJSONArray("services")?.strings()?.filter { it.isNotBlank() }
        return State(state, i?.optString("title", "")?.ifBlank { null } ?: "Slack has an issue", null,
            i?.let { iso(it.optString("date_created", "")) }, services?.take(2)?.joinToString(", ")?.ifBlank { null })
    }

    /** Statuspage-style pages without `unresolved.json` (incident.io's, such as OpenAI's): asked for `summary.json` straight away. */
    private val noUnresolved: MutableSet<String> = ConcurrentHashMap.newKeySet()

    private fun statuspage(base: String): State? {
        val st = body("$base/api/v2/status.json")?.let { JSONObject(it) }?.optJSONObject("status") ?: return null
        val indicator = st.optString("indicator", "none")
        if (indicator == "none") return State("ok")
        val state = when (indicator) { "major", "critical" -> "major"; "maintenance" -> "maintenance"; else -> "minor" }
        val incidents = when (val r = if (base in noUnresolved) Answer.Missing else get("$base/api/v2/incidents/unresolved.json")) {
            is Answer.Ok -> JSONObject(r.body).optJSONArray("incidents")
            is Answer.Missing -> { noUnresolved.add(base); body("$base/api/v2/summary.json")?.let { JSONObject(it).optJSONArray("incidents") } }
            is Answer.Failed -> null
        }
        val i = incidents?.optJSONObject(0) ?: return State(state, st.optString("description", "").ifBlank { null })
        val comps = i.optJSONArray("components")?.let { a -> (0 until a.length()).mapNotNull { a.optJSONObject(it)?.optString("name") } }?.filter { it.isNotBlank() } ?: emptyList()
        val more = if (incidents.length() > 1) " (and ${incidents.length() - 1} more)" else ""
        val update = i.optJSONArray("incident_updates")?.optJSONObject(0)?.optString("body", "") ?: ""
        val started = i.optString("started_at", "").takeIf { it.isNotBlank() && it != "null" } ?: i.optString("created_at", "")
        return State(state, i.optString("name", "").ifBlank { st.optString("description") } + more, clip(plain(update)), iso(started),
            (comps.take(2).joinToString(", ") + if (comps.size > 2) " +${comps.size - 2}" else "").ifBlank { null })
    }

    // --- text helpers

    private class RssItem(val title: String, val description: String, val guid: String, val date: Long?)
    private val rfc822 = ThreadLocal.withInitial { SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss zzz", Locale.US) }

    private fun rssItems(xml: String): List<RssItem> = Regex("<item>(.*?)</item>", RegexOption.DOT_MATCHES_ALL).findAll(xml).map { m ->
        val s = m.groupValues[1]
        fun tag(t: String) = Regex("<$t[^>]*>(.*?)</$t>", RegexOption.DOT_MATCHES_ALL).find(s)?.groupValues?.get(1)?.trim()
            ?.removePrefix("<![CDATA[")?.removeSuffix("]]>")?.trim() ?: ""
        val date = tag("pubDate").let { d ->
            if (d.isBlank()) null else try { rfc822.get()!!.parse(d.replace(Regex(" Z$"), " GMT"))?.time } catch (_: Exception) { null }
        }
        RssItem(plain(tag("title")), plain(tag("description")), tag("guid"), date)
    }.toList()

    private fun iso(s: String): Long? = if (s.isBlank() || s.startsWith("0001")) null else try { OffsetDateTime.parse(s).toInstant().toEpochMilli() } catch (_: Exception) { null }

    /** HTML (or escaped HTML) → one line of plain text. */
    private fun plain(html: String): String = html
        .replace("&lt;", "<").replace("&gt;", ">")
        .replace(Regex("<br\\s*/?>|</p>|</div>|</li>", RegexOption.IGNORE_CASE), " ")
        .replace(Regex("<[^>]+>"), "")
        .replace("&nbsp;", " ").replace("&quot;", "\"").replace("&#39;", "'").replace("&apos;", "'").replace("&amp;", "&")
        .replace(Regex("\\s+"), " ").trim()

    /** Google's markdown (`**Summary:**` headings) → plain text. */
    private fun markdown(s: String): String = s.replace("**", "").replace(Regex("\\s+"), " ").trim()

    /** Google's updates start "Summary: … Description: …": the description is what helps on a small screen. */
    private fun summary(s: String): String {
        val d = Regex("Description:\\s*(.*?)(?:\\s+(?:Symptoms|Workaround|Diagnosis):|$)", RegexOption.IGNORE_CASE).find(s)?.groupValues?.get(1)?.trim()
        return if (!d.isNullOrBlank()) d else s.removePrefix("Summary:").trim()
    }

    private fun firstSentence(s: String): String? {
        val t = s.removePrefix("Summary:").trim()
        if (t.isBlank()) return null
        val end = Regex("[.!?](\\s|$)").find(t)?.range?.first
        return (if (end != null && end < 140) t.substring(0, end) else t).take(140)
    }

    private fun clip(s: String): String? = if (s.isBlank()) null else if (s.length <= DETAIL_MAX) s else s.take(DETAIL_MAX - 1).trimEnd() + "…"
}
