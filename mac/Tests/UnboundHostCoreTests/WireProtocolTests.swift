import Foundation
import Testing
@testable import UnboundHostCore

@Suite struct WireProtocolTests {
    @Test func headerRoundTrip() throws {
        let msg = WireMessage(type: .videoFrame, flags: .keyframe, timestampMicros: 1_234_567_890_123,
                              payload: Data([1, 2, 3]))
        let bytes = msg.serialized()
        #expect(bytes.count == Wire.headerSize + 3)
        let header = try WireHeader.parse(bytes.prefix(Wire.headerSize))
        #expect(header.type == .videoFrame)
        #expect(header.flags.contains(.keyframe))
        #expect(header.payloadLength == 3)
        #expect(header.timestampMicros == 1_234_567_890_123)
    }

    @Test func negativeTimestampSurvives() throws {
        let bytes = WireMessage(type: .ping, timestampMicros: -42).serialized()
        #expect(try WireHeader.parse(bytes).timestampMicros == -42)
    }

    @Test func rejectsBadMagicAndOversize() {
        var bytes = WireMessage(type: .ping).serialized()
        bytes[0] = 0
        #expect(throws: WireHeader.ParseError.badMagic) { try WireHeader.parse(bytes) }

        var big = WireMessage(type: .videoFrame).serialized()
        big.replaceSubrange(8..<12, with: [0x7F, 0xFF, 0xFF, 0xFF])
        #expect(throws: WireHeader.ParseError.payloadTooLarge(0x7FFF_FFFF)) { try WireHeader.parse(big) }
    }

    @Test func codecConfigLayout() {
        let config = CodecConfig(width: 2560, height: 1600, sps: Data([0x67, 0x64]), pps: Data([0x68]))
        let p = WireMessage.codecConfig(config).payload
        #expect([UInt8](p) == [1, 0x0A, 0x00, 0x06, 0x40, 0, 2, 0x67, 0x64, 0, 1, 0x68])
    }

    @Test func clientHelloParse() throws {
        var w = ByteWriter()
        w.u16(1); w.u16(2560); w.u16(1600); w.u16(320)
        w.u8(3); w.data.append(Data("abc".utf8))
        w.data.append(Data("Galaxy Tab S9".utf8))
        let hello = try ClientHello.parse(w.data)
        #expect(hello == ClientHello(protocolVersion: 1, pixelWidth: 2560, pixelHeight: 1600, densityDpi: 320,
                                     deviceID: "abc", model: "Galaxy Tab S9"))
    }

    @Test func avccToAnnexB() {
        let avcc = Data([0, 0, 0, 2, 0x65, 0xAA, 0, 0, 0, 1, 0x41])
        #expect([UInt8](NALUtil.avccToAnnexB(avcc)) == [0, 0, 0, 1, 0x65, 0xAA, 0, 0, 0, 1, 0x41])
    }

    @Test func avccTruncatedStopsSafely() {
        let avcc = Data([0, 0, 0, 9, 0x65])
        #expect(NALUtil.avccToAnnexB(avcc).isEmpty)
    }
}

@Suite struct InputProtocolTests {
    @Test(arguments: [
        InputEvent.pointer(.down, .left, x: 0.25, y: 0.75),
        InputEvent.pointer(.up, .right, x: 1, y: 0),
        InputEvent.scroll(dx: -3.5, dy: 120),
        InputEvent.key(down: true, modifiers: [.command, .shift], keyCode: 8),
    ])
    func roundTrip(_ event: InputEvent) throws {
        let msg = event.serialized()
        #expect(try InputEvent.parse(type: msg.type, payload: msg.payload) == event)
    }

    @Test func pointerLayoutMatchesAndroid() {
        // Android writes: action, button, 0x0000, float32 x, float32 y (big-endian)
        let p = [UInt8](InputEvent.pointer(.move, .left, x: 0.5, y: 1.0).serialized().payload)
        #expect(p == [1, 0, 0, 0, 0x3F, 0, 0, 0, 0x3F, 0x80, 0, 0])
    }
}

@Suite struct AdaptiveBitrateTests {
    @Test func backsOffOnDropsAndRecovers() {
        let abr = AdaptiveBitrate(maxBitrate: 12_000_000)
        #expect(abr.update(framesDropped: 3, queuedBytes: 0) == 8_400_000)
        #expect(abr.update(framesDropped: 9, queuedBytes: 0) == 5_880_000)
        // No new drops, empty queue: holds for 3 s then steps up.
        for _ in 0..<5 { #expect(abr.update(framesDropped: 9, queuedBytes: 0) == nil) }
        #expect(abr.update(framesDropped: 9, queuedBytes: 0) == 6_762_000)
    }

    @Test func neverBelowMinimum() {
        let abr = AdaptiveBitrate(maxBitrate: 12_000_000)
        var dropped: Int64 = 0
        for _ in 0..<20 { dropped += 1; _ = abr.update(framesDropped: dropped, queuedBytes: 0) }
        #expect(abr.bitrate == 1_500_000)
    }
}
