package app.unbound.client.net

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Sprint-1 framing, mirrored from mac/Sources/UnboundHostCore/Protocol/WireProtocol.swift.
 * 20-byte big-endian header: magic u16, version u8, type u8, flags u8, reserved[3],
 * payload length u32, timestamp i64 (µs).
 */
object Wire {
    const val MAGIC = 0x5542
    const val VERSION = 1
    const val HEADER_SIZE = 20
    const val MAX_PAYLOAD = 16 * 1024 * 1024
    const val DEFAULT_PORT = 7878

    const val TYPE_HELLO = 0x01
    const val TYPE_CODEC_CONFIG = 0x02
    const val TYPE_VIDEO_FRAME = 0x03
    const val TYPE_REQUEST_KEYFRAME = 0x04
    const val TYPE_PING = 0x05
    const val TYPE_PONG = 0x06
    const val TYPE_GOODBYE = 0x07
    const val TYPE_POINTER = 0x08
    const val TYPE_SCROLL = 0x09
    const val TYPE_KEY = 0x0A

    const val FLAG_KEYFRAME = 0x01

    const val CODEC_H264 = 1
}

class ProtocolException(message: String) : Exception(message)

data class Header(val type: Int, val flags: Int, val payloadLength: Int, val timestampUs: Long) {
    val isKeyframe get() = flags and Wire.FLAG_KEYFRAME != 0

    companion object {
        fun parse(bytes: ByteArray): Header {
            if (bytes.size < Wire.HEADER_SIZE) throw ProtocolException("truncated header")
            val b = ByteBuffer.wrap(bytes).order(ByteOrder.BIG_ENDIAN)
            val magic = b.short.toInt() and 0xFFFF
            if (magic != Wire.MAGIC) throw ProtocolException("bad magic 0x${magic.toString(16)}")
            val version = b.get().toInt() and 0xFF
            if (version != Wire.VERSION) throw ProtocolException("unsupported protocol version $version")
            val type = b.get().toInt() and 0xFF
            val flags = b.get().toInt() and 0xFF
            b.position(b.position() + 3)
            val length = b.int.toLong() and 0xFFFFFFFFL
            if (length > Wire.MAX_PAYLOAD) throw ProtocolException("payload too large: $length")
            return Header(type, flags, length.toInt(), b.long)
        }
    }
}

fun encodeMessage(type: Int, payload: ByteArray = ByteArray(0), flags: Int = 0, timestampUs: Long = 0): ByteArray {
    val b = ByteBuffer.allocate(Wire.HEADER_SIZE + payload.size).order(ByteOrder.BIG_ENDIAN)
    b.putShort(Wire.MAGIC.toShort())
    b.put(Wire.VERSION.toByte())
    b.put(type.toByte())
    b.put(flags.toByte())
    b.put(ByteArray(3))
    b.putInt(payload.size)
    b.putLong(timestampUs)
    b.put(payload)
    return b.array()
}

class CodecConfig(val codec: Int, val width: Int, val height: Int, val sps: ByteArray, val pps: ByteArray) {
    override fun equals(other: Any?) = other is CodecConfig && codec == other.codec && width == other.width &&
        height == other.height && sps.contentEquals(other.sps) && pps.contentEquals(other.pps)

    override fun hashCode() = 31 * (31 * width + height) + sps.contentHashCode()

    override fun toString() = "CodecConfig(${width}x$height, sps=${sps.size}B, pps=${pps.size}B)"

    companion object {
        fun parse(payload: ByteArray): CodecConfig {
            val b = ByteBuffer.wrap(payload).order(ByteOrder.BIG_ENDIAN)
            val codec = b.get().toInt() and 0xFF
            val width = b.short.toInt() and 0xFFFF
            val height = b.short.toInt() and 0xFFFF
            val sps = ByteArray(b.short.toInt() and 0xFFFF).also { b.get(it) }
            val pps = ByteArray(b.short.toInt() and 0xFFFF).also { b.get(it) }
            return CodecConfig(codec, width, height, sps, pps)
        }
    }
}

object Messages {
    /** u16 version, u16 width, u16 height, u16 dpi, u8 idLength, id, model (rest). */
    fun clientHello(width: Int, height: Int, densityDpi: Int, deviceId: String, model: String): ByteArray {
        val id = deviceId.toByteArray(Charsets.UTF_8).take(255).toByteArray()
        val name = model.toByteArray(Charsets.UTF_8).take(255).toByteArray()
        val b = ByteBuffer.allocate(9 + id.size + name.size).order(ByteOrder.BIG_ENDIAN)
        b.putShort(Wire.VERSION.toShort())
        b.putShort(width.toShort()); b.putShort(height.toShort()); b.putShort(densityDpi.toShort())
        b.put(id.size.toByte()); b.put(id)
        b.put(name)
        return encodeMessage(Wire.TYPE_HELLO, b.array())
    }

    fun ping(nowUs: Long) = encodeMessage(Wire.TYPE_PING, timestampUs = nowUs)

    fun requestKeyframe() = encodeMessage(Wire.TYPE_REQUEST_KEYFRAME)

    fun goodbye() = encodeMessage(Wire.TYPE_GOODBYE)

    /** x/y normalized 0..1 over the video frame. */
    fun pointer(action: PointerAction, button: MouseButton, x: Float, y: Float): ByteArray {
        val b = ByteBuffer.allocate(12).order(ByteOrder.BIG_ENDIAN)
        b.put(action.code.toByte()); b.put(button.code.toByte()); b.putShort(0)
        b.putFloat(x); b.putFloat(y)
        return encodeMessage(Wire.TYPE_POINTER, b.array())
    }

    /** Deltas in video pixels, in finger-movement direction. */
    fun scroll(dx: Float, dy: Float): ByteArray {
        val b = ByteBuffer.allocate(8).order(ByteOrder.BIG_ENDIAN)
        b.putFloat(dx); b.putFloat(dy)
        return encodeMessage(Wire.TYPE_SCROLL, b.array())
    }

    fun key(down: Boolean, modifiers: Int, macKeyCode: Int): ByteArray {
        val b = ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN)
        b.put(if (down) 1 else 0); b.put(modifiers.toByte()); b.putShort(macKeyCode.toShort())
        return encodeMessage(Wire.TYPE_KEY, b.array())
    }
}

enum class PointerAction(val code: Int) { DOWN(0), MOVE(1), UP(2), CANCEL(3) }

enum class MouseButton(val code: Int) { LEFT(0), RIGHT(1) }

object Modifier {
    const val SHIFT = 1 shl 0
    const val CONTROL = 1 shl 1
    const val OPTION = 1 shl 2
    const val COMMAND = 1 shl 3
    const val CAPS_LOCK = 1 shl 4
}
