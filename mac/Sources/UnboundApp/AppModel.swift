import AppKit
import ApplicationServices
import CoreGraphics
import ServiceManagement
import SwiftUI
import UnboundHostCore

/// Display presets offered in the menu. `hiDPI` presets render at 2× for Retina sharpness.
struct DisplayPreset: Identifiable, Hashable {
    let id: String
    let title: String
    let width: Int
    let height: Int
    let hiDPI: Bool

    static let all: [DisplayPreset] = [
        .init(id: "1920x1200", title: "1920 × 1200", width: 1920, height: 1200, hiDPI: false),
        .init(id: "2304x1440", title: "2304 × 1440", width: 2304, height: 1440, hiDPI: false),
        .init(id: "2560x1600", title: "2560 × 1600", width: 2560, height: 1600, hiDPI: false),
        .init(id: "r1152x720", title: "Retina 1152 × 720", width: 1152, height: 720, hiDPI: true),
        .init(id: "r1280x800", title: "Retina 1280 × 800", width: 1280, height: 800, hiDPI: true),
        .init(id: "r1440x900", title: "Retina 1440 × 900", width: 1440, height: 900, hiDPI: true),
    ]
    static let `default` = all[0]
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case off
        case starting
        case waiting                         // display up, no tablet yet
        case connected(name: String, via: String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .off
    @Published private(set) var stats: SessionStats?
    @Published private(set) var usbMessage: String?
    @Published private(set) var hasScreenRecording = CGPreflightScreenCaptureAccess()
    @Published private(set) var hasAccessibility = AXIsProcessTrusted()

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "enabled"); enabled ? start() : stop() } }
    @Published var presetID: String { didSet { defaults.set(presetID, forKey: "preset"); restartIfRunning() } }
    @Published var fps: Int { didSet { defaults.set(fps, forKey: "fps"); restartIfRunning() } }
    @Published var wifi: Bool { didSet { defaults.set(wifi, forKey: "wifi"); restartIfRunning() } }
    @Published var developerUSB: Bool { didSet { defaults.set(developerUSB, forKey: "developerUSB"); restartIfRunning() } }
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet { setLaunchAtLogin(launchAtLogin) }
    }

    private let defaults = UserDefaults.standard
    private var session: HostSession?
    private var permissionTimer: Timer?

    init() {
        defaults.register(defaults: ["enabled": true, "preset": DisplayPreset.default.id, "fps": 60, "wifi": true,
                                     "developerUSB": false])
        enabled = defaults.bool(forKey: "enabled")
        presetID = defaults.string(forKey: "preset") ?? DisplayPreset.default.id
        fps = defaults.integer(forKey: "fps")
        wifi = defaults.bool(forKey: "wifi")
        developerUSB = defaults.bool(forKey: "developerUSB")

        // Permissions can be granted in System Settings at any time; keep the UI current.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
        if enabled { start() }
    }

    var preset: DisplayPreset { DisplayPreset.all.first { $0.id == presetID } ?? .default }

    var statusLine: String {
        switch phase {
        case .off: "Off"
        case .starting: "Starting…"
        case .waiting: usbMessage ?? "Waiting for a tablet"
        case .connected(let name, let via): "Connected to \(name) via \(via)"
        case .failed(let message): message
        }
    }

    var isConnected: Bool { if case .connected = phase { true } else { false } }

    // MARK: - Session

    func start() {
        guard session == nil else { return }
        refreshPermissions()
        guard hasScreenRecording else {
            phase = .failed("Screen Recording permission is needed")
            return
        }
        if let pid = SingleInstance.acquire() {
            phase = .failed("Another Unbound host is running (pid \(pid)). Quit it first.")
            return
        }

        var options = HostSessionOptions()
        options.display.width = preset.width
        options.display.height = preset.height
        options.display.hiDPI = preset.hiDPI
        options.display.name = "Unbound"
        options.display.refreshRate = Double(fps)
        options.framesPerSecond = fps
        options.accessory = true
        options.wifi = wifi
        options.usb = developerUSB
        options.authorizer = { hello, kind, reply in
            Task { @MainActor in reply(Approvals.shared.authorize(hello, kind)) }
        }

        let session = HostSession(options: options)
        session.onEvent = { [weak self] event in Task { @MainActor in self?.handle(event) } }
        self.session = session
        phase = .starting
        usbMessage = nil
        Task {
            do {
                try await session.start()
                if case .starting = self.phase { self.phase = .waiting }
            } catch {
                await session.stop()
                self.session = nil
                self.phase = .failed("\(error)")
            }
        }
    }

    func stop() {
        guard let session else { phase = .off; return }
        self.session = nil
        phase = .off
        stats = nil
        Task { await session.stop() }
    }

    private func restartIfRunning() {
        guard session != nil else { return }
        let old = session
        session = nil
        phase = .starting
        Task {
            await old?.stop()
            self.start()
        }
    }

    private func handle(_ event: HostEvent) {
        switch event {
        case .displayCreated:
            phase = .waiting
        case .clientConnected(let hello, let kind):
            usbMessage = nil
            phase = .connected(name: hello.model, via: kind.rawValue)
        case .clientDisconnected:
            stats = nil
            if session != nil { phase = .waiting }
        case .usbStatus(let message):
            usbMessage = message
        case .stats(let s):
            stats = isConnected ? s : nil
        }
    }

    // MARK: - Permissions

    func refreshPermissions() {
        let screen = CGPreflightScreenCaptureAccess()
        let ax = AXIsProcessTrusted()
        if screen != hasScreenRecording { hasScreenRecording = screen }
        if ax != hasAccessibility { hasAccessibility = ax }
    }

    func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            openSettings("Privacy_ScreenCapture")
        }
    }

    func requestAccessibility() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        if !AXIsProcessTrustedWithOptions([key: true] as CFDictionary) {
            openSettings("Privacy_Accessibility")
        }
    }

    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Screen Recording only takes effect after a relaunch.
    func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", path]
        try? task.run()
        NSApp.terminate(nil)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log("launch at login: \(error)")
        }
    }

    func openDownloadPage() {
        if let url = URL(string: UnboundProduct.downloadURL) { NSWorkspace.shared.open(url) }
    }
}

/// Wi-Fi approval with "always allow" memory. USB connections never reach here (physically trusted).
@MainActor
final class Approvals {
    static let shared = Approvals()
    private let key = "trustedDevices"

    func authorize(_ hello: ClientHello, _ kind: ChannelKind) -> Bool {
        var trusted = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        if !hello.deviceID.isEmpty, trusted.contains(hello.deviceID) { return true }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Allow “\(hello.model)” to use this Mac as a display?"
        alert.informativeText = "It's connecting over \(kind.rawValue). It will show the Unbound display "
            + "and can control the mouse and keyboard while connected."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Always allow this tablet"
        let allowed = alert.runModal() == .alertFirstButtonReturn
        if allowed, alert.suppressionButton?.state == .on, !hello.deviceID.isEmpty {
            trusted.insert(hello.deviceID)
            UserDefaults.standard.set(Array(trusted), forKey: key)
        }
        return allowed
    }

    func forgetAll() { UserDefaults.standard.removeObject(forKey: key) }
}
