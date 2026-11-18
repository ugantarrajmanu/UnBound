import UnboundHostCore
import CoreGraphics
import Foundation

let usage = """
unbound-host — use an Android tablet as a Mac display

USAGE
  unbound-host serve        [display options] [--fps N] [--bitrate MBPS] [--port N] [--no-cursor]
  unbound-host probe        [display options] [--cycles N]
  unbound-host capabilities
  unbound-host usb                       list USB devices and which look like Android tablets

DISPLAY OPTIONS
  --width N  --height N  --refresh HZ  --hidpi  --ppi N
  --fps N    stream rate; also sets the display refresh (60 default, 90 for 90 Hz tablets)

  USB-C (no developer mode needed) and Wi-Fi are on by default.
  --no-usbc  don't use the USB-C cable
  --no-wifi  don't accept network connections
  --usb      developer mode instead: `adb reverse` + launch the app (needs USB debugging)

EXAMPLES
  unbound-host serve --fps 90                            # plug in the tablet with a USB-C cable
  unbound-host serve --width 2560 --height 1600          # match a 16:10 tablet
  unbound-host probe --cycles 25                         # create/destroy stress test
"""

struct Arguments {
    var command = "serve"
    var options: HostSessionOptions = {
        var o = HostSessionOptions()
        o.accessory = true                 // USB-C is the primary connection
        return o
    }()
    var cycles = 10

    init(_ argv: [String]) throws {
        var args = argv[...]
        if let first = args.first, !first.hasPrefix("-") { command = first; args = args.dropFirst() }
        func value(_ flag: String) throws -> String {
            guard let v = args.popFirst() else { throw ArgError("missing value for \(flag)") }
            return v
        }
        func int(_ flag: String) throws -> Int {
            guard let n = Int(try value(flag)), n > 0 else { throw ArgError("\(flag) expects a positive integer") }
            return n
        }
        var fpsSet = false, refreshSet = false
        while let flag = args.popFirst() {
            switch flag {
            case "--width": options.display.width = try int(flag)
            case "--height": options.display.height = try int(flag)
            case "--refresh": options.display.refreshRate = Double(try int(flag)); refreshSet = true
            case "--hidpi": options.display.hiDPI = true
            case "--ppi": options.display.pixelsPerInch = Double(try int(flag))
            case "--fps": options.framesPerSecond = try int(flag); fpsSet = true
            case "--bitrate": options.bitrate = try int(flag) * 1_000_000
            case "--port": options.port = UInt16(clamping: try int(flag))
            case "--no-cursor": options.showsCursor = false
            case "--usb": options.usb = true; options.accessory = false   // adb owns the USB port
            case "--aoa": options.accessory = true
            case "--no-usbc", "--no-aoa": options.accessory = false
            case "--no-wifi": options.wifi = false
            case "--cycles": cycles = try int(flag)
            case "-h", "--help": command = "help"
            default: throw ArgError("unknown option \(flag)")
            }
        }
        // One knob: the display refreshes at the stream rate unless told otherwise.
        if fpsSet && !refreshSet { options.display.refreshRate = Double(options.framesPerSecond) }
        if refreshSet && !fpsSet { options.framesPerSecond = Int(options.display.refreshRate) }
        if options.display.width % 2 != 0 || options.display.height % 2 != 0 {
            throw ArgError("width and height must be even (H.264 4:2:0)")
        }
    }
}

struct ArgError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: - Commands

func runCapabilities() {
    print("Architecture : \(Diagnostics.architecture)\(Diagnostics.isTranslated ? " (Rosetta)" : "")")
    print("CPU          : \(Diagnostics.sysctlString("machdep.cpu.brand_string"))")
    print("Model        : \(Diagnostics.sysctlString("hw.model"))")
    print("macOS        : \(ProcessInfo.processInfo.operatingSystemVersionString)")
    let provider = VirtualDisplayProviders.makeDefault()
    print("Display API  : \(provider.identifier) — \(provider.availability())")
    print("Screen Rec.  : \(CGPreflightScreenCaptureAccess() ? "granted" : "not granted")")
    print("Encoders     :")
    for e in Diagnostics.videoEncoders() {
        print("  \(e.codec.padding(toLength: 6, withPad: " ", startingAt: 0)) \(e.isHardware ? "HW" : "SW")  \(e.name)")
    }
    print("Encoder probe:")
    for (w, h) in [(1920, 1200), (2560, 1600), (2880, 1800), (3840, 2400)] {
        print("  " + Diagnostics.probeEncoder(width: w, height: h))
    }
}

/// Create/destroy stress test — the commercial feasibility gate (ADR-002).
/// Ground truth is ScreenCaptureKit (asks WindowServer directly); this process's
/// CoreGraphics display list can be stale after the first cycle on macOS 27.
func runProbe(_ args: Arguments) async -> Int32 {
    let provider = VirtualDisplayProviders.makeDefault()
    let config = args.options.display
    let useSCK = CGPreflightScreenCaptureAccess()
    print("provider=\(provider.identifier) config=\(config) cycles=\(args.cycles) "
          + "verify=\(useSCK ? "ScreenCaptureKit" : "CoreGraphics (grant Screen Recording for accurate results)")")
    var failures = 0
    var createTimes: [Double] = [], visibleTimes: [Double] = [], goneTimes: [Double] = []

    func visible(_ id: CGDirectDisplayID) async -> Bool {
        useSCK ? await ScreenCaptureManager.isDisplayAvailable(id) : DisplayInfo.onlineDisplays().contains(id)
    }
    func wait(_ id: CGDirectDisplayID, present: Bool, timeout: Double) async -> Double? {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if await visible(id) == present { return Date().timeIntervalSince(start) * 1000 }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    for cycle in 1...args.cycles {
        let start = Date()
        do {
            let display = try provider.createDisplay(config) { log("cycle \(cycle): terminated by system") }
            let id = display.displayID
            let created = Date().timeIntervalSince(start) * 1000
            createTimes.append(created)
            guard let shown = await wait(id, present: true, timeout: 5) else {
                failures += 1
                print(String(format: "cycle %2d: FAIL display %u never became visible", cycle, id))
                display.destroy()
                continue
            }
            visibleTimes.append(shown)
            let info = DisplayInfo(id)
            if cycle == 1 {
                print("          \(info)")
                print("          modes: \(DisplayInfo.availableModes(id).joined(separator: ", "))")
            }
            display.destroy()
            guard let gone = await wait(id, present: false, timeout: 5) else {
                failures += 1
                print(String(format: "cycle %2d: FAIL display %u still present 5s after destroy", cycle, id))
                continue
            }
            goneTimes.append(gone)
            print(String(format: "cycle %2d: OK   id=%u create=%.0fms visible=+%.0fms removed=%.0fms",
                         cycle, id, created, shown, gone))
        } catch {
            failures += 1
            print("cycle \(cycle): FAIL \(error)")
        }
    }
    func avg(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
    print(String(format: "RESULT: %d/%d cycles passed | avg create %.0f ms, visible +%.0f ms, removed %.0f ms",
                 args.cycles - failures, args.cycles, avg(createTimes), avg(visibleTimes), avg(goneTimes)))
    return failures == 0 ? 0 : 1
}

func acquireSingleInstanceLock() {
    if let pid = SingleInstance.acquire() {
        log("ERROR: Unbound is already running (pid \(pid)). Stop it first:  kill -INT \(pid)")
        exit(3)
    }
}

func runServe(_ args: Arguments) {
    acquireSingleInstanceLock()
    if !CGPreflightScreenCaptureAccess() {
        CGRequestScreenCaptureAccess()
        log("Screen Recording permission is required for the app running this binary (e.g. Terminal/iTerm).")
        log("Grant it in System Settings › Privacy & Security › Screen Recording, then re-run.")
        exit(2)
    }
    let session = HostSession(options: args.options)

    let signals = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            log("shutting down…")
            Task { await session.stop(); exit(0) }
        }
        source.resume()
        return source
    }
    _ = signals

    Task {
        do {
            try await session.start()
        } catch {
            log("ERROR: \(error)")
            await session.stop()
            exit(1)
        }
    }
    withExtendedLifetime(signals) { dispatchMain() }
}

// MARK: - Entry

do {
    let args = try Arguments(Array(CommandLine.arguments.dropFirst()))
    switch args.command {
    case "serve": runServe(args)
    case "probe":
        Task { exit(await runProbe(args)) }
        dispatchMain()
    case "capabilities": runCapabilities()
    case "usb": AccessoryWatcher.describeDevices().forEach { print($0) }
    default: print(usage)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n\n\(usage)\n".utf8))
    exit(64)
}
