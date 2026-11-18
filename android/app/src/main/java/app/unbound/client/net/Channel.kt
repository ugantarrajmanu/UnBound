package app.unbound.client.net

import android.os.ParcelFileDescriptor
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket

/** A byte pipe to the Mac: TCP (Wi-Fi / adb) or the USB accessory. */
interface Channel {
    enum class Kind(val label: String) { USB("USB-C"), WIFI("Wi-Fi"), ADB("USB (adb)") }

    val kind: Kind
    val input: InputStream
    val output: OutputStream
    fun close()
}

class TcpChannel private constructor(private val socket: Socket, override val kind: Channel.Kind) : Channel {
    override val input: InputStream = socket.getInputStream().buffered(1 shl 16)
    override val output: OutputStream = socket.getOutputStream()
    override fun close() { try { socket.close() } catch (_: IOException) {} }

    companion object {
        fun connect(host: String, port: Int): TcpChannel {
            val s = Socket()
            s.tcpNoDelay = true
            s.receiveBufferSize = 1 shl 20
            s.connect(InetSocketAddress(host, port), 3000)
            val kind = if (host == "127.0.0.1" || host == "localhost") Channel.Kind.ADB else Channel.Kind.WIFI
            return TcpChannel(s, kind)
        }
    }
}

/**
 * Android Open Accessory channel. Reads must use a buffer of at least 16 KiB (the
 * USB request size); BufferedInputStream with 64 KiB satisfies that.
 */
class AccessoryChannel(private val fd: ParcelFileDescriptor) : Channel {
    override val kind = Channel.Kind.USB
    override val input: InputStream = FileInputStream(fd.fileDescriptor).buffered(1 shl 16)
    override val output: OutputStream = FileOutputStream(fd.fileDescriptor)
    override fun close() { try { fd.close() } catch (_: IOException) {} }
}
