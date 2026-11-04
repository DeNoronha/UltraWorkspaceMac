package nl.denoronha.deckhand.monitor

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.graphics.Color
import android.net.wifi.WifiManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.webkit.JavascriptInterface
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import org.json.JSONObject
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.net.SocketTimeoutException
import kotlin.math.abs

/**
 * Full-screen kiosk WebView that shows Deckhand's monitor page.
 *
 * The page URL comes from (in order of precedence) the `url` intent extra, a UDP beacon
 * Deckhand broadcasts on port 5320, or the last URL remembered in SharedPreferences.
 */
class MainActivity : Activity() {

    companion object {
        private const val TAG = "DeckhandMonitor"
        private const val BEACON_PORT = 5320
        private const val PREFS = "monitor"
        private const val PREF_URL = "lastUrl"
        private const val FALLBACK_DELAY_MS = 4_000L
        private const val RETRY_DELAY_MS = 5_000L
        private const val LONG_PRESS_MS = 700L
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

    private var beaconThread: Thread? = null
    private var beaconSocket: DatagramSocket? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    private val fallbackToRemembered = Runnable {
        if (currentUrl == null) {
            val remembered = prefs().getString(PREF_URL, null)
            if (remembered != null) {
                Log.i(TAG, "No beacon yet, loading remembered url $remembered")
                load(remembered)
            }
        }
    }

    private val retry = Runnable {
        val url = currentUrl
        if (url != null && lastLoadFailed) {
            Log.i(TAG, "Retrying $url")
            web.loadUrl(url)
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
            setLayerType(View.LAYER_TYPE_HARDWARE, null)
            settings.apply {
                javaScriptEnabled = true
                domStorageEnabled = true
                mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
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

        intent?.getStringExtra("url")?.takeIf { it.isNotBlank() }?.let {
            Log.i(TAG, "Loading url from intent extra: $it")
            load(it)
        }
    }

    override fun onNewIntent(intent: android.content.Intent?) {
        super.onNewIntent(intent)
        intent?.getStringExtra("url")?.takeIf { it.isNotBlank() }?.let { load(it) }
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
    }

    override fun onPause() {
        main.removeCallbacks(fallbackToRemembered)
        main.removeCallbacks(retry)
        main.removeCallbacks(longPressFinish)
        stopBeaconListener()
        releaseMulticastLock()
        web.onPause()
        super.onPause()
    }

    override fun onDestroy() {
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
        web.loadDataWithBaseURL(null, LOOKING_HTML, "text/html", "utf-8", null)
    }

    /** Load [url] now (or re-load it if it previously failed) and remember it. */
    private fun load(url: String) {
        main.removeCallbacks(fallbackToRemembered)
        main.removeCallbacks(retry)
        prefs().edit().putString(PREF_URL, url).apply()
        if (url == currentUrl && !lastLoadFailed && !showingLookingPage) return
        currentUrl = url
        lastLoadFailed = false
        showingLookingPage = false
        web.loadUrl(url)
    }

    private fun onBeacon(url: String) {
        if (url != currentUrl) {
            Log.i(TAG, "Beacon url $url")
            load(url)
        } else if (lastLoadFailed) {
            load(url)
        }
    }

    private inner class Client : WebViewClient() {
        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean = false

        override fun onPageFinished(view: WebView, url: String?) {
            if (!lastLoadFailed && url != null && url == currentUrl) showingLookingPage = false
        }

        override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
            if (!request.isForMainFrame) return
            Log.w(TAG, "Main frame error ${error.errorCode} ${error.description} for ${request.url}")
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
        fun version(): String =
            try { packageManager.getPackageInfo(packageName, 0).versionName ?: "" } catch (_: Exception) { "" }
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
        if (beaconThread != null) return
        val thread = Thread({
            var socket: DatagramSocket? = null
            try {
                socket = DatagramSocket(null).apply {
                    reuseAddress = true
                    broadcast = true
                    soTimeout = 1_000
                    bind(InetSocketAddress(BEACON_PORT))
                }
                beaconSocket = socket
                val buf = ByteArray(2048)
                val packet = DatagramPacket(buf, buf.size)
                while (!Thread.currentThread().isInterrupted) {
                    try {
                        socket.receive(packet)
                    } catch (_: SocketTimeoutException) {
                        continue
                    }
                    val text = String(packet.data, packet.offset, packet.length, Charsets.UTF_8)
                    val url = parseBeacon(text) ?: continue
                    main.post { onBeacon(url) }
                }
            } catch (e: Exception) {
                if (!Thread.currentThread().isInterrupted) Log.w(TAG, "Beacon listener stopped", e)
            } finally {
                try { socket?.close() } catch (_: Exception) {}
            }
        }, "deckhand-beacon")
        thread.isDaemon = true
        beaconThread = thread
        thread.start()
    }

    private fun stopBeaconListener() {
        beaconThread?.interrupt()
        try { beaconSocket?.close() } catch (_: Exception) {}
        beaconSocket = null
        beaconThread = null
    }

    private fun parseBeacon(text: String): String? = try {
        val json = JSONObject(text.trim())
        if (json.optString("deckhand") != "monitor") null
        else json.optString("url").takeIf { it.startsWith("http://") || it.startsWith("https://") }
    } catch (_: Exception) {
        null
    }
}
