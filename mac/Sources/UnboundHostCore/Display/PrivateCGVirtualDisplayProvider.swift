import CGVirtualDisplayBridge
import CoreGraphics
import Foundation

/// Provider backed by the undocumented CGVirtualDisplay API (commercial feasibility gate).
public struct PrivateCGVirtualDisplayProvider: VirtualDisplayProvider {
    public var onlineTimeout: TimeInterval

    public init(onlineTimeout: TimeInterval = 0.75) {
        self.onlineTimeout = onlineTimeout
    }

    public var identifier: String { "private-cgvirtualdisplay" }

    public func availability() -> VirtualDisplayAvailability {
        let missing = UNBVirtualDisplay.missingAPIs()
        return missing.isEmpty ? .available : .unavailable(reason: "missing \(missing.joined(separator: ", "))")
    }

    public func createDisplay(
        _ configuration: VirtualDisplayConfiguration,
        onTerminated: @escaping @Sendable () -> Void
    ) throws -> any VirtualDisplay {
        let native: UNBVirtualDisplay
        do {
            native = try UNBVirtualDisplay(
                name: configuration.name,
                width: UInt(configuration.width),
                height: UInt(configuration.height),
                refreshRate: configuration.refreshRate,
                hiDPI: configuration.hiDPI,
                sizeInMillimeters: configuration.sizeInMillimeters,
                serialNumber: configuration.serialNumber,
                terminationHandler: onTerminated
            )
        } catch let error as UNBVirtualDisplayError {
            switch error.code {
            case .unsupported: throw VirtualDisplayError.unsupported(error.localizedDescription)
            case .applySettingsFailed: throw VirtualDisplayError.applySettingsFailed(error.localizedDescription)
            case .creationFailed:
                // Observed on macOS 27: a display with the same vendor/product/serial already exists
                // (e.g. another unbound-host instance is running).
                throw VirtualDisplayError.creationFailed(error.localizedDescription
                    + " — is another unbound-host already running? Only one display per serial number can exist.")
            default: throw VirtualDisplayError.creationFailed(error.localizedDescription)
            }
        }

        let display = PrivateCGVirtualDisplay(native: native, configuration: configuration)
        if !DisplayInfo.waitUntilOnline(display.displayID, timeout: onlineTimeout) {
            // Known issue (macOS 27): this process's CG display list can stay stale
            // after the first create/destroy. ScreenCaptureKit is the ground truth.
            log("note: display \(display.displayID) not yet visible in this process's display list; "
                + "relying on ScreenCaptureKit to confirm it")
        } else {
            do {
                try DisplayModeManager.select(configuration, on: display.displayID)
            } catch {
                log("warning: could not select requested mode \(configuration): \(error)")
            }
        }
        return display
    }
}

final class PrivateCGVirtualDisplay: VirtualDisplay, @unchecked Sendable {
    private let lock = NSLock()
    private var native: UNBVirtualDisplay?
    private var _configuration: VirtualDisplayConfiguration
    let displayID: CGDirectDisplayID

    init(native: UNBVirtualDisplay, configuration: VirtualDisplayConfiguration) {
        self.native = native
        self.displayID = native.displayID
        self._configuration = configuration
    }

    var configuration: VirtualDisplayConfiguration {
        lock.withLock { _configuration }
    }

    func apply(_ configuration: VirtualDisplayConfiguration) throws {
        try lock.withLock {
            guard let native else { throw VirtualDisplayError.applySettingsFailed("display destroyed") }
            do {
                try native.applyWidth(
                    UInt(configuration.width),
                    height: UInt(configuration.height),
                    refreshRate: configuration.refreshRate,
                    hiDPI: configuration.hiDPI
                )
            } catch {
                throw VirtualDisplayError.applySettingsFailed(error.localizedDescription)
            }
            _configuration = configuration
        }
    }

    func destroy() {
        lock.withLock {
            native?.invalidate()
            native = nil
        }
    }

    deinit { native?.invalidate() }
}
