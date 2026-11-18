import UnboundUSB
import Foundation

/// Consumer USB-C path (no developer mode): watches for Android devices, switches them
/// into Android Open Accessory mode, and opens the accessory as a ByteChannel.
public final class AccessoryWatcher: @unchecked Sendable {
    public struct Identity: Sendable {
        public var manufacturer = "Unbound"
        public var model = "Unbound Display"          // must match android/res/xml/accessory_filter.xml
        public var description = "Use this tablet as a display for your Mac"
        public var version = "1"
        /// Shown by Android when the app isn't installed ("Learn more at …").
        public var uri = UnboundProduct.downloadURL
        public var serial = "unbound-host"
        public init() {}
    }

    private let identity: Identity
    /// User-facing USB status (connected, needs attention). Called on a background queue.
    public var onStatus: (@Sendable (String) -> Void)?
    private let onChannel: @Sendable (any ByteChannel) -> Void
    private let queue = DispatchQueue(label: "unbound.usb.aoa")
    private var timer: DispatchSourceTimer?
    // Accessed on `queue`:
    private var open: Set<UInt64> = []               // registry IDs with a live channel
    private var switchAttempts: [UInt64: Date] = [:]  // registry ID → last AOA attempt
    private var openFailures: [UInt64: Date] = [:]

    public init(identity: Identity = Identity(), onChannel: @escaping @Sendable (any ByteChannel) -> Void) {
        self.identity = identity
        self.onChannel = onChannel
    }

    public func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
        log("usb: waiting for a tablet on USB-C")
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    private func poll() {
        let devices = UNBUSB.connectedDevices()
        let present = Set(devices.map(\.registryID))
        switchAttempts = switchAttempts.filter { present.contains($0.key) }
        openFailures = openFailures.filter { present.contains($0.key) }

        for device in devices {
            if device.isAccessoryMode {
                openAccessory(device)
            } else if Self.isAndroidCandidate(device) {
                switchToAccessory(device)
            }
        }
    }

    private func switchToAccessory(_ device: UNBUSBDeviceInfo) {
        // One attempt per plug-in; retry every 15 s in case the user was mid-dialog.
        if let last = switchAttempts[device.registryID], Date().timeIntervalSince(last) < 15 { return }
        switchAttempts[device.registryID] = Date()
        do {
            let version = try Self.startAccessory(device, identity)
            log("usb: \(device.productName) switched to accessory mode (AOA v\(version))")
            onStatus?("Tablet found — tap “OK” on the tablet to open Unbound")
        } catch {
            log("usb: \(device.productName) did not accept accessory mode: \(error.localizedDescription)")
            onStatus?(error.localizedDescription)
        }
    }

    private func openAccessory(_ device: UNBUSBDeviceInfo) {
        let id = device.registryID
        guard !open.contains(id) else { return }
        if let failed = openFailures[id], Date().timeIntervalSince(failed) < 3 { return }
        do {
            let connection = try UNBAccessoryConnection(device: device)
            open.insert(id)
            let channel = AccessoryChannel(connection: connection, name: device.productName) { [weak self] in
                guard let self else { return }
                self.queue.async { self.open.remove(id) }
            }
            log("usb: accessory connected")
            onChannel(channel)
        } catch {
            openFailures[id] = Date()
            log("usb: couldn't open accessory: \(error.localizedDescription)")
            onStatus?(error.localizedDescription)
        }
    }

    static func startAccessory(_ device: UNBUSBDeviceInfo, _ identity: Identity) throws -> Int {
        var error: NSError?
        let version = UNBUSB.startAccessoryMode(device, manufacturer: identity.manufacturer, model: identity.model,
                                                description: identity.description, version: identity.version,
                                                uri: identity.uri, serial: identity.serial, error: &error)
        if version == 0 { throw error ?? NSError(domain: "UNBUSB", code: 2) }
        return version
    }

    /// Vendors that ship Android phones/tablets. Many also make non-Android hardware
    /// (Samsung SSDs and monitors share 0x04E8), so we also look at the interfaces.
    static let androidVendors: Set<UInt16> = [
        0x18D1, 0x04E8, 0x22B8, 0x2717, 0x12D1, 0x339B, 0x17EF, 0x0BB4, 0x1004, 0x054C, 0x0FCE,
        0x2A70, 0x05C6, 0x0E8D, 0x19D2, 0x2D95, 0x22D9, 0x2A45, 0x0B05, 0x1BBB, 0x2AE5, 0x0489,
        0x2207, 0x1F3A, 0x0502, 0x1949, 0x29A9, 0x2E04, 0x1EBF, 0x109B, 0x2340, 0x0414,
    ]

    /// Interface classes that mean "this is a disk/keyboard/camera/hub, leave it alone".
    static let excludedInterfaceClasses: Set<Int> = [0x01, 0x03, 0x07, 0x08, 0x09, 0x0E, 0x10, 0x11]

    static func isAndroidCandidate(_ d: UNBUSBDeviceInfo) -> Bool {
        isAndroidCandidate(vendorID: d.vendorID, interfaceClasses: d.interfaceClasses.map(\.intValue))
    }

    static func isAndroidCandidate(vendorID: UInt16, interfaceClasses: [Int]) -> Bool {
        guard androidVendors.contains(vendorID) else { return false }
        return !interfaceClasses.contains { excludedInterfaceClasses.contains($0) }
    }

    /// Diagnostic listing for `unbound-host usb`.
    public static func describeDevices() -> [String] {
        UNBUSB.connectedDevices().map { d in
            let role = d.isAccessoryMode ? "ACCESSORY MODE" : (isAndroidCandidate(d) ? "android candidate" : "-")
            let classes = d.interfaceClasses.map { String(format: "%02X", $0.intValue) }.joined(separator: ",")
            return String(format: "%04X:%04X  %-32@ interfaces[%@]  %@", d.vendorID, d.productID,
                          d.productName as NSString, classes as NSString, role as NSString)
        }
    }
}

/// ByteChannel over the accessory's bulk pipes, with a reader thread and a serial writer.
final class AccessoryChannel: ByteChannel, @unchecked Sendable {
    let kind: ChannelKind = .usbAccessory
    let name: String
    private let connection: UNBAccessoryConnection
    private let writer = DispatchQueue(label: "unbound.usb.write", qos: .userInteractive)
    private let onFinish: @Sendable () -> Void
    private let lock = NSLock()
    private var closed = false
    private var onClose: (@Sendable (String) -> Void)?

    init(connection: UNBAccessoryConnection, name: String, onFinish: @escaping @Sendable () -> Void) {
        self.connection = connection
        self.name = name
        self.onFinish = onFinish
    }

    var description: String { "USB-C \(name)" }

    func start(onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (String) -> Void) {
        lock.withLock { self.onClose = onClose }
        let thread = Thread { [self] in
            let buffer = NSMutableData(length: 64 * 1024)!
            while true {
                buffer.length = 64 * 1024
                var error: NSError?
                let n = connection.read(into: buffer, error: &error)
                if n < 0 {
                    finish("usb read: \(error?.localizedDescription ?? "closed")")
                    return
                }
                if n > 0 { onData(Data(bytes: buffer.bytes, count: n)) }
            }
        }
        thread.name = "unbound.usb.read"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        writer.async { [self] in
            if lock.withLock({ closed }) { return completion(ChannelClosed()) }
            do {
                try connection.write(data)
                completion(nil)
            } catch {
                completion(error)
                finish("usb write: \(error.localizedDescription)")
            }
        }
    }

    func close() { finish("closed") }

    private func finish(_ reason: String) {
        let (wasOpen, handler) = lock.withLock { () -> (Bool, (@Sendable (String) -> Void)?) in
            guard !closed else { return (false, nil) }
            closed = true
            defer { onClose = nil }
            return (true, onClose)
        }
        guard wasOpen else { return }
        connection.close()
        onFinish()
        handler?(reason)
    }
}
