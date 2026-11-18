package app.unbound.client

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.core.content.ContextCompat
import androidx.core.content.IntentCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import app.unbound.client.input.KeyMapper
import app.unbound.client.input.TouchInputHandler
import app.unbound.client.net.AccessoryChannel
import app.unbound.client.net.Channel
import app.unbound.client.net.CodecConfig
import app.unbound.client.net.MacDiscovery
import app.unbound.client.net.Messages
import app.unbound.client.net.StreamClient
import app.unbound.client.net.TcpChannel
import app.unbound.client.net.Wire
import app.unbound.client.video.VideoDecoder
import java.io.IOException
import java.util.UUID

class MainActivity : ComponentActivity(), StreamClient.Listener, VideoDecoder.Listener, SurfaceHolder.Callback {

    /** What we're connected (or trying to connect) to. */
    private sealed interface Target {
        data class Usb(val accessory: UsbAccessory) : Target
        data class Tcp(val host: String, val port: Int, val name: String?) : Target
    }

    private val main = Handler(Looper.getMainLooper())
    private val prefs by lazy { getSharedPreferences("unbound", Context.MODE_PRIVATE) }
    private val usbManager by lazy { getSystemService(Context.USB_SERVICE) as UsbManager }
    private val deviceId by lazy {
        prefs.getString("device_id", null) ?: UUID.randomUUID().toString().also {
            prefs.edit().putString("device_id", it).apply()
        }
    }

    private lateinit var root: FrameLayout
    private lateinit var videoFrame: AspectFrameLayout
    private lateinit var surfaceView: SurfaceView
    private lateinit var connectPanel: LinearLayout
    private lateinit var macList: LinearLayout
    private lateinit var hostInput: EditText
    private lateinit var statusText: TextView
    private lateinit var statsText: TextView
    private lateinit var overlayText: TextView

    private var client: StreamClient? = null
    private var target: Target? = null
    private val decoder = VideoDecoder(this)
    private lateinit var discovery: MacDiscovery
    private var userWantsConnection = false
    private var reconnectAttempt = 0
    private var streaming = false
    @Volatile private var videoWidth = 0

    private var hostName = ""
    private var decoderName = ""
    private var framesThisSecond = 0
    private var bytesThisSecond = 0L
    private var latencySumUs = 0L
    private var latencyCount = 0
    private var rttMs = 0.0
    private var showStats = false
    private var panelRefreshHz = 60f

    // ---- Lifecycle ----

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
        requestHighestRefreshRate()
        buildUi()
        setContentView(root)
        discovery = MacDiscovery(this, ::onMacsChanged)

        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                if (userWantsConnection) {
                    prefs.edit().putBoolean("auto_connect", false).apply()
                    disconnect("Disconnected")
                } else {
                    finish()
                }
            }
        })
        ContextCompat.registerReceiver(this, usbReceiver, IntentFilter().apply {
            addAction(ACTION_USB_PERMISSION)
            addAction(UsbManager.ACTION_USB_ACCESSORY_DETACHED)
        }, ContextCompat.RECEIVER_NOT_EXPORTED)

        main.post(statsTick)
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        if (client == null) {
            ourAccessory()?.let { connectUsb(it); return }
            discovery.start()
        }
    }

    override fun onPause() {
        super.onPause()
        if (client == null) discovery.stop()
    }

    override fun onDestroy() {
        main.removeCallbacksAndMessages(null)
        unregisterReceiver(usbReceiver)
        discovery.stop()
        client?.stop()
        decoder.release()
        super.onDestroy()
    }

    private fun handleIntent(intent: Intent?) {
        when {
            intent?.action == UsbManager.ACTION_USB_ACCESSORY_ATTACHED -> {
                val accessory = IntentCompat.getParcelableExtra(intent, UsbManager.EXTRA_ACCESSORY, UsbAccessory::class.java)
                if (accessory != null && isOurs(accessory)) connectUsb(accessory)
            }
            // Development/automation: `adb shell am start -n app.unbound.client/.MainActivity --es host 127.0.0.1`
            intent?.getStringExtra("host") != null -> {
                val host = intent.getStringExtra("host")!!
                hostInput.setText(host)
                connectTcp(host, Wire.DEFAULT_PORT, null)
            }
        }
    }

    // ---- USB accessory ----

    private fun isOurs(a: UsbAccessory) = a.manufacturer == ACCESSORY_MANUFACTURER && a.model == ACCESSORY_MODEL

    private fun ourAccessory(): UsbAccessory? = usbManager.accessoryList?.firstOrNull(::isOurs)

    private fun connectUsb(accessory: UsbAccessory) {
        if (target is Target.Usb && client != null) return
        if (!usbManager.hasPermission(accessory)) {
            statusText.text = "Allow Unbound to use the USB connection…"
            val intent = Intent(ACTION_USB_PERMISSION).setPackage(packageName)
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0)
            usbManager.requestPermission(accessory, PendingIntent.getBroadcast(this, 0, intent, flags))
            return
        }
        discovery.stop()
        start(Target.Usb(accessory)) {
            val fd = usbManager.openAccessory(accessory) ?: throw IOException("couldn't open the USB connection")
            AccessoryChannel(fd)
        }
    }

    private val usbReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val accessory = IntentCompat.getParcelableExtra(intent, UsbManager.EXTRA_ACCESSORY, UsbAccessory::class.java)
            when (intent.action) {
                ACTION_USB_PERMISSION -> {
                    if (intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false) && accessory != null) {
                        connectUsb(accessory)
                    } else {
                        statusText.text = "USB permission was not granted"
                    }
                }
                UsbManager.ACTION_USB_ACCESSORY_DETACHED -> if (target is Target.Usb) {
                    disconnect("USB cable unplugged")
                    discovery.start()
                }
            }
        }
    }

    // ---- Wi-Fi / TCP ----

    private fun onMacsChanged(macs: List<MacDiscovery.Mac>) {
        macList.removeAllViews()
        if (macs.isEmpty()) {
            macList.addView(label("Looking for Macs on this network…", 14f, 0xFF8A8A8A.toInt()))
            return
        }
        for (mac in macs) {
            macList.addView(Button(this).apply {
                text = mac.name
                isAllCaps = false
                setOnClickListener { prefs.edit().putBoolean("auto_connect", true).apply(); connectTcp(mac.host, mac.port, mac.name) }
            }, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        }
        // Reconnect automatically to the Mac used last time.
        val last = prefs.getString("last_mac", null)
        if (client == null && prefs.getBoolean("auto_connect", false)) {
            macs.firstOrNull { it.name == last }?.let { connectTcp(it.host, it.port, it.name) }
        }
    }

    private fun connectTcp(host: String, port: Int, name: String?) {
        prefs.edit().putString("host", host).apply()
        if (name != null) prefs.edit().putString("last_mac", name).apply()
        start(Target.Tcp(host, port, name)) { TcpChannel.connect(host, port) }
    }

    // ---- Connection lifecycle ----

    private fun start(newTarget: Target, open: () -> Channel) {
        client?.stop()
        target = newTarget
        userWantsConnection = true
        streaming = false
        statusText.text = when (newTarget) {
            is Target.Usb -> "Connecting over USB-C…"
            is Target.Tcp -> "Connecting to ${newTarget.name ?: newTarget.host}…"
        }
        client = StreamClient(open, ::helloMessage, this).also { it.start() }
    }

    private fun helloMessage(): ByteArray {
        val (w, h) = realScreenSize()
        return Messages.clientHello(w, h, resources.displayMetrics.densityDpi, deviceId,
            "${Build.MANUFACTURER.replaceFirstChar { it.uppercase() }} ${Build.MODEL}")
    }

    private fun disconnect(message: String) {
        userWantsConnection = false
        main.removeCallbacks(reconnect)
        client?.stop()
        client = null
        target = null
        showVideo(false)
        statusText.text = message
        discovery.start()
    }

    private val reconnect = Runnable {
        if (!userWantsConnection) return@Runnable
        when (val t = target) {
            is Target.Usb -> ourAccessory()?.let { client = null; connectUsb(it) } ?: disconnect("USB cable unplugged")
            is Target.Tcp -> connectTcp(t.host, t.port, t.name)
            null -> {}
        }
    }

    // ---- StreamClient.Listener (network thread) ----

    override fun onHostHello(hostName: String, kind: Channel.Kind) = main.post {
        this.hostName = hostName
        reconnectAttempt = 0
        overlayText.visibility = View.GONE
        if (!streaming) {
            statusText.text = if (kind == Channel.Kind.WIFI)
                "Waiting for approval…\nClick “Allow” on $hostName."
            else "Connected to $hostName"
        }
    }.let {}

    override fun onCodecConfig(config: CodecConfig) {
        videoWidth = config.width
        decoder.configure(config)
        main.post { if (!streaming) { streaming = true; discovery.stop(); showVideo(true) } }
    }

    override fun onVideoFrame(data: ByteArray, ptsUs: Long, keyframe: Boolean, receivedAtNs: Long) {
        decoder.submit(data, ptsUs, keyframe, receivedAtNs)
        main.post { bytesThisSecond += data.size }
    }

    override fun onRoundTrip(rttMs: Double) = main.post { this.rttMs = rttMs }.let {}

    override fun onHostSilent() = main.post {
        overlayText.text = "Waiting for your Mac…\nOpen Unbound on the Mac to continue."
        overlayText.visibility = View.VISIBLE
    }.let {}

    override fun onDisconnected(reason: String, hostReason: String?, wasConnected: Boolean) = main.post {
        client = null
        if (!userWantsConnection) return@post
        if (hostReason != null) {
            // The Mac ended it on purpose (declined, version mismatch…): don't retry.
            disconnect(hostReason)
            return@post
        }
        showVideo(false)
        streaming = false
        reconnectAttempt++
        val delay = (500L * reconnectAttempt).coerceAtMost(5000L)
        statusText.text = (if (wasConnected) "Connection lost: $reason" else "Couldn't connect: $reason") +
            "\nRetrying… (Back to cancel)"
        main.postDelayed(reconnect, delay)
    }.let {}

    // ---- VideoDecoder.Listener (decoder thread) ----

    override fun onVideoSize(width: Int, height: Int) = main.post { videoFrame.setAspectRatio(width, height) }.let {}

    override fun onFrameRendered(decodeLatencyUs: Long) = main.post {
        framesThisSecond++
        latencySumUs += decodeLatencyUs
        latencyCount++
    }.let {}

    override fun onDecoderName(name: String, lowLatency: Boolean) = main.post {
        decoderName = name + if (lowLatency) " (low-latency)" else ""
    }.let {}

    override fun requestKeyframe() { client?.send(Messages.requestKeyframe()) }

    override fun onDecoderError(message: String) = main.post { statusText.text = "Video decoder: $message" }.let {}

    // ---- Surface ----

    override fun surfaceCreated(holder: SurfaceHolder) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            holder.surface.setFrameRate(panelRefreshHz, android.view.Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE)
        }
        decoder.setSurface(holder.surface)
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}
    override fun surfaceDestroyed(holder: SurfaceHolder) = decoder.setSurface(null).let {}

    // ---- Hardware keyboard ----

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val c = client
        if (c != null && streaming && event.keyCode != KeyEvent.KEYCODE_BACK) {
            val mac = KeyMapper.macKeyCode(event.keyCode)
            if (mac != null && (event.action == KeyEvent.ACTION_DOWN || event.action == KeyEvent.ACTION_UP)) {
                c.send(Messages.key(event.action == KeyEvent.ACTION_DOWN, KeyMapper.modifiers(event), mac))
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    // ---- UI ----

    @SuppressLint("ClickableViewAccessibility")
    private fun buildUi() {
        root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }

        surfaceView = SurfaceView(this).apply { holder.addCallback(this@MainActivity) }
        videoFrame = AspectFrameLayout(this).apply {
            addView(surfaceView, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
            visibility = View.GONE
        }
        root.addView(videoFrame, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT, Gravity.CENTER))

        val touch = TouchInputHandler(surfaceView, { videoWidth }, { msg -> client?.send(msg) }) {
            showStats = !showStats
            statsText.visibility = if (showStats && streaming) View.VISIBLE else View.GONE
        }
        surfaceView.setOnTouchListener(touch)
        surfaceView.setOnGenericMotionListener(touch)

        statsText = label("", 11f, Color.WHITE).apply {
            typeface = Typeface.MONOSPACE
            setBackgroundColor(0x99000000.toInt())
            setPadding(dp(8), dp(4), dp(8), dp(4))
            visibility = View.GONE
        }
        root.addView(statsText, FrameLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.TOP or Gravity.START))

        overlayText = label("", 16f, Color.WHITE).apply {
            gravity = Gravity.CENTER
            setPadding(dp(24), dp(16), dp(24), dp(16))
            background = GradientDrawable().apply { cornerRadius = dp(14).toFloat(); setColor(0xCC000000.toInt()) }
            visibility = View.GONE
        }
        root.addView(overlayText, FrameLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.CENTER))

        connectPanel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(32), dp(40), dp(32), dp(32))
        }
        connectPanel.addView(label("Unbound", 40f, Color.WHITE).apply { typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD) })
        connectPanel.addView(label("Your Mac's desktop, unbound.", 16f, 0xFFB0B0B0.toInt()).apply { setPadding(0, dp(2), 0, dp(28)) })

        connectPanel.addView(sectionTitle("USB-C"))
        connectPanel.addView(label("Plug this tablet into your Mac with a USB-C cable.\n" +
            "Make sure Unbound is running on the Mac, then tap “OK” when asked.", 14f, 0xFFCFCFCF.toInt()),
            LinearLayout.LayoutParams(dp(460), WRAP_CONTENT))

        connectPanel.addView(sectionTitle("Wi-Fi"))
        macList = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        connectPanel.addView(macList, LinearLayout.LayoutParams(dp(460), WRAP_CONTENT))
        onMacsChanged(emptyList())

        val manual = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        hostInput = EditText(this).apply {
            hint = "or enter the Mac's IP address"
            setText(prefs.getString("host", ""))
            setTextColor(Color.WHITE)
            setHintTextColor(0xFF6F6F6F.toInt())
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
            imeOptions = EditorInfo.IME_ACTION_GO
            setSingleLine()
            setOnEditorActionListener { _, _, _ -> manualConnect(); true }
        }
        manual.addView(hostInput, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f))
        manual.addView(Button(this).apply { text = "Connect"; setOnClickListener { manualConnect() } })
        connectPanel.addView(manual, LinearLayout.LayoutParams(dp(460), WRAP_CONTENT).apply { topMargin = dp(4) })

        statusText = label("", 15f, 0xFFFFD27A.toInt()).apply { gravity = Gravity.CENTER; setPadding(0, dp(20), 0, 0) }
        connectPanel.addView(statusText, LinearLayout.LayoutParams(dp(460), WRAP_CONTENT))

        connectPanel.addView(label("Tap = click · Drag = drag · Long-press = right-click\n" +
            "Two fingers = scroll · Three-finger tap = stats · Back = disconnect", 12f, 0xFF7A7A7A.toInt()).apply {
            gravity = Gravity.CENTER
            setPadding(0, dp(28), 0, 0)
        })

        val scroll = ScrollView(this).apply { isFillViewport = true }
        val center = FrameLayout(this)
        center.addView(connectPanel, FrameLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.CENTER))
        scroll.addView(center, FrameLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        root.addView(scroll, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        connectPanelContainer = scroll
    }

    private lateinit var connectPanelContainer: View

    private fun manualConnect() {
        val host = hostInput.text.toString().trim()
        if (host.isEmpty()) { statusText.text = "Enter the Mac's IP address"; return }
        prefs.edit().putBoolean("auto_connect", false).apply()
        connectTcp(host, Wire.DEFAULT_PORT, null)
    }

    private fun sectionTitle(text: String) = label(text.uppercase(), 12f, 0xFF7FB2FF.toInt()).apply {
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        letterSpacing = 0.12f
        setPadding(0, dp(18), 0, dp(6))
        layoutParams = LinearLayout.LayoutParams(dp(460), WRAP_CONTENT)
    }

    private fun label(text: String, sp: Float, color: Int) = TextView(this).apply {
        this.text = text
        setTextColor(color)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, sp)
    }

    private fun showVideo(visible: Boolean) {
        videoFrame.visibility = if (visible) View.VISIBLE else View.GONE
        connectPanelContainer.visibility = if (visible) View.GONE else View.VISIBLE
        statsText.visibility = if (visible && showStats) View.VISIBLE else View.GONE
        if (!visible) overlayText.visibility = View.GONE
        val controller = WindowInsetsControllerCompat(window, root)
        if (visible) {
            controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            controller.hide(WindowInsetsCompat.Type.systemBars())
            surfaceView.requestFocus()
        } else {
            controller.show(WindowInsetsCompat.Type.systemBars())
        }
    }

    /** Samsung and most OEMs keep apps at 60 Hz unless they ask for more. */
    private fun requestHighestRefreshRate() {
        @Suppress("DEPRECATION")
        val display = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) display else windowManager.defaultDisplay
        display ?: return
        val current = display.mode
        val best = display.supportedModes
            .filter { it.physicalWidth == current.physicalWidth && it.physicalHeight == current.physicalHeight }
            .maxByOrNull { it.refreshRate } ?: return
        panelRefreshHz = best.refreshRate
        window.attributes = window.attributes.apply { preferredDisplayModeId = best.modeId }
    }

    private fun realScreenSize(): Pair<Int, Int> {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val b = windowManager.maximumWindowMetrics.bounds
            b.width() to b.height()
        } else {
            val m = android.util.DisplayMetrics()
            @Suppress("DEPRECATION") windowManager.defaultDisplay.getRealMetrics(m)
            m.widthPixels to m.heightPixels
        }
    }

    private val statsTick = object : Runnable {
        override fun run() {
            if (streaming) {
                val avgLatency = if (latencyCount > 0) latencySumUs / latencyCount / 1000.0 else 0.0
                val kind = (target as? Target.Usb)?.let { "USB-C" } ?: "Wi-Fi"
                val line = "%d fps  %.1f Mbps  decode %.1f ms  rtt %.1f ms".format(
                    framesThisSecond, bytesThisSecond * 8 / 1_000_000.0, avgLatency, rttMs)
                statsText.text = "%s via %s  %dx%s  panel %.0f Hz\n%s\n%s".format(
                    hostName, kind, videoWidth, videoFrame.aspectText(), panelRefreshHz, line, decoderName)
                android.util.Log.i("UnboundStats", line)
            }
            framesThisSecond = 0; bytesThisSecond = 0; latencySumUs = 0; latencyCount = 0
            main.postDelayed(this, 1000)
        }
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    companion object {
        private const val ACTION_USB_PERMISSION = "app.unbound.client.USB_PERMISSION"
        // Must match the Mac's AccessoryWatcher.Identity and res/xml/accessory_filter.xml.
        const val ACCESSORY_MANUFACTURER = "Unbound"
        const val ACCESSORY_MODEL = "Unbound Display"
    }
}

/** Centers its child and letterboxes it to the video's aspect ratio. */
class AspectFrameLayout(context: Context) : FrameLayout(context) {
    private var videoW = 16
    private var videoH = 10

    fun setAspectRatio(width: Int, height: Int) {
        if (width <= 0 || height <= 0 || (width == videoW && height == videoH)) return
        videoW = width; videoH = height
        requestLayout()
    }

    fun aspectText() = "$videoH"

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val availW = MeasureSpec.getSize(widthMeasureSpec)
        val availH = MeasureSpec.getSize(heightMeasureSpec)
        var w = availW
        var h = (availW.toLong() * videoH / videoW).toInt()
        if (h > availH) {
            h = availH
            w = (availH.toLong() * videoW / videoH).toInt()
        }
        super.onMeasure(MeasureSpec.makeMeasureSpec(w, MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec(h, MeasureSpec.EXACTLY))
    }
}
