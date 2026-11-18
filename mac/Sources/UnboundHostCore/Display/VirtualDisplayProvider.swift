import CoreGraphics
import Foundation

/// Requested shape of a virtual display. `width`/`height` are the *mode* size;
/// with `hiDPI` the backing pixel size is typically 2x (verify with `probe`).
public struct VirtualDisplayConfiguration: Sendable, Equatable, CustomStringConvertible {
    public var name: String
    public var width: Int
    public var height: Int
    public var refreshRate: Double
    public var hiDPI: Bool
    /// Used to derive the physical size macOS reports for the display.
    public var pixelsPerInch: Double
    public var serialNumber: UInt32

    public init(
        name: String = "Unbound Display",
        width: Int = 1920,
        height: Int = 1200,
        refreshRate: Double = 60,
        hiDPI: Bool = false,
        pixelsPerInch: Double = 110,
        serialNumber: UInt32 = 0x0001
    ) {
        self.name = name
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.hiDPI = hiDPI
        self.pixelsPerInch = pixelsPerInch
        self.serialNumber = serialNumber
    }

    public var sizeInMillimeters: CGSize {
        CGSize(width: Double(width) / pixelsPerInch * 25.4, height: Double(height) / pixelsPerInch * 25.4)
    }

    public var description: String {
        "\(width)x\(height)@\(Int(refreshRate))Hz\(hiDPI ? " HiDPI" : "")"
    }
}

public enum VirtualDisplayAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String)
}

public enum VirtualDisplayError: Error, CustomStringConvertible {
    case unsupported(String)
    case creationFailed(String)
    case applySettingsFailed(String)
    case notOnline(CGDirectDisplayID, timeout: TimeInterval)

    public var description: String {
        switch self {
        case .unsupported(let r): "Virtual displays are not supported on this Mac: \(r)"
        case .creationFailed(let r): "Virtual display creation failed: \(r)"
        case .applySettingsFailed(let r): "Virtual display mode change failed: \(r)"
        case .notOnline(let id, let t): "Virtual display \(id) did not come online within \(t)s"
        }
    }
}

/// A live virtual display. Destroyed on `destroy()` or deinit.
public protocol VirtualDisplay: AnyObject, Sendable {
    var displayID: CGDirectDisplayID { get }
    var configuration: VirtualDisplayConfiguration { get }
    func apply(_ configuration: VirtualDisplayConfiguration) throws
    func destroy()
}

/// The replaceable seam that protects the rest of the product from changes to
/// the (private) display-creation mechanism. See docs/adr/ADR-002.
public protocol VirtualDisplayProvider: Sendable {
    var identifier: String { get }
    func availability() -> VirtualDisplayAvailability
    func createDisplay(
        _ configuration: VirtualDisplayConfiguration,
        onTerminated: @escaping @Sendable () -> Void
    ) throws -> any VirtualDisplay
}

/// Fallback used when no working provider exists. Always fails with a clear reason.
public struct UnsupportedProvider: VirtualDisplayProvider {
    public let reason: String
    public init(reason: String) { self.reason = reason }
    public var identifier: String { "unsupported" }
    public func availability() -> VirtualDisplayAvailability { .unavailable(reason: reason) }
    public func createDisplay(
        _ configuration: VirtualDisplayConfiguration,
        onTerminated: @escaping @Sendable () -> Void
    ) throws -> any VirtualDisplay {
        throw VirtualDisplayError.unsupported(reason)
    }
}

public enum VirtualDisplayProviders {
    /// Picks the best available provider, never crashes.
    public static func makeDefault() -> any VirtualDisplayProvider {
        let candidate = PrivateCGVirtualDisplayProvider()
        switch candidate.availability() {
        case .available: return candidate
        case .unavailable(let reason): return UnsupportedProvider(reason: reason)
        }
    }
}
