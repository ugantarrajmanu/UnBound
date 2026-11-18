import Foundation
import Network

/// Accepts tablets from every path (USB-C accessory, Wi-Fi, adb loopback), runs the
/// approval gate, and keeps exactly one active client. A pending (unapproved) client
/// never disturbs the active one.
public final class HostTransport: MediaTransport, @unchecked Sendable {
    public struct Options: Sendable {
        /// Listen for TCP (Wi-Fi and adb). nil disables networking entirely.
        public var tcpPort: UInt16? = Wire.defaultPort
        /// Advertise over Bonjour so tablets find the Mac without typing an IP.
        public var advertise = true
        public var hostName = Host.current().localizedName ?? "Mac"
        public var maxQueuedBytes = 1_500_000
        public init() {}
    }

    /// Decide whether an untrusted (Wi-Fi) client may connect. Call `reply` exactly once.
    public typealias Authorizer = @Sendable (_ hello: ClientHello, _ kind: ChannelKind,
                                             _ reply: @escaping @Sendable (Bool) -> Void) -> Void

    public var events: MediaTransportEvents {
        get { lock.withLock { _events } }
        set { lock.withLock { _events = newValue } }
    }
    public var authorizer: Authorizer {
        get { lock.withLock { _authorizer } }
        set { lock.withLock { _authorizer = newValue } }
    }

    private let options: Options
    private let queue = DispatchQueue(label: "unbound.transport", qos: .userInteractive)
    private let lock = NSLock()
    private var _events = MediaTransportEvents()
    private var _authorizer: Authorizer = { _, _, reply in reply(true) }
    private var listener: NWListener?
    private var active: ClientSession?
    private var pending: [ObjectIdentifier: ClientSession] = [:]
    private var lastConfig: CodecConfig?

    public init(options: Options = Options()) {
        self.options = options
    }

    public var statistics: TransportStatistics {
        lock.withLock { active?.statistics } ?? TransportStatistics()
    }

    public var activeClient: (ClientHello, ChannelKind)? {
        lock.withLock {
            guard let a = active, let hello = a.hello else { return nil }
            return (hello, a.channel.kind)
        }
    }

    public func start() throws {
        guard let port = options.tcpPort else { return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        params.serviceClass = .interactiveVideo
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw NWError.posix(.EINVAL) }
        let listener = try NWListener(using: params, on: nwPort)
        if options.advertise {
            listener.service = NWListener.Service(name: options.hostName, type: UnboundProduct.bonjourType)
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            self.accept(TCPChannel(connection, queue: self.queue))
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state { log("transport: listener failed: \(error)") }
        }
        listener.start(queue: queue)
        lock.withLock { self.listener = listener }
    }

    public func stop() {
        let (listener, sessions) = lock.withLock { () -> (NWListener?, [ClientSession]) in
            defer { self.listener = nil; active = nil; pending.removeAll() }
            return (self.listener, Array(pending.values) + [active].compactMap { $0 })
        }
        listener?.cancel()
        sessions.forEach { $0.close() }
    }

    /// Entry point for every new channel (TCP listener, USB accessory watcher).
    public func accept(_ channel: any ByteChannel) {
        let handlers = ClientSession.Handlers(
            hello: { [weak self] session, hello in self?.helloReceived(session, hello) },
            closed: { [weak self] session, reason in self?.sessionClosed(session, reason) },
            keyframeNeeded: { [weak self] reason in self?.events.keyframeNeeded(reason) },
            input: { [weak self] event in self?.events.input(event) })
        let session = ClientSession(channel: channel, maxQueuedBytes: options.maxQueuedBytes, handlers: handlers)
        lock.withLock { pending[ObjectIdentifier(session)] = session }
        log("transport: \(channel) connected, waiting for hello")
        session.start(hostName: options.hostName)

        // A network client that never says hello is dropped. USB accessory clients get no
        // deadline: the person may still be answering Android's "Open Unbound?" prompt.
        guard channel.kind != .usbAccessory else { return }
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak session] in
            guard let self, let session, session.state == .awaitingHello else { return }
            log("transport: \(channel) sent no hello; closing")
            self.lock.withLock { _ = self.pending.removeValue(forKey: ObjectIdentifier(session)) }
            session.close()
        }
    }

    public func sendCodecConfig(_ config: CodecConfig) {
        let target = lock.withLock { () -> ClientSession? in
            lastConfig = config
            return active
        }
        target?.sendCodecConfig(config)
    }

    public func sendFrame(_ frame: EncodedFrame) {
        lock.withLock { active }?.sendFrame(frame)
    }

    // MARK: - Private

    private func helloReceived(_ session: ClientSession, _ hello: ClientHello) {
        log("transport: hello from \(hello) via \(session.channel.kind.rawValue)")
        guard hello.protocolVersion == Int(Wire.version) else {
            session.reject(reason: "Please update the app (protocol \(hello.protocolVersion), Mac speaks \(Wire.version))")
            return
        }
        let kind = session.channel.kind
        if kind.isTrusted {
            promote(session)
        } else {
            authorizer(hello, kind) { [weak self, weak session] allowed in
                guard let self, let session else { return }
                if allowed {
                    self.promote(session)
                } else {
                    log("transport: \(hello.model) was not allowed to connect")
                    self.lock.withLock { _ = self.pending.removeValue(forKey: ObjectIdentifier(session)) }
                    session.reject(reason: "The Mac declined the connection")
                }
            }
        }
    }

    private func promote(_ session: ClientSession) {
        let (previous, config) = lock.withLock { () -> (ClientSession?, CodecConfig?) in
            pending.removeValue(forKey: ObjectIdentifier(session))
            guard session.state == .pendingApproval else { return (nil, nil) }
            let previous = active
            active = session
            return (previous, lastConfig)
        }
        guard session.state == .pendingApproval else { return }
        if let previous {
            log("transport: replacing \(previous.channel) with \(session.channel)")
            previous.close()
        }
        session.activate(lastConfig: config)
        events.clientConnected(session.hello)
    }

    private func sessionClosed(_ session: ClientSession, _ reason: String) {
        let wasActive = lock.withLock { () -> Bool in
            pending.removeValue(forKey: ObjectIdentifier(session))
            guard active === session else { return false }
            active = nil
            return true
        }
        if wasActive { events.clientDisconnected("\(session.channel.kind.rawValue): \(reason)") }
    }
}
