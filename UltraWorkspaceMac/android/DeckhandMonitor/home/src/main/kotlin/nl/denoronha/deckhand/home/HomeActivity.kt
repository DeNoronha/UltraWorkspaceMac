package nl.denoronha.deckhand.home

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.TextUtils
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import org.json.JSONObject
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.net.SocketTimeoutException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Deckhand Home: a home screen for the CoreBar's 1424×280 strip. Left, the clock and whether Deckhand's
 * beacon is heard; middle, one tile per installed app (Deckhand's own first); right, Settings and the bar's
 * own launcher. Nothing here talks to the Mac: the tiles are the apps the bar has, the beacon is only listened
 * to for the status line. The bar's launcher keeps running underneath (it still serves the cube uploads and the
 * module bus), so switching between the two homes is a one-line `cmd package set-home-activity` either way.
 */
class HomeActivity : Activity() {

    companion object {
        private const val TAG = "DeckhandHome"
        private const val BEACON_PORT = 5320
        private const val BEACON_LOST_MS = 20_000L      // Deckhand beacons every 5 s
        private const val OUR_PREFIX = "nl.denoronha.deckhand."
        private const val VENDOR_LAUNCHER = "com.ultrabar.launch"
        private const val VENDOR_HOME = "com.ultrabar.launch.ui.activity.MainActivity"
        private const val SETTINGS_PACKAGE = "com.android.settings"
        /** Pinned on the right, so they are left out of the scrolling row. */
        private val PINNED = setOf(SETTINGS_PACKAGE, VENDOR_LAUNCHER)
        private val OUR_ORDER = listOf("monitor", "claude", "crypto", "weather", "music", "calendar", "flights", "sky", "news", "verse", "tasks")

        private const val BG = 0xFF000000.toInt()
        private const val TILE = 0xFF15171C.toInt()
        private const val TILE_PRESSED = 0xFF2A2E38.toInt()
        private const val INK = 0xFFE6E6E6.toInt()
        private const val INK_DIM = 0xFF8A8F99.toInt()
        private const val GREEN = 0xFF34C759.toInt()
    }

    private val main = Handler(Looper.getMainLooper())
    private lateinit var clock: TextView
    private lateinit var date: TextView
    private lateinit var status: TextView
    private lateinit var dot: View
    private lateinit var tiles: LinearLayout
    private lateinit var pinned: LinearLayout

    private var beacon: BeaconListener? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private var deckhandHost: String? = null

    private val tick = object : Runnable {
        override fun run() {
            val now = Date()
            clock.text = SimpleDateFormat("HH:mm", Locale.getDefault()).format(now)
            date.text = SimpleDateFormat("EEEE d MMMM", Locale.getDefault()).format(now)
            main.postDelayed(this, 60_000 - (System.currentTimeMillis() % 60_000))
        }
    }

    private val beaconLost = Runnable { setDeckhand(null) }

    private val packages = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) { populate() }
    }

    // ---- lifecycle ---------------------------------------------------------------------------

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(buildLayout())
        registerReceiver(packages, IntentFilter().apply {
            addAction(Intent.ACTION_PACKAGE_ADDED); addAction(Intent.ACTION_PACKAGE_REMOVED); addAction(Intent.ACTION_PACKAGE_CHANGED)
            addDataScheme("package")
        })
        populate()
    }

    override fun onDestroy() {
        main.removeCallbacksAndMessages(null)
        try { unregisterReceiver(packages) } catch (_: Exception) {}
        super.onDestroy()
    }

    override fun onResume() {
        super.onResume()
        hideSystemBars()
        main.removeCallbacks(tick); main.post(tick)
        acquireMulticastLock()
        startBeaconListener()
        setDeckhand(deckhandHost)         // re-arm the loss timer; a beacon within 20 s confirms it
        populate()
    }

    override fun onPause() {
        main.removeCallbacks(tick)
        main.removeCallbacks(beaconLost)
        stopBeaconListener()
        releaseMulticastLock()
        super.onPause()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemBars()
    }

    /** The home screen is the bottom of the stack: Back does nothing here. */
    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {}

    @Suppress("DEPRECATION")
    private fun hideSystemBars() {
        window.decorView.systemUiVisibility =
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
            View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
            View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_FULLSCREEN
    }

    // ---- layout ------------------------------------------------------------------------------

    private fun dp(v: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).toInt()

    private fun buildLayout(): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setBackgroundColor(BG)
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(24), dp(12), dp(16), dp(12))
        }

        // Left: clock, date, Deckhand status
        val left = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(dp(300), LinearLayout.LayoutParams.MATCH_PARENT)
        }
        clock = TextView(this).apply {
            setTextColor(INK); textSize = 72f; typeface = Typeface.create("sans-serif-light", Typeface.NORMAL)
            includeFontPadding = false; letterSpacing = -0.02f
        }
        date = TextView(this).apply { setTextColor(INK_DIM); textSize = 20f }
        val statusRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(10), 0, 0)
        }
        dot = View(this).apply {
            background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(INK_DIM) }
            layoutParams = LinearLayout.LayoutParams(dp(10), dp(10)).apply { rightMargin = dp(8) }
        }
        status = TextView(this).apply { setTextColor(INK_DIM); textSize = 16f; text = getString(R.string.deckhand_off) }
        statusRow.addView(dot); statusRow.addView(status)
        left.addView(clock); left.addView(date); left.addView(statusRow)
        root.addView(left)

        // Middle: the app tiles, scrolling sideways
        tiles = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        val scroller = HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            overScrollMode = View.OVER_SCROLL_NEVER
            addView(tiles)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f)
        }
        root.addView(scroller)

        // Right: Settings and the bar's own launcher, always reachable, as the same tiles as every other app
        pinned = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.MATCH_PARENT).apply { leftMargin = dp(12) }
        }
        val right = pinned
        root.addView(right)
        return root
    }

    private fun tileBackground() = android.graphics.drawable.StateListDrawable().apply {
        fun rounded(color: Int) = GradientDrawable().apply { cornerRadius = dp(18).toFloat(); setColor(color) }
        addState(intArrayOf(android.R.attr.state_pressed), rounded(TILE_PRESSED))
        addState(intArrayOf(), rounded(TILE))
    }

    /** One app tile: icon over a two-line label, 150 × 230 dp, pressed state, long press opens App info. */
    private fun appTile(info: ResolveInfo, labelOverride: String? = null, gap: Boolean = true): View {
        val pm = packageManager
        val label = labelOverride ?: info.loadLabel(pm).toString()
        val tile = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER
            background = tileBackground()
            layoutParams = LinearLayout.LayoutParams(dp(150), dp(230)).apply { if (gap) rightMargin = dp(12) }
            isClickable = true; isFocusable = true
            contentDescription = label
        }
        tile.addView(ImageView(this).apply {
            setImageDrawable(info.loadIcon(pm))
            layoutParams = LinearLayout.LayoutParams(dp(112), dp(112))
        })
        tile.addView(TextView(this).apply {
            text = label; setTextColor(INK); textSize = 18f; gravity = Gravity.CENTER
            maxLines = 2; ellipsize = TextUtils.TruncateAt.END
            setPadding(dp(8), dp(10), dp(8), 0)
        })
        val component = ComponentName(info.activityInfo.packageName, info.activityInfo.name)
        tile.setOnClickListener {
            launch(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER).setComponent(component)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED))
        }
        tile.setOnLongClickListener {
            launch(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + component.packageName)))
            true
        }
        return tile
    }

    private fun launch(intent: Intent) {
        try { startActivity(intent) } catch (e: Exception) { Log.w(TAG, "Cannot start $intent", e) }
    }

    /** Every LAUNCHER activity except this one: Deckhand's pages first in their known order, then the rest by label. */
    private fun populate() {
        val pm = packageManager
        val all = pm.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), 0)
            .filter { it.activityInfo.packageName != packageName }
        populatePinned(all)
        fun rank(r: ResolveInfo): Int {
            val p = r.activityInfo.packageName
            if (!p.startsWith(OUR_PREFIX)) return 1000
            val i = OUR_ORDER.indexOf(p.removePrefix(OUR_PREFIX))
            return if (i >= 0) i else 100
        }
        val sorted = all.filter { it.activityInfo.packageName !in PINNED }.sortedWith(compareBy<ResolveInfo> { rank(it) }.thenBy { it.loadLabel(pm).toString().lowercase() })
        tiles.removeAllViews()
        if (sorted.isEmpty()) {
            tiles.addView(TextView(this).apply { text = getString(R.string.no_apps); setTextColor(INK_DIM); textSize = 18f })
            return
        }
        for (r in sorted) tiles.addView(appTile(r))
    }

    /** Settings, then the bar's own launcher (labelled UltraBar), each left out when the bar does not have it. */
    private fun populatePinned(all: List<ResolveInfo>) {
        pinned.removeAllViews()
        val settings = all.firstOrNull { it.activityInfo.packageName == SETTINGS_PACKAGE }
        val vendor = all.firstOrNull { it.activityInfo.packageName == VENDOR_LAUNCHER && it.activityInfo.name == VENDOR_HOME }
            ?: all.firstOrNull { it.activityInfo.packageName == VENDOR_LAUNCHER }
        settings?.let { pinned.addView(appTile(it, getString(R.string.settings), gap = vendor != null)) }
        vendor?.let { pinned.addView(appTile(it, getString(R.string.ultrabar), gap = false)) }
    }

    // ---- Deckhand status (beacon) --------------------------------------------------------------

    private fun setDeckhand(host: String?) {
        deckhandHost = host
        main.removeCallbacks(beaconLost)
        if (host != null) {
            status.text = getString(R.string.deckhand_on, host); status.setTextColor(INK)
            (dot.background as GradientDrawable).setColor(GREEN)
            main.postDelayed(beaconLost, BEACON_LOST_MS)
        } else {
            status.text = getString(R.string.deckhand_off); status.setTextColor(INK_DIM)
            (dot.background as GradientDrawable).setColor(INK_DIM)
        }
    }

    private fun acquireMulticastLock() {
        if (multicastLock != null) return
        try {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicastLock = wifi.createMulticastLock(TAG).apply { setReferenceCounted(false); acquire() }
        } catch (e: Exception) { Log.w(TAG, "MulticastLock unavailable", e) }
    }

    private fun releaseMulticastLock() {
        try { multicastLock?.takeIf { it.isHeld }?.release() } catch (_: Exception) {}
        multicastLock = null
    }

    private fun startBeaconListener() {
        if (beacon != null) return
        try { beacon = BeaconListener().also { it.start() } } catch (e: Exception) { Log.w(TAG, "Beacon listener could not start", e) }
    }

    private fun stopBeaconListener() { beacon?.stop(); beacon = null }

    /** Listens on UDP 5320 for Deckhand's beacon and reports the sender; the page URL itself is not used here. */
    private inner class BeaconListener {
        private val socket = DatagramSocket(null)
        private val thread = Thread(::run, "deckhand-beacon").apply { isDaemon = true }
        fun start() = thread.start()
        fun stop() { thread.interrupt(); try { socket.close() } catch (_: Exception) {} }
        private fun run() {
            try {
                socket.reuseAddress = true; socket.broadcast = true; socket.soTimeout = 1_000
                socket.bind(InetSocketAddress(BEACON_PORT))
                val buf = ByteArray(2048); val packet = DatagramPacket(buf, buf.size)
                while (!Thread.currentThread().isInterrupted && !socket.isClosed) {
                    packet.setLength(buf.size)
                    try { socket.receive(packet) } catch (_: SocketTimeoutException) { continue }
                    val text = String(packet.data, packet.offset, packet.length, Charsets.UTF_8)
                    val ok = try { JSONObject(text.trim()).optString("deckhand") == "monitor" } catch (_: Exception) { false }
                    val from = packet.address?.hostAddress
                    if (ok && from != null) main.post { if (!isFinishing && !isDestroyed) setDeckhand(from) }
                }
            } catch (e: Exception) {
                if (!Thread.currentThread().isInterrupted && !socket.isClosed) Log.w(TAG, "Beacon listener stopped", e)
            } finally { try { socket.close() } catch (_: Exception) {} }
        }
    }
}
