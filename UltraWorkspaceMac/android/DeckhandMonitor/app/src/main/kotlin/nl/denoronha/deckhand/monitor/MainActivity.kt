package nl.denoronha.deckhand.monitor

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.view.WindowManager
import android.webkit.JavascriptInterface
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import nl.denoronha.deckhand.monitor.onbar.BarConfig
import nl.denoronha.deckhand.monitor.onbar.LocalSite
import nl.denoronha.deckhand.monitor.onbar.httpJson
import nl.denoronha.deckhand.monitor.onbar.pool
import org.json.JSONObject
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.SocketTimeoutException
import kotlin.math.abs

/**
 * Full-screen kiosk WebView for one Deckhand page on the CoreBar (1424×280).
 *
 * Since 1.9 every flavor carries its page (the Mac app's own page files, packaged as assets) and shows it at once
 * from `https://deckhand.invalid/<page>`, answered by [LocalSite]; nothing is ever loaded from anywhere else.
 *
 * - On-bar flavors (flights, crypto, weather, sky, news, verse; `BuildConfig.ON_BAR`) fetch their own data and
 *   work with the Mac off. Deckhand only gives them their settings: pushed over adb (see `onbar/ConfigReceiver`),
 *   or fetched here as `/config.json` when the beacon is heard.
 * - Mac flavors (monitor, claude, music, calendar, tasks) show what only the Mac knows; [LocalSite] passes their
 *   data requests to Deckhand's data API at the address the beacon names. Without a Mac the page says
 *   "Waiting for the Mac…" by itself and fills in as soon as a beacon arrives.
 *
 * The beacon (UDP 5320, every 5 s from Deckhand) is only accepted when it names its own sender on a private LAN
 * address. The last address is remembered, so a Mac page works straight after a restart of the app. The `url`
 * intent extra sets the address by hand (adb testing), under the same rule.
 */
class MainActivity : Activity() {

    companion object {
        private const val TAG = "DeckhandMonitor"
        private const val BEACON_PORT = 5320
        private const val PREFS = "monitor"
        private const val PREF_BASE = "macBase"
        private const val RETRY_DELAY_MS = 5_000L
        private const val LONG_PRESS_MS = 700L
        private const val CONFIG_EVERY_MS = 300_000L    // on-bar flavors: config.json from the Mac at most every 5 min
    }

    private lateinit var web: WebView
    private val main = Handler(Looper.getMainLooper())
    private val site by lazy { LocalSite(applicationContext, BuildConfig.PAGE, BuildConfig.TITLE) }
    private val pageUrl = LocalSite.ORIGIN + "/" + BuildConfig.PAGE

    private var beacon: BeaconListener? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private var configAt = 0L

    private val reload = Runnable { if (!isFinishing && !isDestroyed) web.loadUrl(pageUrl) }
    private val longPressFinish = Runnable { finish() }

    // ---- lifecycle ---------------------------------------------------------------------------

    @SuppressLint("SetJavaScriptEnabled", "ClickableViewAccessibility")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        web = WebView(this).apply {
            setBackgroundColor(Color.parseColor("#1c2029"))
            settings.apply {
                javaScriptEnabled = true
                domStorageEnabled = true
                mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
                cacheMode = WebSettings.LOAD_NO_CACHE
                mediaPlaybackRequiresUserGesture = false
                useWideViewPort = true
                loadWithOverviewMode = true
                setSupportZoom(false)
                builtInZoomControls = false
                displayZoomControls = false
            }
            addJavascriptInterface(Bridge(), "Deckhand")
            webViewClient = Client()
            setOnTouchListener { _, event -> onWebTouch(event); false }
            isVerticalScrollBarEnabled = false
            isHorizontalScrollBarEnabled = false
        }
        setContentView(web)

        site.macBase = prefs().getString(PREF_BASE, null)?.takeIf { isLanHttpUrl(it) }
        baseFromIntent(intent)
        web.loadUrl(pageUrl)
    }

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        baseFromIntent(intent)
    }

    /** The `url` extra (adb testing): a Deckhand address on the LAN, e.g. http://192.168.50.207:7432 or any page URL on it. */
    private fun baseFromIntent(intent: Intent?) {
        val url = intent?.getStringExtra("url")?.trim()?.takeIf { it.isNotEmpty() } ?: return
        if (isLanHttpUrl(url)) setMac(baseOf(url)) else Log.w(TAG, "Ignoring url extra that is not a LAN http url: $url")
    }

    override fun onResume() {
        super.onResume()
        hideSystemBars()
        acquireMulticastLock()
        startBeaconListener()
        web.onResume()
    }

    override fun onPause() {
        main.removeCallbacks(reload)
        main.removeCallbacks(longPressFinish)
        stopBeaconListener()
        releaseMulticastLock()
        web.onPause()
        super.onPause()
    }

    override fun onDestroy() {
        main.removeCallbacksAndMessages(null)
        (web.parent as? ViewGroup)?.removeView(web)
        web.stopLoading()
        web.destroy()
        super.onDestroy()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemBars()
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        finish()
    }

    @Suppress("DEPRECATION")
    private fun hideSystemBars() {
        window.decorView.systemUiVisibility =
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
            View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
            View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_FULLSCREEN
    }

    private fun prefs() = getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    // ---- Deckhand's address --------------------------------------------------------------------

    private fun baseOf(url: String): String {
        val u = Uri.parse(url)
        return "${u.scheme}://${u.host}${if (u.port > 0) ":" + u.port else ""}"
    }

    /** A beacon (or the url extra) named Deckhand at [base]: Mac pages ask it for data, on-bar pages for settings. */
    private fun setMac(base: String) {
        if (base != site.macBase) {
            Log.i(TAG, "Deckhand at $base")
            site.macBase = base
            prefs().edit().putString(PREF_BASE, base).apply()
        }
        if (BuildConfig.ON_BAR) fetchConfig(base)
    }

    /** On-bar flavors: Deckhand's settings document, at most every 5 min (the adb push is the fast path). */
    private fun fetchConfig(base: String) {
        val now = System.currentTimeMillis()
        if (now - configAt < CONFIG_EVERY_MS) return
        configAt = now
        pool.execute {
            val cfg = httpJson("$base/config.json", 5_000) ?: return@execute
            if (cfg.optInt("v", 0) >= 2 && BarConfig.save(applicationContext, cfg)) {
                Log.i(TAG, "New settings from Deckhand at $base")
                site.reloadConfig()
            }
        }
    }

    private fun onBeacon(url: String) {
        if (isFinishing || isDestroyed) return
        setMac(baseOf(url))
    }

    // ---- WebView ---------------------------------------------------------------------------------

    private inner class Client : WebViewClient() {
        /** Every request to the private origin is answered by [LocalSite], never the network. */
        override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? =
            if (request.url.host == LocalSite.HOST) site.handle(request.url, request.method ?: "GET") else null

        /** Kiosk: the page never navigates anywhere. */
        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
            val ok = request.url.scheme == "https" && request.url.host == LocalSite.HOST
            if (!ok) Log.w(TAG, "Blocked navigation to ${request.url}")
            return !ok
        }

        /** The page is local, so this should never happen; if it does, try again shortly instead of a blank screen. */
        override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
            if (!request.isForMainFrame) return
            Log.w(TAG, "Main frame error ${error.errorCode} ${error.description}")
            main.removeCallbacks(reload); main.postDelayed(reload, RETRY_DELAY_MS)
        }
    }

    private inner class Bridge {
        @JavascriptInterface
        fun close() { main.post { finish() } }

        @JavascriptInterface
        fun version(): String = BuildConfig.VERSION_NAME
    }

    // ---- long press anywhere finishes -------------------------------------------------------

    private var downX = 0f
    private var downY = 0f

    private fun onWebTouch(event: MotionEvent) {
        val slop = ViewConfiguration.get(this).scaledTouchSlop
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = event.x; downY = event.y
                main.removeCallbacks(longPressFinish)
                main.postDelayed(longPressFinish, LONG_PRESS_MS)
            }
            MotionEvent.ACTION_MOVE -> {
                if (abs(event.x - downX) > slop || abs(event.y - downY) > slop) main.removeCallbacks(longPressFinish)
            }
            MotionEvent.ACTION_POINTER_DOWN, MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL ->
                main.removeCallbacks(longPressFinish)
        }
    }

    // ---- beacon listener --------------------------------------------------------------------

    private fun acquireMulticastLock() {
        if (multicastLock != null) return
        try {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicastLock = wifi.createMulticastLock(TAG).apply { setReferenceCounted(false); acquire() }
        } catch (e: Exception) {
            Log.w(TAG, "MulticastLock unavailable", e)
        }
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

    /**
     * One UDP listener on port 5320. Owns its socket, so stopping an old listener can never
     * close the socket of a newer one (onPause/onResume in quick succession).
     */
    private inner class BeaconListener {
        private val socket = DatagramSocket(null)
        private val thread = Thread(::run, "deckhand-beacon").apply { isDaemon = true }

        fun start() = thread.start()

        fun stop() {
            thread.interrupt()
            try { socket.close() } catch (_: Exception) {}
        }

        private fun run() {
            try {
                socket.reuseAddress = true
                socket.broadcast = true
                socket.soTimeout = 1_000
                socket.bind(InetSocketAddress(BEACON_PORT))
                val buf = ByteArray(2048)
                val packet = DatagramPacket(buf, buf.size)
                while (!Thread.currentThread().isInterrupted && !socket.isClosed) {
                    packet.setLength(buf.size)
                    try { socket.receive(packet) } catch (_: SocketTimeoutException) { continue }
                    val text = String(packet.data, packet.offset, packet.length, Charsets.UTF_8)
                    val url = parseBeacon(text, packet.address) ?: continue
                    main.post { onBeacon(url) }
                }
            } catch (e: Exception) {
                if (!Thread.currentThread().isInterrupted && !socket.isClosed) Log.w(TAG, "Beacon listener stopped", e)
            } finally {
                try { socket.close() } catch (_: Exception) {}
            }
        }
    }

    /**
     * `{"deckhand":"monitor","v":2,"base":"http://<mac>:7432","url":…}` → Deckhand's address. The address must be
     * a LAN http(s) URL whose host is the beacon's sender: Deckhand always names itself, so anything else is a
     * forged beacon and is dropped.
     */
    private fun parseBeacon(text: String, from: InetAddress?): String? = try {
        val json = JSONObject(text.trim())
        if (json.optString("deckhand") != "monitor") null
        else {
            val base = json.optString("base").trimEnd('/').ifEmpty { json.optString("url") }
            val sender = from?.hostAddress
            base.takeIf { isLanHttpUrl(it) && sender != null && Uri.parse(it).host == sender }.also {
                if (it == null) Log.w(TAG, "Ignoring beacon from $from: not a LAN url of the sender")
            }
        }
    } catch (_: Exception) {
        null
    }

    /** True for `http(s)://<private IPv4>[:port]/...`: 10/8, 172.16/12, 192.168/16 or 169.254/16. */
    private fun isLanHttpUrl(url: String): Boolean {
        val uri = try { Uri.parse(url) } catch (_: Exception) { return false }
        if (!(uri.scheme.equals("http", true) || uri.scheme.equals("https", true))) return false
        val parts = (uri.host ?: return false).split('.')
        if (parts.size != 4) return false
        val o = parts.map { it.toIntOrNull() ?: return false }
        if (o.any { it !in 0..255 }) return false
        return o[0] == 10 || (o[0] == 172 && o[1] in 16..31) || (o[0] == 192 && o[1] == 168) || (o[0] == 169 && o[1] == 254)
    }
}
