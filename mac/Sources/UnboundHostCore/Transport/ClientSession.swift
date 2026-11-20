import Foundation

/// Protocol state for one connected tablet, independent of the underlying channel.
///
/// Lifecycle: `start()` sends the host HELLO → client answers with its HELLO →
/// owner approves (`activate`) or rejects (`reject`) → video flows only when active.
final class ClientSession: @unchecked Sendable {
    struct Handlers: Sendable {
        var hello: @Sendable (ClientSession, ClientHello) -> Void
        var closed: @Sendable (ClientSession, String) -> Void
        var keyframeNeeded: @Sendable (KeyframeReason) -> Void
        var input: @Sendable (InputEvent) -> Void
    }

    enum State { case awaitingHello, pendingApproval, active, closed }

    let channel: any ByteChannel
    private let handlers: Handlers
    private let maxQueuedBytes: Int
    private let lock = NSLock()
    private var parser = FrameParser()
    private var _state = State.awaitingHello
    private var _hello: ClientHello?
    private var stats = TransportStatistics(connected: true)
    private var awaitingKeyframe = true
    private var keyframeRequested = true

    init(channel: any ByteChannel, maxQueuedBytes: Int, handlers: Handlers) {
        self.channel = channel
        self.maxQueuedBytes = maxQueuedBytes
        self.handlers = handlers
    }

    var state: State { lock.withLock { _state } }
    var hello: ClientHello? { lock.withLock { _hello } }
    var statistics: TransportStatistics {
        lock.withLock { var s = stats; s.client = _hello; s.connected = _state == .active; return s }
    }

    func start(hostName: String) {
        channel.start(
            onData: { [weak self] data in self?.receive(data) },
            onClose: { [weak self] reason in self?.closed(reason) })
        send(WireMessage.hostHello(hostName: hostName))
    }

    func activate(lastConfig: CodecConfig?) {
        lock.withLock { _state = .active; awaitingKeyframe = true; keyframeRequested = true }
        if let lastConfig { sendCodecConfig(lastConfig) }
        handlers.keyframeNeeded(.newClient)
    }

    func reject(reason: String) {
        send(WireMessage(type: .goodbye, payload: Data(reason.utf8)))
        // Give the goodbye a moment to flush before closing.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [channel] in channel.close() }
    }

    func close() {
        send(WireMessage(type: .goodbye))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [channel] in channel.close() }
    }

    // MARK: Outgoing media

    func sendCodecConfig(_ config: CodecConfig) {
        guard state == .active else { return }
        send(WireMessage.codecConfig(config))
    }

    /// Congestion policy (see docs/protocol.md): over the limit → drop (keyframes too) and
    /// resync; while resyncing, drop deltas until the queue drains to half, then request one IDR.
    func sendFrame(_ frame: EncodedFrame) {
        enum Decision { case send, drop, dropAndRequestKeyframe }
        let decision: Decision = lock.withLock {
            guard _state == .active else { return .drop }
            if stats.queuedBytes > maxQueuedBytes {
                stats.framesDropped += 1
                stats.congestionDrops += 1
                awaitingKeyframe = true
                keyframeRequested = false
                return .drop
            }
            guard awaitingKeyframe else { return .send }
            if frame.isKeyframe {
                awaitingKeyframe = false
                keyframeRequested = false
                return .send
            }
            stats.framesDropped += 1
            if !keyframeRequested, stats.queuedBytes < maxQueuedBytes / 2 {
                keyframeRequested = true
                return .dropAndRequestKeyframe
            }
            return .drop
        }
        switch decision {
        case .send: send(WireMessage.videoFrame(frame), countsAsFrame: true)
        case .drop: break
        case .dropAndRequestKeyframe: handlers.keyframeNeeded(.congestionRecovered)
        }
    }

    private func send(_ message: WireMessage, countsAsFrame: Bool = false) {
        let bytes = message.serialized()
        let ok = lock.withLock { () -> Bool in
            guard _state != .closed else { return false }
            stats.queuedBytes += bytes.count
            return true
        }
        guard ok else { return }
        channel.send(bytes) { [weak self] error in
            guard let self else { return }
            self.lock.withLock {
                self.stats.queuedBytes -= bytes.count
                if error == nil {
                    self.stats.bytesSent += Int64(bytes.count)
                    if countsAsFrame { self.stats.framesSent += 1 }
                }
            }
        }
    }

    // MARK: Incoming

    private func receive(_ data: Data) {
        let messages: [(WireHeader, Data)]
        do {
            messages = try lock.withLock { try parser.append(data) }
        } catch WireHeader.ParseError.outdatedPeer {
            log("session \(channel): the tablet app is outdated. Install the latest: \(UnboundProduct.downloadURL)")
            channel.close()
            return
        } catch {
            log("session \(channel): protocol error \(error)")
            channel.close()
            return
        }
        for (header, payload) in messages { handle(header, payload) }
    }

    private func handle(_ header: WireHeader, _ payload: Data) {
        switch header.type {
        case .hello:
            guard let hello = try? ClientHello.parse(payload) else { return channel.close() }
            let first = lock.withLock { () -> Bool in
                _hello = hello
                guard _state == .awaitingHello else { return false }
                _state = .pendingApproval
                return true
            }
            if first { handlers.hello(self, hello) }
        case .requestKeyframe:
            guard state == .active else { return }
            lock.withLock { awaitingKeyframe = true; keyframeRequested = true }
            handlers.keyframeNeeded(.clientRequest)
        case .ping:
            send(WireMessage(type: .pong, timestampMicros: header.timestampMicros))
        case .pointer, .scroll, .key:
            // Input is only honoured from an approved, active client.
            guard state == .active, let event = try? InputEvent.parse(type: header.type, payload: payload) else { return }
            handlers.input(event)
        case .goodbye:
            channel.close()
        default:
            break
        }
    }

    private func closed(_ reason: String) {
        let wasOpen = lock.withLock { () -> Bool in
            guard _state != .closed else { return false }
            _state = .closed
            return true
        }
        if wasOpen { handlers.closed(self, reason) }
    }
}
