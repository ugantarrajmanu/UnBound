package app.unbound.client.net

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Byte layouts must match mac/Tests/UnboundHostCoreTests/WireProtocolTests.swift. */
class WireProtocolTest {
    @Test fun headerRoundTrip() {
        val msg = encodeMessage(Wire.TYPE_VIDEO_FRAME, byteArrayOf(1, 2, 3), Wire.FLAG_KEYFRAME, 1_234_567_890_123L)
        val h = Header.parse(msg.copyOf(Wire.HEADER_SIZE))
        assertEquals(Wire.TYPE_VIDEO_FRAME, h.type)
        assertTrue(h.isKeyframe)
        assertEquals(3, h.payloadLength)
        assertEquals(1_234_567_890_123L, h.timestampUs)
    }

    @Test(expected = ProtocolException::class)
    fun rejectsBadMagic() {
        val msg = encodeMessage(Wire.TYPE_PING)
        msg[0] = 0
        Header.parse(msg)
    }

    @Test fun codecConfigMatchesSwiftLayout() {
        // Same bytes as Swift's codecConfigLayout test.
        val payload = byteArrayOf(1, 0x0A, 0x00, 0x06, 0x40, 0, 2, 0x67, 0x64, 0, 1, 0x68)
        val c = CodecConfig.parse(payload)
        assertEquals(2560, c.width)
        assertEquals(1600, c.height)
        assertArrayEquals(byteArrayOf(0x67, 0x64), c.sps)
        assertArrayEquals(byteArrayOf(0x68), c.pps)
    }

    @Test fun pointerMatchesSwiftLayout() {
        val msg = Messages.pointer(PointerAction.MOVE, MouseButton.LEFT, 0.5f, 1.0f)
        val payload = msg.copyOfRange(Wire.HEADER_SIZE, msg.size)
        assertArrayEquals(byteArrayOf(1, 0, 0, 0, 0x3F, 0, 0, 0, 0x3F, 0x80.toByte(), 0, 0), payload)
    }

    @Test fun helloLayout() {
        val msg = Messages.clientHello(2560, 1600, 320, "abc", "Tab")
        val p = msg.copyOfRange(Wire.HEADER_SIZE, msg.size)
        val expected = byteArrayOf(0, 1, 0x0A, 0x00, 0x06, 0x40, 0x01, 0x40, 3) +
            "abc".toByteArray() + "Tab".toByteArray()
        assertArrayEquals(expected, p)
    }

    @Test
    fun recognisesHelloHeaderOnly() {
        val hello = encodeMessage(Wire.TYPE_HELLO, ByteArray(10))
        assertTrue(Header.isHello(hello.copyOf(Wire.HEADER_SIZE)))
        val ping = encodeMessage(Wire.TYPE_PING)
        assertFalse(Header.isHello(ping.copyOf(Wire.HEADER_SIZE)))
        val shifted = ByteArray(1) + hello
        assertFalse(Header.isHello(shifted.copyOf(Wire.HEADER_SIZE)))
    }
}
