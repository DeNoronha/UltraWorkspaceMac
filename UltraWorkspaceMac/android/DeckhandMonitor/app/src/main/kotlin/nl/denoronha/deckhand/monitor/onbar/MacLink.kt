package nl.denoronha.deckhand.monitor.onbar

import android.content.Context
import android.net.Uri
import org.json.JSONObject
import java.security.MessageDigest
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import kotlin.math.abs

/**
 * Which Mac this app trusts (2.4): Deckhand pushes its address and a random per-bar key over adb, in the `mac`
 * section of the config broadcast (`{"mac":{"base":"http://<mac>:7432","key":"<64 hex>"}}`, see [ConfigReceiver];
 * only the shell user can send it). With that key the app
 *
 *  - accepts a beacon only when it carries `sig = HMAC-SHA256(key, "deckhand-beacon|<base>|<ts>")` (hex), with `ts`
 *    within 10 minutes of the bar's clock or `base` equal to the pushed address, so another host on the Wi-Fi can no
 *    longer point the app at a server of its own;
 *  - sends the key as `X-Deckhand-Key` on every request to the Mac, which answers nothing without it.
 *
 * Without a pushed key no beacon is accepted at all: the page waits until Deckhand has pushed one.
 */
internal object MacLink {
    private const val PREFS = "maclink"
    private const val KEY_BASE = "base"
    private const val KEY_KEY = "key"
    const val HEADER = "X-Deckhand-Key"
    private const val MAX_SKEW_S = 600L

    fun base(ctx: Context): String? = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_BASE, null)
    fun key(ctx: Context): String? = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_KEY, null)

    /** Store the `mac` section of a pushed config; returns true when it was valid. */
    fun save(ctx: Context, mac: JSONObject): Boolean {
        val base = mac.optString("base").trimEnd('/')
        val key = mac.optString("key").lowercase()
        if (!isLanHttpUrl(base) || !key.matches(Regex("^[0-9a-f]{64}$"))) return false
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY_BASE, base).putString(KEY_KEY, key).apply()
        return true
    }

    /** The headers for a request to the Mac (empty while no key was pushed). */
    fun headers(ctx: Context): Map<String, String> = key(ctx)?.let { mapOf(HEADER to it) } ?: emptyMap()

    /** A beacon's `base` when it is signed with [key] and recent (or names [pinned]), else null. */
    fun verify(json: JSONObject, key: String?, pinned: String?, nowS: Long = System.currentTimeMillis() / 1000): String? {
        if (key == null) return null
        val base = json.optString("base").trimEnd('/')
        val ts = json.optLong("ts", -1)
        val sig = json.optString("sig").lowercase()
        if (!isLanHttpUrl(base) || ts < 0 || sig.length != 64) return null
        val want = hmacHex(key, "deckhand-beacon|$base|$ts")
        if (!MessageDigest.isEqual(want.toByteArray(), sig.toByteArray())) return null
        return base.takeIf { abs(nowS - ts) <= MAX_SKEW_S || it == pinned }
    }

    fun hmacHex(keyHex: String, msg: String): String {
        val keyBytes = ByteArray(keyHex.length / 2) { keyHex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(keyBytes, "HmacSHA256"))
        return mac.doFinal(msg.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
    }

    /** True for `http(s)://<private IPv4>[:port]/...`: 10/8, 172.16/12, 192.168/16 or 169.254/16. */
    fun isLanHttpUrl(url: String): Boolean {
        val uri = try { Uri.parse(url) } catch (_: Exception) { return false }
        if (!(uri.scheme.equals("http", true) || uri.scheme.equals("https", true))) return false
        val parts = (uri.host ?: return false).split('.')
        if (parts.size != 4) return false
        val o = parts.map { it.toIntOrNull() ?: return false }
        if (o.any { it !in 0..255 }) return false
        return o[0] == 10 || (o[0] == 172 && o[1] in 16..31) || (o[0] == 192 && o[1] == 168) || (o[0] == 169 && o[1] == 254)
    }
}
