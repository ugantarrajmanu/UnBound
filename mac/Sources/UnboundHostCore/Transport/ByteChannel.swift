import Foundation
import Network

public enum UnboundProduct {
    /// Where users get the tablet app. Android shows this when the app isn't installed
    /// and an accessory connects. Replace with the real download page before release.
    public static let downloadURL = "https://github.com/ugantarrajmanu/UnBound/releases/latest"
    public static let bonjourType = "_unbound._tcp"
}

public enum ChannelKind: String, Sendable {
    /// USB-C via Android Open Accessory — physical connection, implicitly trusted.
    case usbAccessory = "USB-C"
    /// TCP over the loopback interface (adb reverse, development).
    case usbDebug = "USB (adb)"
    /// TCP from the network — requires approval on the Mac.
    case wifi = "Wi-Fi"

    public var isTrusted: Bool { self != .wifi }
}

struct ChannelClosed: Error {}

/// A bidirectional byte stream to one tablet. TCP and USB accessory both implement it,
/// so the protocol session never knows which cable (or radio) it is on.
public protocol ByteChannel: AnyObject, Sendable, CustomStringConvertible {
    var kind: ChannelKind { get }
    func start(onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (String) -> Void)
    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void)
    func close()
}

/// Reassembles wire messages from arbitrary chunks.
struct FrameParser {
    private var buffer = Data()
    private var header: WireHeader?
    /// Until the peer's HELLO is found, unrecognised bytes are skipped rather than fatal.
    private var synced = false
    private(set) var skippedBytes = 0

    mutating func append(_ chunk: Data) throws -> [(WireHeader, Data)] {
        buffer.append(chunk)
        var out: [(WireHeader, Data)] = []
        if !synced {
            if skippedBytes == 0, buffer.count >= 2,
               UInt16(buffer[buffer.startIndex]) << 8 | UInt16(buffer[buffer.startIndex + 1]) == WireHeader.legacyMagic {
                throw WireHeader.ParseError.outdatedPeer
            }
            while buffer.count >= Wire.headerSize, !WireHeader.isHello(buffer) {
                buffer.removeFirst()
                skippedBytes += 1
            }
            guard buffer.count >= Wire.headerSize else { return out }
            synced = true
        }
        while true {
            if header == nil {
                guard buffer.count >= Wire.headerSize else { break }
                header = try WireHeader.parse(buffer.prefix(Wire.headerSize))
                buffer.removeFirst(Wire.headerSize)
            }
            guard let h = header, buffer.count >= h.payloadLength else { break }
            out.append((h, Data(buffer.prefix(h.payloadLength))))
            buffer.removeFirst(h.payloadLength)
            header = nil
        }
        if buffer.isEmpty { buffer = Data() } // drop capacity after large payloads
        return out
    }
}

/// TCP connection (Wi-Fi, or loopback via adb reverse).
final class TCPChannel: ByteChannel, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var onClose: (@Sendable (String) -> Void)?
    private var closed = false
    let kind: ChannelKind

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
        if case .hostPort(let host, _) = connection.endpoint, "\(host)".hasPrefix("127.") || "\(host)" == "::1" {
            kind = .usbDebug
        } else {
            kind = .wifi
        }
    }

    var description: String { "\(kind.rawValue) \(connection.endpoint)" }

    func start(onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (String) -> Void) {
        lock.withLock { self.onClose = onClose }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.receive(onData)
            case .failed(let e): self?.finish("failed: \(e)")
            case .cancelled: self?.finish("closed")
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(_ onData: @escaping @Sendable (Data) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty { onData(data) }
            if let error { return self.finish("receive: \(error)") }
            if complete { return self.finish("client closed") }
            self.receive(onData)
        }
    }

    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            completion(error)
            if let error { self?.finish("send: \(error)") }
        })
    }

    func close() {
        finish("closed")
    }

    private func finish(_ reason: String) {
        let handler: (@Sendable (String) -> Void)? = lock.withLock {
            guard !closed else { return nil }
            closed = true
            defer { onClose = nil }
            return onClose
        }
        guard let handler else { return }
        connection.cancel()
        handler(reason)
    }
}
