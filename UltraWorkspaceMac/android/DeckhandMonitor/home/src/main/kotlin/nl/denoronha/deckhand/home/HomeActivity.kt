package nl.denoronha.deckhand.home

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.BitmapDrawable
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
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.URL
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.net.SocketTimeoutException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Deckhand Home: a home screen for the CoreBar's 1424×280 strip. Left, the clock and whether Deckhand's
 * beacon is heard; then one tile per installed app (Deckhand's own first), scrolling sideways, with Settings and
 * the bar's own launcher as the last two. The tiles are the apps the bar has. While Deckhand's beacon is heard,
 * the Deckhand apps' tiles are live: once a minute Home asks the Mac that sent the beacon for `/home/glance.json`
 * (a short line per app, a count badge, the temperature) and draws it on the tiles; the Calendar icon shows
 * today's date on its own. Without the Mac the tiles are plain. The bar's launcher keeps running underneath (it still serves the cube uploads and the
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
        /** Always the last two tiles of the row, so they are left out of the sorted part. */
        private val LAST = setOf(SETTINGS_PACKAGE, VENDOR_LAUNCHER)
        private val OUR_ORDER = listOf("monitor", "claude", "crypto", "weather", "music", "calendar", "flights", "sky", "news", "verse", "tasks", "haven", "tide", "teletekst", "schiphol", "strava", "cask")

        private const val BG = 0xFF000000.toInt()
        private const val TILE = 0xFF15171C.toInt()
        private const val TILE_PRESSED = 0xFF2A2E38.toInt()
        private const val INK = 0xFFE6E6E6.toInt()
        private const val INK_DIM = 0xFF8A8F99.toInt()
        private const val GREEN = 0xFF34C759.toInt()
        private const val RED = 0xFFFF453A.toInt()
        private const val ORANGE = 0xFFFF9F0A.toInt()
        private const val BLUE = 0xFF64D2FF.toInt()
        private const val GLANCE_EVERY_MS = 60_000L
        /** A line older than this (the Mac stopped answering) is taken off the tile. */
        private const val GLANCE_STALE_MS = 5 * 60_000L
    }

    /** The parts of a Deckhand app's tile that the live data changes. */
    private class Live(val icon: ImageView, val line: TextView, val badge: TextView, val temp: TextView)
    private val live = HashMap<String, Live>()          // by page id ("cask", "haven", …)
    private var glance: JSONObject? = null
    private var glanceAt = 0L
    private var deckhandBase: String? = null

    private val main = Handler(Looper.getMainLooper())
    private lateinit var clock: TextView
    private lateinit var date: TextView
    private lateinit var status: TextView
    private lateinit var dot: View
    private lateinit var tiles: LinearLayout

    private var beacon: BeaconListener? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private var deckhandHost: String? = null

    private val tick = object : Runnable {
        override fun run() {
            val now = Date()
            clock.text = SimpleDateFormat("HH:mm", Locale.getDefault()).format(now)
            date.text = SimpleDateFormat("EEEE d MMMM", Locale.getDefault()).format(now)
            live["calendar"]?.icon?.setImageDrawable(calendarIcon(now))   // a new day turns the page
            main.postDelayed(this, 60_000 - (System.currentTimeMillis() % 60_000))
        }
    }

    private val beaconLost = Runnable { setDeckhand(null) }

    /** Ask the Mac for the tiles' live data, once a minute while Home is on screen. */
    private val glancePoll = object : Runnable {
        override fun run() {
            fetchGlance()
            main.postDelayed(this, GLANCE_EVERY_MS)
        }
    }

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
        main.removeCallbacks(glancePoll); main.post(glancePoll)
    }

    override fun onPause() {
        main.removeCallbacks(tick)
        main.removeCallbacks(beaconLost)
        main.removeCallbacks(glancePoll)
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
        val pkg = info.activityInfo.packageName
        val page = if (pkg.startsWith(OUR_PREFIX)) pkg.removePrefix(OUR_PREFIX) else null
        // The icon with room around it for a count badge (top right) and the temperature (bottom).
        val iconBox = FrameLayout(this).apply { layoutParams = LinearLayout.LayoutParams(dp(124), dp(118)) }
        val icon = ImageView(this).apply {
            setImageDrawable(if (page == "calendar") calendarIcon(Date()) else info.loadIcon(pm))
            layoutParams = FrameLayout.LayoutParams(dp(112), dp(112), Gravity.CENTER)
        }
        val badge = TextView(this).apply {
            setTextColor(Color.WHITE); textSize = 15f; typeface = Typeface.DEFAULT_BOLD; gravity = Gravity.CENTER
            minWidth = dp(30); setPadding(dp(8), 0, dp(8), 0)
            background = GradientDrawable().apply { cornerRadius = dp(15).toFloat(); setColor(RED); setStroke(dp(2), TILE) }
            layoutParams = FrameLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(30), Gravity.TOP or Gravity.END)
            visibility = View.GONE
        }
        val temp = TextView(this).apply {
            setTextColor(Color.WHITE); textSize = 20f; typeface = Typeface.DEFAULT_BOLD; gravity = Gravity.CENTER
            setPadding(dp(10), 0, dp(10), 0)
            background = GradientDrawable().apply { cornerRadius = dp(15).toFloat(); setColor(0xCC000000.toInt()) }
            layoutParams = FrameLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(32), Gravity.BOTTOM or Gravity.END).apply { rightMargin = dp(2) }
            visibility = View.GONE
        }
        iconBox.addView(icon); iconBox.addView(badge); iconBox.addView(temp)
        tile.addView(iconBox)
        tile.addView(TextView(this).apply {
            text = label; setTextColor(INK); textSize = 18f; gravity = Gravity.CENTER
            maxLines = 2; ellipsize = TextUtils.TruncateAt.END
            setPadding(dp(8), dp(6), dp(8), 0)
        })
        val line = TextView(this).apply {
            setTextColor(INK_DIM); textSize = 15f; gravity = Gravity.CENTER
            maxLines = 1; ellipsize = TextUtils.TruncateAt.END
            setPadding(dp(8), dp(2), dp(8), 0)
            visibility = View.GONE
        }
        tile.addView(line)
        if (page != null) live[page] = Live(icon, line, badge, temp)
        val component = ComponentName(pkg, info.activityInfo.name)
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

    /** Every LAUNCHER activity except this one: Deckhand's pages first in their known order, then the rest by label,
     *  and Settings and the bar's own launcher at the end of the row. */
    private fun populate() {
        val pm = packageManager
        val all = pm.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), 0)
            .filter { it.activityInfo.packageName != packageName }
        fun rank(r: ResolveInfo): Int {
            val p = r.activityInfo.packageName
            if (!p.startsWith(OUR_PREFIX)) return 1000
            val i = OUR_ORDER.indexOf(p.removePrefix(OUR_PREFIX))
            return if (i >= 0) i else 100
        }
        val sorted = all.filter { it.activityInfo.packageName !in LAST }.sortedWith(compareBy<ResolveInfo> { rank(it) }.thenBy { it.loadLabel(pm).toString().lowercase() })
        tiles.removeAllViews()
        live.clear()
        if (sorted.isEmpty()) tiles.addView(TextView(this).apply { text = getString(R.string.no_apps); setTextColor(INK_DIM); textSize = 18f })
        for (r in sorted) tiles.addView(appTile(r))
        addLastTiles(all)
        applyGlance()
    }

    // ---- live tiles ----------------------------------------------------------------------------

    /** Calendar's icon: a page with the weekday on a red band and the day of the month, like a desk calendar. */
    private fun calendarIcon(now: Date): BitmapDrawable {
        val size = dp(112)
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val c = Canvas(bmp)
        val p = Paint(Paint.ANTI_ALIAS_FLAG)
        val r = size * 0.2f
        val box = RectF(0f, 0f, size.toFloat(), size.toFloat())
        p.color = Color.WHITE; c.drawRoundRect(box, r, r, p)
        c.save(); c.clipRect(0f, 0f, size.toFloat(), size * 0.3f)
        p.color = 0xFFE5413A.toInt(); c.drawRoundRect(box, r, r, p); c.restore()
        p.textAlign = Paint.Align.CENTER
        p.color = Color.WHITE; p.typeface = Typeface.DEFAULT_BOLD; p.textSize = size * 0.17f
        c.drawText(SimpleDateFormat("EEE", Locale.getDefault()).format(now).uppercase(Locale.getDefault()).trimEnd('.'), size / 2f, size * 0.22f, p)
        p.color = 0xFF1C1C1E.toInt(); p.typeface = Typeface.create("sans-serif-light", Typeface.NORMAL); p.textSize = size * 0.56f
        c.drawText(SimpleDateFormat("d", Locale.getDefault()).format(now), size / 2f, size * 0.86f, p)
        return BitmapDrawable(resources, bmp)
    }

    /** GET `/home/glance.json` from the Mac that sent the beacon, off the main thread. */
    private fun fetchGlance() {
        val base = deckhandBase
        if (base == null) { if (System.currentTimeMillis() - glanceAt > GLANCE_STALE_MS) { glance = null; applyGlance() }; return }
        Thread({
            val json = try {
                val conn = URL("$base/home/glance.json").openConnection() as HttpURLConnection
                conn.connectTimeout = 3_000; conn.readTimeout = 3_000; conn.useCaches = false
                MacLink.key(applicationContext)?.let { conn.setRequestProperty(MacLink.HEADER, it) }
                try {
                    if (conn.responseCode != 200 || conn.contentLength > 262_144) null
                    else JSONObject(String(conn.inputStream.use { it.readNBytesCompat(262_144) }, Charsets.UTF_8))
                } finally { conn.disconnect() }
            } catch (e: Exception) { Log.d(TAG, "glance: ${e.message}"); null }
            main.post {
                if (isFinishing || isDestroyed) return@post
                if (json != null) { glance = json; glanceAt = System.currentTimeMillis() }
                else if (System.currentTimeMillis() - glanceAt > GLANCE_STALE_MS) glance = null
                applyGlance()
            }
        }, "deckhand-glance").apply { isDaemon = true }.start()
    }

    /** Put the last answer on the tiles; a tile the answer does not mention goes back to its plain look. */
    private fun applyGlance() {
        val apps = glance?.optJSONObject("apps")
        for ((page, v) in live) {
            val g = apps?.optJSONObject(page)
            val text = g?.optString("line").orEmpty()
            v.line.text = text
            v.line.visibility = if (text.isEmpty()) View.GONE else View.VISIBLE
            v.line.setTextColor(when (g?.optString("tone")) { "up" -> GREEN; "down" -> RED; "warn" -> ORANGE; "live" -> BLUE; else -> INK_DIM })
            val n = g?.optInt("badge", 0) ?: 0
            v.badge.text = if (n > 99) "99+" else n.toString()
            v.badge.visibility = if (n > 0) View.VISIBLE else View.GONE
            val t = g?.optString("temp").orEmpty()
            v.temp.text = t
            v.temp.visibility = if (t.isEmpty()) View.GONE else View.VISIBLE
        }
    }

    /** Settings, then the bar's own launcher (labelled UltraBar), each left out when the bar does not have it. */
    private fun addLastTiles(all: List<ResolveInfo>) {
        val settings = all.firstOrNull { it.activityInfo.packageName == SETTINGS_PACKAGE }
        val vendor = all.firstOrNull { it.activityInfo.packageName == VENDOR_LAUNCHER && it.activityInfo.name == VENDOR_HOME }
            ?: all.firstOrNull { it.activityInfo.packageName == VENDOR_LAUNCHER }
        settings?.let { tiles.addView(appTile(it, getString(R.string.settings), gap = vendor != null)) }
        vendor?.let { tiles.addView(appTile(it, getString(R.string.ultrabar), gap = false)) }
    }

    // ---- Deckhand status (beacon) --------------------------------------------------------------

    private fun setDeckhand(host: String?, base: String? = deckhandBase) {
        val first = host != null && deckhandHost == null
        deckhandHost = host
        deckhandBase = if (host != null) base else null
        if (first) { main.removeCallbacks(glancePoll); main.post(glancePoll) }   // live tiles as soon as the Mac is heard
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

    /** At most [max] bytes of the stream (the glance is a few hundred bytes). */
    private fun java.io.InputStream.readNBytesCompat(max: Int): ByteArray {
        val out = java.io.ByteArrayOutputStream(); val buf = ByteArray(8192)
        while (out.size() < max) { val n = read(buf, 0, minOf(buf.size, max - out.size())); if (n < 0) break; out.write(buf, 0, n) }
        return out.toByteArray()
    }

    /** The beacon's `base` URL, only when it is plain http to the very address that sent it and that address is on the
     *  local network: a packet from elsewhere cannot point Home at another server. Since 1.6 the beacon must also be
     *  signed with the key Deckhand pushed over adb ([MacLink]), checked before this. */
    private fun safeBase(base: String, from: InetAddress): String? {
        if (!(from.isSiteLocalAddress || from.isLoopbackAddress || from.isLinkLocalAddress)) return null
        val u = try { URL(base) } catch (_: Exception) { return null }
        if (u.protocol != "http" || u.host != from.hostAddress || u.port !in 1..65535) return null
        return "http://${u.host}:${u.port}"
    }

    /** Listens on UDP 5320 for Deckhand's beacon and reports the sender and the base URL of its data server. */
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
                    val obj = try { JSONObject(text.trim()) } catch (_: Exception) { null }
                    val from = packet.address
                    // Only a beacon signed with the pushed key counts (no key pushed yet: none does).
                    val signed = obj?.takeIf { it.optString("deckhand") == "monitor" }
                        ?.let { MacLink.verify(it, MacLink.key(applicationContext), MacLink.base(applicationContext)) }
                    if (signed != null && from != null) {
                        val base = safeBase(signed, from) ?: continue
                        main.post { if (!isFinishing && !isDestroyed) setDeckhand(from.hostAddress, base) }
                    }
                }
            } catch (e: Exception) {
                if (!Thread.currentThread().isInterrupted && !socket.isClosed) Log.w(TAG, "Beacon listener stopped", e)
            } finally { try { socket.close() } catch (_: Exception) {} }
        }
    }
}
