import Foundation

/// Sprint-1 framing over a reliable byte stream (TCP / adb-reverse USB).
/// Every message: 20-byte big-endian header + payload. See docs/protocol.md.
///
///   0  u16  magic 0x5542 ("UB")
///   2  u8   protocol version (1)
///   3  u8   message type
///   4  u8   flags (bit0 = keyframe)
///   5  u8[3] reserved (0)
///   8  u32  payload length
///  12  i64  timestamp (µs; PTS for video, sender clock for ping/pong)
public enum Wire {
    public static let magic: UInt16 = 0x5542
    public static let version: UInt8 = 1
    public static let headerSize = 20
    public static let maxPayload = 16 * 1024 * 1024
    public static let defaultPort: UInt16 = 7878

    public enum MessageType: UInt8, Sendable {
        case hello = 0x01            // both directions
        case codecConfig = 0x02      // host → client
        case videoFrame = 0x03       // host → client
        case requestKeyframe = 0x04  // client → host
        case ping = 0x05             // client → host
        case pong = 0x06             // host → client
        case goodbye = 0x07          // both directions
        case pointer = 0x08          // client → host
        case scroll = 0x09           // client → host
        case key = 0x0A              // client → host
    }

    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let keyframe = Flags(rawValue: 1 << 0)
    }

    public enum Codec: UInt8, Sendable { case h264 = 1, hevc = 2 }
}

public struct WireHeader: Sendable, Equatable {
    public var type: Wire.MessageType
    public var flags: Wire.Flags
    public var payloadLength: Int
    public var timestampMicros: Int64

    public enum ParseError: Error, Equatable {
        case badMagic, unsupportedVersion(UInt8), unknownType(UInt8), payloadTooLarge(Int), truncated
        /// The peer uses the pre-rename (Annex) marker: it needs updating.
        case outdatedPeer
    }

    /// Marker used before the rename; recognised only to report "update the app".
    public static let legacyMagic: UInt16 = 0x4158
    static let maxHelloPayload = 4096

    /// True when `bytes` starts with a plausible HELLO header. Used to resync a stream that
    /// begins with stale bytes (USB keeps data from an earlier session).
    static func isHello(_ bytes: Data) -> Bool {
        guard bytes.count >= Wire.headerSize else { return false }
        let b = [UInt8](bytes.prefix(Wire.headerSize))
        guard UInt16(b[0]) << 8 | UInt16(b[1]) == Wire.magic, b[2] == Wire.version,
              b[3] == Wire.MessageType.hello.rawValue else { return false }
        let length = Int(b[8]) << 24 | Int(b[9]) << 16 | Int(b[10]) << 8 | Int(b[11])
        return length <= maxHelloPayload
    }

    public static func parse(_ bytes: Data) throws -> WireHeader {
        guard bytes.count >= Wire.headerSize else { throw ParseError.truncated }
        var r = ByteReader(bytes)
        guard try r.u16() == Wire.magic else { throw ParseError.badMagic }
        let version = try r.u8()
        guard version == Wire.version else { throw ParseError.unsupportedVersion(version) }
        let rawType = try r.u8()
        guard let type = Wire.MessageType(rawValue: rawType) else { throw ParseError.unknownType(rawType) }
        let flags = Wire.Flags(rawValue: try r.u8())
        _ = try r.bytes(3)
        let length = Int(try r.u32())
        guard length <= Wire.maxPayload else { throw ParseError.payloadTooLarge(length) }
        let ts = Int64(bitPattern: try r.u64())
        return WireHeader(type: type, flags: flags, payloadLength: length, timestampMicros: ts)
    }
}

public struct WireMessage: Sendable {
    public var type: Wire.MessageType
    public var flags: Wire.Flags = []
    public var timestampMicros: Int64 = 0
    public var payload: Data = Data()

    public init(type: Wire.MessageType, flags: Wire.Flags = [], timestampMicros: Int64 = 0, payload: Data = Data()) {
        self.type = type
        self.flags = flags
        self.timestampMicros = timestampMicros
        self.payload = payload
    }

    public func serialized() -> Data {
        var w = ByteWriter(capacity: Wire.headerSize + payload.count)
        w.u16(Wire.magic)
        w.u8(Wire.version)
        w.u8(type.rawValue)
        w.u8(flags.rawValue)
        w.bytes([0, 0, 0])
        w.u32(UInt32(payload.count))
        w.u64(UInt64(bitPattern: timestampMicros))
        w.data.append(payload)
        return w.data
    }

    // MARK: Constructors

    public static func hostHello(hostName: String) -> WireMessage {
        var w = ByteWriter()
        w.u16(UInt16(Wire.version))
        w.data.append(Data(hostName.utf8.prefix(255)))
        return WireMessage(type: .hello, payload: w.data)
    }

    public static func codecConfig(_ config: CodecConfig, codec: Wire.Codec = .h264) -> WireMessage {
        var w = ByteWriter()
        w.u8(codec.rawValue)
        w.u16(UInt16(config.width))
        w.u16(UInt16(config.height))
        w.u16(UInt16(config.sps.count)); w.data.append(config.sps)
        w.u16(UInt16(config.pps.count)); w.data.append(config.pps)
        return WireMessage(type: .codecConfig, payload: w.data)
    }

    public static func videoFrame(_ frame: EncodedFrame) -> WireMessage {
        WireMessage(type: .videoFrame, flags: frame.isKeyframe ? .keyframe : [],
                    timestampMicros: frame.ptsMicros, payload: frame.annexB)
    }
}

/// What an Android client tells us about itself on connect.
public struct ClientHello: Sendable, Equatable, CustomStringConvertible {
    public var protocolVersion: Int
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var densityDpi: Int
    /// Stable per-install identifier (used to remember approved tablets).
    public var deviceID: String
    public var model: String

    public init(protocolVersion: Int, pixelWidth: Int, pixelHeight: Int, densityDpi: Int, deviceID: String, model: String) {
        self.protocolVersion = protocolVersion
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.densityDpi = densityDpi
        self.deviceID = deviceID
        self.model = model
    }

    /// Layout: u16 version, u16 width, u16 height, u16 dpi, u8 idLength, id (UTF-8), model (UTF-8, rest)
    public static func parse(_ payload: Data) throws -> ClientHello {
        var r = ByteReader(payload)
        let version = Int(try r.u16())
        let w = Int(try r.u16()), h = Int(try r.u16()), dpi = Int(try r.u16())
        let idLength = Int(try r.u8())
        let id = String(decoding: try r.bytes(idLength), as: UTF8.self)
        let model = String(decoding: r.remaining(), as: UTF8.self)
        return ClientHello(protocolVersion: version, pixelWidth: w, pixelHeight: h, densityDpi: dpi,
                           deviceID: id, model: model)
    }

    public var description: String { "\(model) \(pixelWidth)x\(pixelHeight) @\(densityDpi)dpi (protocol v\(protocolVersion))" }
}

/// Input events from the tablet. Coordinates are normalized (0…1) over the video frame.
public enum InputEvent: Sendable, Equatable {
    public enum PointerAction: UInt8, Sendable { case down = 0, move = 1, up = 2, cancel = 3 }
    public enum Button: UInt8, Sendable { case left = 0, right = 1 }
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
        public static let capsLock = Modifiers(rawValue: 1 << 4)
    }

    /// pointer: u8 action, u8 button, u16 0, f32 x, f32 y
    case pointer(PointerAction, Button, x: Float, y: Float)
    /// scroll: f32 dx, f32 dy — in video pixels, finger-movement direction
    case scroll(dx: Float, dy: Float)
    /// key: u8 down, u8 modifiers, u16 macOS virtual key code
    case key(down: Bool, modifiers: Modifiers, keyCode: UInt16)

    public static func parse(type: Wire.MessageType, payload: Data) throws -> InputEvent? {
        var r = ByteReader(payload)
        switch type {
        case .pointer:
            guard let action = PointerAction(rawValue: try r.u8()),
                  let button = Button(rawValue: try r.u8()) else { return nil }
            _ = try r.u16()
            return .pointer(action, button, x: Float(bitPattern: try r.u32()), y: Float(bitPattern: try r.u32()))
        case .scroll:
            return .scroll(dx: Float(bitPattern: try r.u32()), dy: Float(bitPattern: try r.u32()))
        case .key:
            let down = try r.u8() != 0
            let mods = Modifiers(rawValue: try r.u8())
            return .key(down: down, modifiers: mods, keyCode: try r.u16())
        default:
            return nil
        }
    }

    public func serialized() -> WireMessage {
        var w = ByteWriter()
        switch self {
        case .pointer(let a, let b, let x, let y):
            w.u8(a.rawValue); w.u8(b.rawValue); w.u16(0); w.u32(x.bitPattern); w.u32(y.bitPattern)
            return WireMessage(type: .pointer, payload: w.data)
        case .scroll(let dx, let dy):
            w.u32(dx.bitPattern); w.u32(dy.bitPattern)
            return WireMessage(type: .scroll, payload: w.data)
        case .key(let down, let mods, let code):
            w.u8(down ? 1 : 0); w.u8(mods.rawValue); w.u16(code)
            return WireMessage(type: .key, payload: w.data)
        }
    }
}

// MARK: - Byte helpers

struct ByteWriter {
    var data: Data
    init(capacity: Int = 64) { data = Data(capacity: capacity) }
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { data.append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xFF)]) }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }
}

struct ByteReader {
    private let bytes: [UInt8]
    private var offset = 0
    init(_ data: Data) { bytes = [UInt8](data) }

    mutating func bytes(_ n: Int) throws -> ArraySlice<UInt8> {
        guard offset + n <= bytes.count else { throw WireHeader.ParseError.truncated }
        defer { offset += n }
        return bytes[offset..<(offset + n)]
    }
    mutating func u8() throws -> UInt8 { try bytes(1).first! }
    mutating func u16() throws -> UInt16 { try bytes(2).reduce(0) { ($0 << 8) | UInt16($1) } }
    mutating func u32() throws -> UInt32 { try bytes(4).reduce(0) { ($0 << 8) | UInt32($1) } }
    mutating func u64() throws -> UInt64 { try bytes(8).reduce(0) { ($0 << 8) | UInt64($1) } }
    mutating func remaining() -> ArraySlice<UInt8> { defer { offset = bytes.count }; return bytes[offset...] }
}
