package nl.denoronha.deckhand.monitor

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
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
 * Full-screen kiosk WebView that shows Deckhand's monitor page.
 *
 * The page URL comes from (in order of precedence) the `url` intent extra, a UDP beacon
 * Deckhand broadcasts on port 5320, or the last URL remembered in SharedPreferences.
 * Whatever the source, only http(s) URLs whose host is a private (LAN) IPv4 address are
 * loaded, and the WebView never navigates away from that host.
 *
 * On-bar flavors (1.9: flights, crypto, weather, sky, news, verse; `BuildConfig.ON_BAR`) carry their page and
 * fetch their own data ([LocalSite]); for them the beacon only says where Deckhand is, so its `/config.json`
 * (place, units, coins, news source) can be picked up and kept. They work with the Mac off.
 *
 * A page that cannot be loaded (transport error or an HTTP error status on the main frame)
 * gives way to the "Looking for Deckhand…" page and is retried; a page whose beacons stop
 * for [BEACON_LOST_MS] gives way to it too, and the next beacon loads the page again.
 */
class MainActivity : Activity() {

    companion object {
        private const val TAG = "DeckhandMonitor"
        private const val BEACON_PORT = 5320
        private const val PREFS = "monitor"
        private const val PREF_URL = "lastUrl"
        private const val FALLBACK_DELAY_MS = 4_000L
        private const val RETRY_DELAY_MS = 5_000L
        private const val BEACON_LOST_MS = 60_000L   // Deckhand beacons every 5 s
        private const val LONG_PRESS_MS = 700L
        private const val CONFIG_EVERY_MS = 300_000L    // on-bar flavors: config.json from the Mac at most every 5 min
        private const val LOOKING_HTML = """<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>html,body{margin:0;height:100%;background:#000;color:#888;font:16px -apple-system,Roboto,sans-serif;
display:flex;align-items:center;justify-content:center;user-select:none}</style></head>
<body>Looking for Deckhand…</body></html>"""
    }

    private lateinit var web: WebView
    private val main = Handler(Looper.getMainLooper())

    private var currentUrl: String? = null      // the page we are showing / trying to show
    private var lastLoadFailed = false
    private var showingLookingPage = false
    private var errorInThisLoad = false       // main-frame error seen since the last onPageStarted of currentUrl

    private var beacon: BeaconListener? = null
    private val local: LocalSite? by lazy { if (BuildConfig.ON_BAR) LocalSite(applicationContext, BuildConfig.PAGE, BuildConfig.TITLE) else null }
    private var configAt = 0L
    private var multicastLock: WifiManager.MulticastLock? = null

    private val fallbackToRemembered = Runnable {
        if (currentUrl == null) {
            val remembered = prefs().getString(PREF_URL, null)?.takeIf { isLocalHttpUrl(it) }
            if (remembered != null) {
                Log.i(TAG, "No beacon yet, loading remembered url $remembered")
                load(remembered)
            }
        }
    }

    private val retry = Runnable {
        val url = currentUrl
        if (url != null && lastLoadFailed && !isFinishing && !isDestroyed) {
            Log.i(TAG, "Retrying $url")
            web.loadUrl(url)
        }
    }

    /**
     * No beacon for [BEACON_LOST_MS] while a page is shown: Deckhand is gone (quit, asleep,
     * other network), so show "Looking for Deckhand…" instead of a frozen page. The URL stays
     * remembered; the next beacon loads it again at once (see [onBeacon]). Armed by every
     * beacon and by onResume, cancelled in onPause/onDestroy.
     */
    private val beaconLost = Runnable {
        if (isFinishing || isDestroyed) return@Runnable
        if (currentUrl != null && !showingLookingPage) {
            Log.i(TAG, "No beacon for ${BEACON_LOST_MS / 1000} s, looking for Deckhand again")
            showLookingPage()
        }
    }

    private val longPressFinish = Runnable { finish() }

    // ---- lifecycle ---------------------------------------------------------------------------

    @SuppressLint("SetJavaScriptEnabled", "ClickableViewAccessibility")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        web = WebView(this).apply {
            setBackgroundColor(Color.BLACK)
            settings.apply {
                javaScriptEnabled = true
                domStorageEnabled = true
                // The pages are plain http on the LAN (cleartext is allowed in the manifest);
                // nothing legitimately mixes https and http, so never allow it.
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
        showLookingPage()

        if (local != null) load(LocalSite.ORIGIN + "/" + BuildConfig.PAGE) else loadFromIntent(intent)
    }

    override fun onNewIntent(intent: android.content.Intent?) {
        super.onNewIntent(intent)
        loadFromIntent(intent)
    }

    /** The `url` extra (adb / another app): same rules as a beacon, anything else is ignored. */
    private fun loadFromIntent(intent: android.content.Intent?) {
        if (local != null) return   // an on-bar page never loads anything else
        val url = intent?.getStringExtra("url")?.trim()?.takeIf { it.isNotEmpty() } ?: return
        if (isLocalHttpUrl(url)) {
            Log.i(TAG, "Loading url from intent extra: $url")
            load(url)
        } else {
            Log.w(TAG, "Ignoring url extra that is not a LAN http url: $url")
        }
    }

    override fun onResume() {
        super.onResume()
        hideSystemBars()
        acquireMulticastLock()
        startBeaconListener()
        web.onResume()
        if (currentUrl == null) {
            main.removeCallbacks(fallbackToRemembered)
            main.postDelayed(fallbackToRemembered, FALLBACK_DELAY_MS)
        } else if (lastLoadFailed) {
            main.removeCallbacks(retry)
            main.post(retry)
        }
        armBeaconLost()
    }

    override fun onPause() {
        main.removeCallbacks(fallbackToRemembered)
        main.removeCallbacks(retry)
        main.removeCallbacks(beaconLost)
        main.removeCallbacks(longPressFinish)
        stopBeaconListener()
        releaseMulticastLock()
        web.onPause()
        super.onPause()
    }

    override fun onDestroy() {
        main.removeCallbacksAndMessages(null)
        // Detach first: destroy() on a WebView that is still in the view tree logs a warning
        // and keeps the window's reference alive until the activity is gone.
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
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
            View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
            View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
            View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
            View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
            View.SYSTEM_UI_FLAG_FULLSCREEN
    }

    // ---- loading -----------------------------------------------------------------------------

    private fun prefs() = getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun showLookingPage() {
        showingLookingPage = true
        main.removeCallbacks(beaconLost)
        web.loadDataWithBaseURL(null, LOOKING_HTML, "text/html", "utf-8", null)
    }

    /** (Re)start the beacon-loss clock while a page is shown; a no-op on the looking page. */
    private fun armBeaconLost() {
        main.removeCallbacks(beaconLost)
        if (local != null) return   // the page does not depend on the Mac
        if (currentUrl != null && !showingLookingPage) main.postDelayed(beaconLost, BEACON_LOST_MS)
    }

    /**
     * Load [url] now and remember it. A no-op when [url] is already on screen; a page that
     * failed, or gave way to the looking page, is loaded again.
     */
    private fun load(url: String) {
        main.removeCallbacks(fallbackToRemembered)
        main.removeCallbacks(retry)
        if (url == currentUrl && !lastLoadFailed && !showingLookingPage) return
        if (url != currentUrl) prefs().edit().putString(PREF_URL, url).apply()
        currentUrl = url
        lastLoadFailed = false
        showingLookingPage = false
        web.loadUrl(url)
    }

    private fun onBeacon(url: String) {
        if (isFinishing || isDestroyed) return
        if (local != null) { fetchConfig(url); return }
        if (url != currentUrl) Log.i(TAG, "Beacon url $url")
        load(url)          // no-op while that page is already up; otherwise (re)load it now
        armBeaconLost()
    }

    /**
     * On-bar flavors: Deckhand is at the beacon's address, so ask it for `/config.json` (at most every 5 min) and
     * keep it. The beacon was already checked to name its own sender on the LAN (see [parseBeacon]).
     */
    private fun fetchConfig(beaconUrl: String) {
        val now = System.currentTimeMillis()
        if (now - configAt < CONFIG_EVERY_MS) return
        configAt = now
        val u = Uri.parse(beaconUrl)
        val base = "${u.scheme}://${u.host}${if (u.port > 0) ":" + u.port else ""}"
        pool.execute {
            val cfg = httpJson("$base/config.json", 5_000) ?: return@execute
            if (BarConfig.save(applicationContext, cfg)) {
                Log.i(TAG, "New settings from Deckhand at ${u.host}")
                local?.reloadConfig()
            }
        }
    }

    private inner class Client : WebViewClient() {
        /** On-bar flavors: every request to the private origin is answered by [LocalSite], never the network. */
        override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
            val site = local ?: return null
            return if (request.url.host == LocalSite.HOST) site.handle(request.url) else null
        }

        /** Kiosk: the page may only navigate within the host it was loaded from. */
        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
            val target = request.url
            val current = currentUrl?.let(Uri::parse)
            val allowed = current != null && target.scheme.isHttpScheme() &&
                target.host.equals(current.host, ignoreCase = true) && target.port == current.port
            if (!allowed) Log.w(TAG, "Blocked navigation to $target")
            return !allowed
        }

        override fun onPageStarted(view: WebView, url: String?, favicon: android.graphics.Bitmap?) {
            if (url != null && url == currentUrl) errorInThisLoad = false
        }

        override fun onPageFinished(view: WebView, url: String?) {
            if (url != null && url == currentUrl && !errorInThisLoad) {
                lastLoadFailed = false
                showingLookingPage = false
                main.removeCallbacks(retry)
            }
        }

        override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
            if (!request.isForMainFrame) return
            mainFrameFailed("error ${error.errorCode} ${error.description}", request.url)
        }

        /**
         * An HTTP error status on the main frame (403 from a Mac that refuses us, 503 while
         * "Serve the pages" is off, 404 for a page this Deckhand does not have) is a failure
         * like any other: show the looking page instead of the server's error body and retry.
         * Sub-resource errors (a 404 for data.json, a tile) are the page's own business.
         */
        override fun onReceivedHttpError(view: WebView, request: WebResourceRequest, errorResponse: WebResourceResponse) {
            if (!request.isForMainFrame) return
            mainFrameFailed("HTTP ${errorResponse.statusCode} ${errorResponse.reasonPhrase}", request.url)
        }

        private fun mainFrameFailed(what: String, url: Uri) {
            Log.w(TAG, "Main frame $what for $url")
            errorInThisLoad = true
            lastLoadFailed = true
            showLookingPage()
            main.removeCallbacks(retry)
            main.postDelayed(retry, RETRY_DELAY_MS)
        }
    }

    private inner class Bridge {
        @JavascriptInterface
        fun close() {
            main.post { finish() }
        }

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
                if (abs(event.x - downX) > slop || abs(event.y - downY) > slop) {
                    main.removeCallbacks(longPressFinish)
                }
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
            multicastLock = wifi.createMulticastLock(TAG).apply {
                setReferenceCounted(false)
                acquire()
            }
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
        try {
            beacon = BeaconListener().also { it.start() }
        } catch (e: Exception) {
            Log.w(TAG, "Beacon listener could not start", e)
        }
    }

    private fun stopBeaconListener() {
        beacon?.stop()
        beacon = null
    }

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
                    try {
                        socket.receive(packet)
                    } catch (_: SocketTimeoutException) {
                        continue
                    }
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
     * v2 beacons carry `base` (Deckhand's http root): open base + "/" + [BuildConfig.PAGE].
     * v1 beacons only carry `url`: open that as-is. The result must be a LAN http(s) URL
     * (see [isLocalHttpUrl]) whose host is the address the beacon came from: Deckhand always
     * names its own address, so a beacon that points elsewhere was not sent by Deckhand and is
     * dropped, instead of letting any host on the Wi-Fi put its own page on the bar.
     */
    private fun parseBeacon(text: String, from: InetAddress?): String? = try {
        val json = JSONObject(text.trim())
        if (json.optString("deckhand") != "monitor") null
        else {
            val base = json.optString("base").trimEnd('/')
            val url = if (base.isHttp()) "$base/${BuildConfig.PAGE}" else json.optString("url")
            val sender = from?.hostAddress
            url.takeIf { isLocalHttpUrl(it) && sender != null && Uri.parse(it).host == sender }.also {
                if (it == null) Log.w(TAG, "Ignoring beacon from $from: not a LAN url of the sender")
            }
        }
    } catch (_: Exception) {
        null
    }

    /**
     * True for `http(s)://<private IPv4>[:port]/...`: 10/8, 172.16/12, 192.168/16 or
     * 169.254/16. The pages are only ever served by the Mac on the LAN, so nothing else is
     * loaded, however it was handed to us.
     */
    private fun isLocalHttpUrl(url: String): Boolean {
        val uri = try { Uri.parse(url) } catch (_: Exception) { return false }
        if (local != null && uri.scheme == "https" && uri.host == LocalSite.HOST) return true
        if (!uri.scheme.isHttpScheme()) return false
        val host = uri.host ?: return false
        val parts = host.split('.')
        if (parts.size != 4) return false
        val o = parts.map { it.toIntOrNull() ?: return false }
        if (o.any { it !in 0..255 }) return false
        return o[0] == 10 ||
            (o[0] == 172 && o[1] in 16..31) ||
            (o[0] == 192 && o[1] == 168) ||
            (o[0] == 169 && o[1] == 254)
    }

    private fun String?.isHttpScheme() = this.equals("http", true) || this.equals("https", true)

    private fun String.isHttp() = startsWith("http://") || startsWith("https://")
}
