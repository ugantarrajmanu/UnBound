package app.unbound.client.video

import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import app.unbound.client.net.CodecConfig
import java.util.ArrayDeque

/**
 * Hardware H.264 decoder rendering straight to a Surface. All MediaCodec work
 * happens on one HandlerThread, so no locking is needed around codec state.
 *
 * Latency policy: at most [MAX_PENDING] frames may wait for an input buffer.
 * Beyond that we drop everything and resync on the next keyframe.
 */
class VideoDecoder(private val listener: Listener) {
    interface Listener {
        fun onVideoSize(width: Int, height: Int)
        fun onFrameRendered(decodeLatencyUs: Long)
        fun onDecoderName(name: String, lowLatency: Boolean)
        fun requestKeyframe()
        fun onDecoderError(message: String)
    }

    private class Frame(val data: ByteArray, val ptsUs: Long, val keyframe: Boolean, val receivedAtNs: Long)

    private val thread = HandlerThread("unbound-decoder", android.os.Process.THREAD_PRIORITY_URGENT_DISPLAY).apply { start() }
    private val handler = Handler(thread.looper)

    // Decoder-thread state
    private var surface: Surface? = null
    private var config: CodecConfig? = null
    private var codec: MediaCodec? = null
    private var generation = 0
    private val pending = ArrayDeque<Frame>()
    private val freeInputs = ArrayDeque<Int>()
    private val receivedAt = HashMap<Long, Long>()
    private var awaitingKeyframe = true
    private var rendering = false

    fun setSurface(newSurface: Surface?) = handler.post {
        if (surface === newSurface) return@post
        surface = newSurface
        releaseCodec()
        if (newSurface != null && config != null) {
            createCodec()
            listener.requestKeyframe()
        }
    }

    fun configure(newConfig: CodecConfig) = handler.post {
        if (newConfig == config && codec != null) return@post
        config = newConfig
        releaseCodec()
        if (surface != null) createCodec()
    }

    fun submit(data: ByteArray, ptsUs: Long, keyframe: Boolean, receivedAtNs: Long) = handler.post {
        if (codec == null) return@post
        // Hardware codecs can take a few hundred ms to start; only enforce the
        // backlog limit once the decoder has produced its first frame.
        if (rendering && pending.size >= MAX_PENDING) {
            Log.w(TAG, "decoder backlog (${pending.size}); resyncing on next keyframe")
            pending.clear()
            awaitingKeyframe = true
            listener.requestKeyframe()
        }
        pending.addLast(Frame(data, ptsUs, keyframe, receivedAtNs))
        drain()
    }

    fun release() {
        handler.post {
            releaseCodec()
            config = null
            surface = null
        }
        thread.quitSafely()
    }

    // ---- decoder thread ----

    private fun createCodec() {
        val cfg = config ?: return
        val out = surface ?: return
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, cfg.width, cfg.height).apply {
            setByteBuffer("csd-0", java.nio.ByteBuffer.wrap(START_CODE + cfg.sps))
            setByteBuffer("csd-1", java.nio.ByteBuffer.wrap(START_CODE + cfg.pps))
            setInteger(MediaFormat.KEY_PRIORITY, 0) // realtime
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, cfg.width * cfg.height)
        }
        val name = MediaCodecList(MediaCodecList.REGULAR_CODECS).findDecoderForFormat(format)
        val supportsLowLatency = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && name != null &&
            runCatching {
                MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.first { it.name == name }
                    .getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC)
                    .isFeatureSupported(android.media.MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)
            }.getOrDefault(false)
        if (supportsLowLatency && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
        }
        // Vendor low-latency hints; ignored by decoders that don't know them.
        format.setInteger("vendor.qti-ext-dec-low-latency.enable", 1)
        format.setInteger("vendor.rtc-ext-dec-low-latency.enable", 1)

        val c = try {
            (if (name != null) MediaCodec.createByCodecName(name) else MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC))
        } catch (e: Exception) {
            listener.onDecoderError("no H.264 decoder: ${e.message}")
            return
        }
        val gen = ++generation
        c.setCallback(object : MediaCodec.Callback() {
            override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
                if (gen != generation) return
                freeInputs.addLast(index)
                drain()
            }

            override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                if (gen != generation) return
                try {
                    codec.releaseOutputBuffer(index, true)
                } catch (e: IllegalStateException) {
                    return
                }
                rendering = true
                receivedAt.remove(info.presentationTimeUs)?.let {
                    listener.onFrameRendered((SystemClock.elapsedRealtimeNanos() - it) / 1000)
                }
                if (receivedAt.size > 64) receivedAt.clear()
            }

            override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
                if (gen != generation) return
                val w = if (format.containsKey("crop-right")) format.getInteger("crop-right") - format.getInteger("crop-left") + 1
                else format.getInteger(MediaFormat.KEY_WIDTH)
                val h = if (format.containsKey("crop-bottom")) format.getInteger("crop-bottom") - format.getInteger("crop-top") + 1
                else format.getInteger(MediaFormat.KEY_HEIGHT)
                listener.onVideoSize(w, h)
            }

            override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
                if (gen != generation) return
                Log.e(TAG, "codec error", e)
                listener.onDecoderError(e.diagnosticInfo ?: "codec error")
                releaseCodec()
                createCodec()
                listener.requestKeyframe()
            }
        }, handler)

        try {
            c.configure(format, out, null, 0)
            c.start()
        } catch (e: Exception) {
            Log.e(TAG, "configure failed", e)
            c.release()
            listener.onDecoderError("decoder configure failed: ${e.message}")
            return
        }
        codec = c
        awaitingKeyframe = true
        listener.onDecoderName(c.name, supportsLowLatency)
        listener.onVideoSize(cfg.width, cfg.height)
    }

    private fun drain() {
        val c = codec ?: return
        while (freeInputs.isNotEmpty() && pending.isNotEmpty()) {
            val frame = pending.removeFirst()
            if (awaitingKeyframe) {
                if (!frame.keyframe) continue
                awaitingKeyframe = false
            }
            val index = freeInputs.removeFirst()
            try {
                val buffer = c.getInputBuffer(index) ?: continue
                if (frame.data.size > buffer.capacity()) {
                    Log.w(TAG, "frame ${frame.data.size}B exceeds input buffer ${buffer.capacity()}B; dropping")
                    c.queueInputBuffer(index, 0, 0, frame.ptsUs, 0)
                    awaitingKeyframe = true
                    listener.requestKeyframe()
                    continue
                }
                buffer.clear()
                buffer.put(frame.data)
                receivedAt[frame.ptsUs] = frame.receivedAtNs
                c.queueInputBuffer(index, 0, frame.data.size, frame.ptsUs,
                    if (frame.keyframe) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
            } catch (e: IllegalStateException) {
                Log.w(TAG, "queueInputBuffer failed", e)
                return
            }
        }
    }

    private fun releaseCodec() {
        generation++
        rendering = false
        pending.clear()
        freeInputs.clear()
        receivedAt.clear()
        codec?.let {
            try { it.stop() } catch (_: Exception) {}
            try { it.release() } catch (_: Exception) {}
        }
        codec = null
    }

    companion object {
        private const val TAG = "UnboundDecoder"
        private const val MAX_PENDING = 6
        private val START_CODE = byteArrayOf(0, 0, 0, 1)
    }
}
