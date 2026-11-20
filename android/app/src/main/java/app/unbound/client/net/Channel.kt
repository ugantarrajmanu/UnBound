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

/** Android Open Accessory channel (USB-C without developer mode). */
class AccessoryChannel(private val fd: ParcelFileDescriptor) : Channel {
    override val kind = Channel.Kind.USB
    override val input: InputStream = AccessoryInputStream(FileInputStream(fd.fileDescriptor))
    override val output: OutputStream = FileOutputStream(fd.fileDescriptor)
    override fun close() { try { fd.close() } catch (_: IOException) {} }
}

/**
 * Reads the USB accessory endpoint only in fixed 16 KB blocks. Some devices' accessory drivers drop
 * data when a read isn't a whole number of USB packets, and a normal buffered stream passes the
 * caller's (arbitrary) length straight through for large reads.
 */
private class AccessoryInputStream(private val raw: FileInputStream) : InputStream() {
    private val buf = ByteArray(BLOCK)
    private var pos = 0
    private var count = 0

    private fun fill(): Boolean {
        while (true) {
            val n = raw.read(buf, 0, BLOCK)
            if (n < 0) return false
            if (n > 0) { pos = 0; count = n; return true }   // 0 = zero-length packet; keep reading
        }
    }

    override fun read(): Int {
        if (pos >= count && !fill()) return -1
        return buf[pos++].toInt() and 0xFF
    }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        if (len == 0) return 0
        if (pos >= count && !fill()) return -1
        val n = minOf(len, count - pos)
        System.arraycopy(buf, pos, b, off, n)
        pos += n
        return n
    }

    override fun available() = count - pos
    override fun close() = raw.close()

    companion object { const val BLOCK = 16384 }
}
