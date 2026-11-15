package nl.denoronha.deckhand.home

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Base64
import android.util.Log
import org.json.JSONObject
import java.net.URL
import java.security.MessageDigest
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import kotlin.math.abs

/**
 * Which Mac Home trusts (1.6), the same rule as the bar apps' `onbar/MacLink`: Deckhand pushes its address and a
 * random per-bar key over adb (`am broadcast -a nl.denoronha.deckhand.CONFIG -p nl.denoronha.deckhand.home --es
 * config64 …`, the `mac` section; [ConfigReceiver] is guarded by `android.permission.DUMP`, so only the shell user can
 * send it). A beacon counts only when it is signed with that key, and `/home/glance.json` is asked with the key.
 */
internal object MacLink {
    private const val PREFS = "maclink"
    const val HEADER = "X-Deckhand-Key"
    private const val MAX_SKEW_S = 600L

    fun base(ctx: Context): String? = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("base", null)
    fun key(ctx: Context): String? = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("key", null)

    fun save(ctx: Context, mac: JSONObject): Boolean {
        val base = mac.optString("base").trimEnd('/')
        val key = mac.optString("key").lowercase()
        if (!isLanHttp(base) || !key.matches(Regex("^[0-9a-f]{64}$"))) return false
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString("base", base).putString("key", key).apply()
        return true
    }

    /** The beacon's `base` when it is signed with [key] and recent (or names [pinned]), else null. */
    fun verify(json: JSONObject, key: String?, pinned: String?, nowS: Long = System.currentTimeMillis() / 1000): String? {
        if (key == null) return null
        val base = json.optString("base").trimEnd('/')
        val ts = json.optLong("ts", -1)
        val sig = json.optString("sig").lowercase()
        if (ts < 0 || sig.length != 64) return null
        val want = hmacHex(key, "deckhand-beacon|$base|$ts")
        if (!MessageDigest.isEqual(want.toByteArray(), sig.toByteArray())) return null
        return base.takeIf { abs(nowS - ts) <= MAX_SKEW_S || it == pinned }
    }

    private fun hmacHex(keyHex: String, msg: String): String {
        val keyBytes = ByteArray(keyHex.length / 2) { keyHex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(keyBytes, "HmacSHA256"))
        return mac.doFinal(msg.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
    }

    private fun isLanHttp(s: String): Boolean {
        val u = try { URL(s) } catch (_: Exception) { return false }
        if (u.protocol != "http") return false
        val o = u.host.split('.').map { it.toIntOrNull() ?: return false }
        if (o.size != 4 || o.any { it !in 0..255 }) return false
        return o[0] == 10 || (o[0] == 172 && o[1] in 16..31) || (o[0] == 192 && o[1] == 168) || (o[0] == 169 && o[1] == 254)
    }
}

/** Deckhand's config broadcast; Home only keeps the `mac` section (address and key). */
class ConfigReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val b64 = intent.getStringExtra("config64") ?: return
        val json = try { JSONObject(String(Base64.decode(b64, Base64.DEFAULT), Charsets.UTF_8)) } catch (_: Exception) { return }
        val mac = json.optJSONObject("mac") ?: return
        if (MacLink.save(context, mac)) Log.i("DeckhandHome", "Deckhand's address and key pushed")
    }
}
