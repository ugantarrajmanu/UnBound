import CoreGraphics
import CoreMedia
import Foundation

public func log(_ message: String) {
    let ts = String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
    FileHandle.standardError.write(Data("[\(ts)] \(message)\n".utf8))
}

public struct HostSessionOptions: Sendable {
    public var display = VirtualDisplayConfiguration()
    public var framesPerSecond = 60
    public var bitrate = 12_000_000
    public var port: UInt16 = Wire.defaultPort
    public var showsCursor = true
    /// Development USB: auto `adb reverse` + launch the app (needs USB debugging).
    public var usb = false
    /// Consumer USB-C: Android Open Accessory (no developer mode needed).
    public var accessory = false
    /// Accept tablets over the network (Bonjour-advertised, approval required).
    public var wifi = true
    /// Approves Wi-Fi clients. nil = allow all (CLI development default).
    public var authorizer: HostTransport.Authorizer?
    public init() {}
}

public struct SessionStats: Sendable {
    public var captureFPS: Double
    public var encodeFPS: Double
    public var mbps: Double
    public var framesDropped: Int64
}

/// What the UI needs to know about a running session.
public enum HostEvent: Sendable {
    case displayCreated(DisplayInfo)
    case clientConnected(ClientHello, ChannelKind)
    case clientDisconnected(String)
    case usbStatus(String)
    case stats(SessionStats)
}

/// Wires display → capture → encoder → transport. One session = one virtual display.
public final class HostSession: @unchecked Sendable {
    /// Called on arbitrary threads. Set before `start()`.
    public var onEvent: (@Sendable (HostEvent) -> Void)?
    private func emit(_ event: HostEvent) { onEvent?(event) }

    public let options: HostSessionOptions
    private let provider: any VirtualDisplayProvider
    private var display: (any VirtualDisplay)?
    private var capture: ScreenCaptureManager?
    private var encoder: H264Encoder?
    private var transport: HostTransport?
    private var accessoryWatcher: AccessoryWatcher?
    private var input: InputInjector?
    private var abr: AdaptiveBitrate?
    private var usb: USBAdbBridge?
    private var abrTimer: DispatchSourceTimer?
    private var statsTimer: DispatchSourceTimer?
    private let metrics = PipelineMetrics()

    public init(options: HostSessionOptions, provider: any VirtualDisplayProvider = VirtualDisplayProviders.makeDefault()) {
        self.options = options
        self.provider = provider
    }

    public func start() async throws {
        log("provider: \(provider.identifier)")
        let display = try provider.createDisplay(options.display) {
            log("virtual display terminated by the system")
        }
        self.display = display
        let info = DisplayInfo(display.displayID)
        log("virtual display created — \(info)")
        emit(.displayCreated(info))
        if info.isOnline, !info.isIndependentDesktop { log("WARNING: display is mirrored, not an independent desktop") }
        let scale = options.display.hiDPI ? 2 : 1
        let pixelWidth = info.pixelWidth > 0 ? info.pixelWidth : options.display.width * scale
        let pixelHeight = info.pixelHeight > 0 ? info.pixelHeight : options.display.height * scale

        let encoder = try H264Encoder(settings: EncoderSettings(
            width: pixelWidth, height: pixelHeight,
            framesPerSecond: options.framesPerSecond, bitrate: options.bitrate))
        log("encoder: H.264 \(pixelWidth)x\(pixelHeight) hardware=\(encoder.hardwareDescription) "
            + "lowLatencyRC=\(encoder.usingLowLatencyRateControl) bitrate=\(options.bitrate / 1_000_000)Mbps")
        self.encoder = encoder

        let input = InputInjector(displayID: display.displayID, fallbackBounds: info.bounds,
                                  videoPixelWidth: pixelWidth)
        if !InputInjector.hasPermission(prompt: true) {
            log("input: Accessibility permission not granted — video works, but touch/keyboard won't "
                + "until you allow it in System Settings › Privacy & Security › Accessibility.")
        }
        self.input = input

        var transportOptions = HostTransport.Options()
        transportOptions.tcpPort = options.wifi || options.usb ? options.port : nil
        let transport = HostTransport(options: transportOptions)
        if let authorizer = options.authorizer { transport.authorizer = authorizer }
        var events = MediaTransportEvents()
        events.input = { [weak input] event in input?.handle(event) }
        events.keyframeNeeded = { [weak encoder] reason in
            encoder?.requestKeyframe(repeatLastFrame: reason == .newClient)
        }
        let abr = AdaptiveBitrate(maxBitrate: options.bitrate)
        self.abr = abr
        events.clientConnected = { [weak self, weak transport] hello in
            // Every new client starts at full quality; ABR backs off if its link can't keep up.
            abr.reset()
            encoder.setBitrate(abr.bitrate)
            guard let hello else { return }
            if hello.pixelWidth * pixelHeight != hello.pixelHeight * pixelWidth {
                log("hint: tablet is \(hello.pixelWidth)x\(hello.pixelHeight); restart with "
                    + "--width \(hello.pixelWidth) --height \(hello.pixelHeight) to avoid letterboxing")
            }
            let kind = transport?.activeClient?.1 ?? .wifi
            self?.emit(.clientConnected(hello, kind))
        }
        events.clientDisconnected = { [weak self, weak input] reason in
            input?.reset()
            log("transport: client disconnected (\(reason))")
            self?.emit(.clientDisconnected(reason))
        }
        transport.events = events
        self.transport = transport

        let metrics = self.metrics
        encoder.onConfig = { [weak transport] config in transport?.sendCodecConfig(config) }
        encoder.onFrame = { [weak transport] frame in
            metrics.recordEncoded(frame)
            transport?.sendFrame(frame)
        }

        try transport.start()
        let addresses = NetworkAddresses.lanIPv4()
        log("listening on tcp/\(options.port)")
        log("  Wi-Fi: on the tablet enter \(addresses.isEmpty ? "this Mac's IP" : addresses.joined(separator: " or "))")
        log("  USB:   run `adb reverse tcp:\(options.port) tcp:\(options.port)` and enter 127.0.0.1")

        let capture = ScreenCaptureManager(
            onFrame: { [weak encoder] buffer, pts in
                metrics.recordCaptured()
                encoder?.encode(buffer, presentationTime: pts)
            },
            onStop: { error in log("capture stopped: \(error)") })
        try await capture.start(displayID: display.displayID, configuration: CaptureConfiguration(
            pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            framesPerSecond: options.framesPerSecond, showsCursor: options.showsCursor))
        self.capture = capture
        log("capturing display \(display.displayID). Drag a window onto it (it's to the "
            + "\(info.bounds.minX >= 0 ? "right" : "left") of your main display).")
        startStatsTimer()
        startAdaptiveBitrate()
        if options.accessory {
            let watcher = AccessoryWatcher { [weak transport] channel in transport?.accept(channel) }
            watcher.onStatus = { [weak self] message in self?.emit(.usbStatus(message)) }
            watcher.start()
            accessoryWatcher = watcher
        }
        if options.usb {
            if let bridge = USBAdbBridge(port: options.port) {
                bridge.start()
                usb = bridge
            } else {
                log("usb: adb not found (install Android platform-tools or set ANDROID_HOME); USB auto-connect disabled")
            }
        }
    }

    /// Simple AIMD on top of TCP until WebRTC congestion control lands (Sprint 2).
    private func startAdaptiveBitrate() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self, let abr = self.abr, let transport = self.transport, let encoder = self.encoder else { return }
            let t = transport.statistics
            guard t.connected else { return }
            if let newRate = abr.update(framesDropped: t.congestionDrops, queuedBytes: t.queuedBytes) {
                encoder.setBitrate(newRate)
                log(String(format: "abr: bitrate → %.1f Mbps", Double(newRate) / 1_000_000))
            }
        }
        timer.resume()
        abrTimer = timer
    }

    public func stop() async {
        statsTimer?.cancel()
        abrTimer?.cancel()
        usb?.stop()
        usb = nil
        await capture?.stop()
        encoder?.invalidate()
        accessoryWatcher?.stop()
        accessoryWatcher = nil
        transport?.stop()
        if let display {
            let id = display.displayID
            display.destroy()
            log("virtual display \(id) destroyed (offline=\(DisplayInfo.waitUntilOffline(id, timeout: 2)))")
        }
        input?.reset()
        capture = nil; encoder = nil; transport = nil; display = nil; input = nil
    }

    private func startStatsTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let snapshot = metrics.drain(seconds: 2)
            let t = transport?.statistics ?? TransportStatistics()
            self.emit(.stats(SessionStats(captureFPS: snapshot.captureFPS, encodeFPS: snapshot.encodeFPS,
                                          mbps: snapshot.mbps, framesDropped: t.framesDropped)))
            log(String(format: "stats: capture %.1f fps | encode %.1f fps, avg %.1f ms, %.1f Mbps, %d IDR | "
                       + "client=%@ sent=%lld dropped=%lld queued=%dKB",
                       snapshot.captureFPS, snapshot.encodeFPS, snapshot.avgEncodeMillis, snapshot.mbps,
                       snapshot.keyframes, t.connected ? "yes" : "no", t.framesSent, t.framesDropped,
                       t.queuedBytes / 1024))
        }
        timer.resume()
        statsTimer = timer
    }
}

/// Multiplicative decrease on congestion, slow additive-ish increase when clear.
final class AdaptiveBitrate: @unchecked Sendable {
    let maxBitrate: Int
    let minBitrate: Int
    private let lock = NSLock()
    private var current: Int
    private var lastDropped: Int64 = 0
    private var clearTicks = 0

    init(maxBitrate: Int, minBitrate: Int = 1_500_000) {
        self.maxBitrate = maxBitrate
        self.minBitrate = min(minBitrate, maxBitrate)
        current = maxBitrate
    }

    var bitrate: Int { lock.withLock { current } }

    func reset() { lock.withLock { current = maxBitrate; lastDropped = 0; clearTicks = 0 } }

    /// Called every 500 ms. Returns a new bitrate when it should change.
    func update(framesDropped: Int64, queuedBytes: Int) -> Int? {
        lock.withLock {
            let newDrops = framesDropped - lastDropped
            lastDropped = framesDropped
            let bytesPerTick = current / 8 / 2
            let congested = newDrops > 0 || queuedBytes > bytesPerTick / 2
            var next = current
            if congested {
                clearTicks = 0
                next = max(minBitrate, Int((Double(current) * 0.7).rounded()))
            } else if queuedBytes < 32 * 1024 {
                clearTicks += 1
                if clearTicks >= 6 { // 3 s of clear link
                    clearTicks = 0
                    next = min(maxBitrate, Int((Double(current) * 1.15).rounded()))
                }
            }
            guard next != current else { return nil }
            current = next
            return next
        }
    }
}

final class PipelineMetrics: @unchecked Sendable {
    struct Snapshot { var captureFPS, encodeFPS, avgEncodeMillis, mbps: Double; var keyframes: Int }
    private let lock = NSLock()
    private var captured = 0, encoded = 0, keyframes = 0, bytes = 0
    private var encodeMicros: Int64 = 0

    func recordCaptured() { lock.withLock { captured += 1 } }
    func recordEncoded(_ f: EncodedFrame) {
        lock.withLock {
            encoded += 1; bytes += f.annexB.count; encodeMicros += f.encodeDurationMicros
            if f.isKeyframe { keyframes += 1 }
        }
    }
    func drain(seconds: Double) -> Snapshot {
        lock.withLock {
            defer { captured = 0; encoded = 0; keyframes = 0; bytes = 0; encodeMicros = 0 }
            return Snapshot(captureFPS: Double(captured) / seconds, encodeFPS: Double(encoded) / seconds,
                            avgEncodeMillis: encoded > 0 ? Double(encodeMicros) / Double(encoded) / 1000 : 0,
                            mbps: Double(bytes * 8) / seconds / 1_000_000, keyframes: keyframes)
        }
    }
}
