import Foundation

/// USB-C plug-and-play for development builds: watches `adb devices`, and for every
/// newly attached tablet sets up `adb reverse` (so the tablet reaches the host at
/// 127.0.0.1 over the cable) and launches the client app pointed at it.
///
/// Requires USB debugging on the tablet. The consumer path without developer mode
/// (Android Open Accessory / USB networking) is Sprint 4 — see docs/adr/ADR-008.
public final class USBAdbBridge: @unchecked Sendable {
    private let port: UInt16
    private let launchApp: Bool
    private let adbPath: String
    private let queue = DispatchQueue(label: "unbound.usb")
    private var timer: DispatchSourceTimer?
    private var known: Set<String> = []        // serials we've set up (accessed on `queue`)
    private var warnedUnauthorized: Set<String> = []

    public static let clientComponent = "app.unbound.client/.MainActivity"

    public init?(port: UInt16, launchApp: Bool = true) {
        guard let adb = USBAdbBridge.findAdb() else { return nil }
        self.port = port
        self.launchApp = launchApp
        self.adbPath = adb
    }

    public func start() {
        log("usb: watching for tablets via \(adbPath)")
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 2)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        queue.sync {
            for serial in known { _ = run(["-s", serial, "reverse", "--remove", "tcp:\(port)"]) }
            known.removeAll()
        }
    }

    private func poll() {
        guard let output = run(["devices"]) else { return }
        var ready: Set<String> = []
        for line in output.split(separator: "\n").dropFirst() {
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard parts.count >= 2 else { continue }
            let serial = String(parts[0]), state = String(parts[1])
            switch state {
            case "device": ready.insert(serial)
            case "unauthorized":
                if warnedUnauthorized.insert(serial).inserted {
                    log("usb: tablet \(serial) is connected but not authorized — unlock it and tap "
                        + "\u{201C}Allow USB debugging\u{201D}")
                }
            default: break
            }
        }

        for serial in ready.subtracting(known) {
            guard run(["-s", serial, "reverse", "tcp:\(port)", "tcp:\(port)"]) != nil else {
                log("usb: adb reverse failed for \(serial); will retry")
                continue
            }
            known.insert(serial)
            let model = run(["-s", serial, "shell", "getprop", "ro.product.model"])?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? serial
            log("usb: \(model) (\(serial)) connected — tunnel tcp:\(port) ready")
            if launchApp {
                let started = run(["-s", serial, "shell", "am", "start", "-n", Self.clientComponent,
                                   "--es", "host", "127.0.0.1"])
                if started?.contains("Error") ?? true {
                    log("usb: couldn't launch the Unbound app on \(model) — is it installed? "
                        + "(cd android && ./gradlew installDebug)")
                }
            }
        }
        for serial in known.subtracting(ready) {
            known.remove(serial)
            warnedUnauthorized.remove(serial)
            log("usb: tablet \(serial) unplugged")
        }
    }

    @discardableResult
    private func run(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adbPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func findAdb() -> String? {
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let root = env[key] { candidates.append("\(root)/platform-tools/adb") }
        }
        candidates.append(NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb")
        candidates += (env["PATH"] ?? "").split(separator: ":").map { "\($0)/adb" }
        candidates += ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
