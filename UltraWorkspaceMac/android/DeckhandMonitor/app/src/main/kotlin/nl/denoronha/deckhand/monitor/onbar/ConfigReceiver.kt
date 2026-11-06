package nl.denoronha.deckhand.monitor.onbar

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Base64
import android.util.Log
import org.json.JSONObject

/**
 * Deckhand pushes the bar apps' configuration over the debug bridge:
 *
 *     am broadcast -a nl.denoronha.deckhand.CONFIG -p <package> --es config64 <base64 of the JSON>
 *
 * The manifest guards this receiver with `android.permission.DUMP`, which the shell user has and no ordinary
 * app can get, so only `adb shell` (that is, Deckhand) can set the configuration. The document is stored as is;
 * [BarConfig.load] reads it, clamping every value, and the page follows on its next data request.
 */
class ConfigReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val b64 = intent.getStringExtra("config64") ?: return
        val json = try { JSONObject(String(Base64.decode(b64, Base64.DEFAULT), Charsets.UTF_8)) } catch (e: Exception) {
            Log.w(TAG, "Ignoring a config push that is not JSON"); return
        }
        if (json.optInt("v", 0) < 2) { Log.w(TAG, "Ignoring a config push without v2"); return }
        if (BarConfig.save(context, json)) Log.i(TAG, "New settings pushed by Deckhand")
    }
}
