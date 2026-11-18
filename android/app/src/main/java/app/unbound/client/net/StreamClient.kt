package app.unbound.client.net

import android.os.SystemClock
import android.util.Log
import java.io.DataInputStream
import java.io.IOException
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * One connection to the Mac over any [Channel]. Reads on its own thread; writes are
 * serialized on a single-thread executor so the UI never blocks.
 *
 * Handshake: the Mac speaks first (HELLO); we answer with our HELLO. Video starts once the
 * Mac has approved us (first CODEC_CONFIG). If the Mac restarts behind a still-open USB
 * accessory, its new HELLO simply re-runs the handshake.
 */
class StreamClient(
    private val open: () -> Channel,
    private val hello: () -> ByteArray,
    private val listener: Listener,
) {
    interface Listener {
        fun onHostHello(hostName: String, kind: Channel.Kind)
        fun onCodecConfig(config: CodecConfig)
        fun onVideoFrame(data: ByteArray, ptsUs: Long, keyframe: Boolean, receivedAtNs: Long)
        fun onRoundTrip(rttMs: Double)
        /** USB only: the Mac stopped answering but the cable is still attached. */
        fun onHostSilent()
        /** [hostReason] is set when the Mac ended the session deliberately (e.g. declined). */
        fun onDisconnected(reason: String, hostReason: String?, wasConnected: Boolean)
    }

    private class HostGoodbye(val reason: String) : IOException(reason)

    private val running = AtomicBoolean(false)
    @Volatile private var channel: Channel? = null
    @Volatile private var lastReceiveNs = 0L
    @Volatile private var silentReported = false
    private var readThread: Thread? = null
    private val watchdog: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor()
    private val writer: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "unbound-writer").apply { priority = Thread.MAX_PRIORITY }
    }

    fun start() {
        if (!running.compareAndSet(false, true)) return
        readThread = Thread({ run() }, "unbound-reader").apply {
            priority = Thread.MAX_PRIORITY
            start()
        }
    }

    fun stop() {
        if (!running.getAndSet(false)) return
        try {
            writer.execute {
                try { channel?.output?.apply { write(Messages.goodbye()); flush() } } catch (_: IOException) {}
                channel?.close()
            }
        } catch (_: RejectedExecutionException) {
            channel?.close()
        }
        writer.shutdown()
        watchdog.shutdownNow()
    }

    fun send(message: ByteArray) {
        if (!running.get()) return
        try {
            writer.execute {
                val out = channel?.output ?: return@execute
                try {
                    out.write(message)
                    out.flush()
                } catch (e: IOException) {
                    channel?.close() // the reader thread reports the disconnect
                }
            }
        } catch (_: RejectedExecutionException) {
        }
    }

    private fun run() {
        var connected = false
        var reason = "closed"
        var hostReason: String? = null
        try {
            val ch = open()
            channel = ch
            lastReceiveNs = SystemClock.elapsedRealtimeNanos()
            scheduleKeepAlive(ch.kind)
            readLoop(DataInputStream(ch.input), ch.kind) { connected = true }
        } catch (e: HostGoodbye) {
            hostReason = e.reason.ifBlank { null }
            reason = e.reason.ifBlank { "the Mac ended the session" }
        } catch (e: IOException) {
            reason = e.message ?: e.javaClass.simpleName
        } catch (e: ProtocolException) {
            reason = "protocol error: ${e.message}"
        } catch (e: SecurityException) {
            reason = "USB permission denied"
        }
        channel?.close()
        val wasRunning = running.getAndSet(false)
        if (!writer.isShutdown) writer.shutdownNow()
        watchdog.shutdownNow()
        // A stop() requested by the app is not reported as a disconnect.
        if (wasRunning) listener.onDisconnected(reason, hostReason, connected)
    }

    private inline fun readLoop(input: DataInputStream, kind: Channel.Kind, markConnected: () -> Unit) {
        val headerBytes = ByteArray(Wire.HEADER_SIZE)
        while (running.get()) {
            input.readFully(headerBytes)
            val header = Header.parse(headerBytes)
            val payload = ByteArray(header.payloadLength)
            if (payload.isNotEmpty()) input.readFully(payload)
            val receivedAt = SystemClock.elapsedRealtimeNanos()
            lastReceiveNs = receivedAt
            silentReported = false

            when (header.type) {
                Wire.TYPE_HELLO -> {
                    markConnected()
                    send(hello())
                    val name = if (payload.size > 2) String(payload, 2, payload.size - 2, Charsets.UTF_8) else "Mac"
                    listener.onHostHello(name, kind)
                }
                Wire.TYPE_CODEC_CONFIG -> listener.onCodecConfig(CodecConfig.parse(payload))
                Wire.TYPE_VIDEO_FRAME -> listener.onVideoFrame(payload, header.timestampUs, header.isKeyframe, receivedAt)
                Wire.TYPE_PONG -> {
                    val rttUs = nowUs() - header.timestampUs
                    if (rttUs >= 0) listener.onRoundTrip(rttUs / 1000.0)
                }
                Wire.TYPE_GOODBYE -> throw HostGoodbye(String(payload, Charsets.UTF_8))
                else -> Log.d(TAG, "ignoring message type ${header.type}")
            }
        }
    }

    /**
     * Pings every second on the writer. Silence is checked on a separate thread, because a
     * USB write blocks while the Mac isn't reading. Silence for 4 s: TCP reconnects;
     * USB reports it and keeps waiting for the Mac to return.
     */
    private fun scheduleKeepAlive(kind: Channel.Kind) {
        writer.scheduleWithFixedDelay({
            val ch = channel ?: return@scheduleWithFixedDelay
            try { ch.output.write(Messages.ping(nowUs())); ch.output.flush() } catch (_: IOException) { ch.close() }
        }, 500, 1000, TimeUnit.MILLISECONDS)
        watchdog.scheduleWithFixedDelay({
            val ch = channel ?: return@scheduleWithFixedDelay
            val silentMs = (SystemClock.elapsedRealtimeNanos() - lastReceiveNs) / 1_000_000
            if (silentMs > 4000) {
                if (kind == Channel.Kind.USB) {
                    if (!silentReported) { silentReported = true; listener.onHostSilent() }
                } else {
                    ch.close()
                }
            }
        }, 1000, 1000, TimeUnit.MILLISECONDS)
    }

    private fun nowUs() = SystemClock.elapsedRealtimeNanos() / 1000

    companion object { private const val TAG = "UnboundStream" }
}
