import CoreGraphics
import Foundation

/// Snapshot of what macOS reports for a display — used to verify the virtual
/// display is genuinely independent (not mirrored) and to size capture.
public struct DisplayInfo: Sendable, CustomStringConvertible {
    public let displayID: CGDirectDisplayID
    public let isOnline: Bool
    public let isMain: Bool
    public let isInMirrorSet: Bool
    public let mirrorsDisplay: CGDirectDisplayID
    public let bounds: CGRect
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let pointWidth: Int
    public let pointHeight: Int
    public let refreshRate: Double

    public init(_ id: CGDirectDisplayID) {
        displayID = id
        isOnline = DisplayInfo.onlineDisplays().contains(id)
        isMain = CGDisplayIsMain(id) != 0
        isInMirrorSet = CGDisplayIsInMirrorSet(id) != 0
        mirrorsDisplay = CGDisplayMirrorsDisplay(id)
        bounds = CGDisplayBounds(id)
        if let mode = CGDisplayCopyDisplayMode(id) {
            pixelWidth = mode.pixelWidth
            pixelHeight = mode.pixelHeight
            pointWidth = mode.width
            pointHeight = mode.height
            refreshRate = mode.refreshRate
        } else {
            pixelWidth = 0; pixelHeight = 0; pointWidth = 0; pointHeight = 0; refreshRate = 0
        }
    }

    public var isIndependentDesktop: Bool { isOnline && !isInMirrorSet && mirrorsDisplay == kCGNullDirectDisplay }

    public var description: String {
        "display \(displayID): online=\(isOnline) main=\(isMain) mirrored=\(isInMirrorSet) "
            + "points=\(pointWidth)x\(pointHeight) pixels=\(pixelWidth)x\(pixelHeight) "
            + "@\(refreshRate)Hz origin=(\(Int(bounds.origin.x)),\(Int(bounds.origin.y)))"
    }

    public static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// CoreGraphics updates this process's view of the display list from
    /// WindowServer notifications delivered on the main run loop, so waiting
    /// on the main thread must keep that run loop turning.
    static func pump(_ interval: TimeInterval) {
        if Thread.isMainThread {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(interval))
        } else {
            Thread.sleep(forTimeInterval: interval)
        }
    }

    public static func availableModes(_ id: CGDirectDisplayID) -> [String] {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode] else { return [] }
        return modes.map { "\($0.width)x\($0.height)(px \($0.pixelWidth)x\($0.pixelHeight))@\(Int($0.refreshRate))" }
    }

    /// Polls until the display shows up in the online list with a valid mode.
    public static func waitUntilOnline(_ id: CGDirectDisplayID, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if onlineDisplays().contains(id), CGDisplayCopyDisplayMode(id) != nil { return true }
            pump(0.05)
        } while Date() < deadline
        return false
    }

    public static func waitUntilOffline(_ id: CGDirectDisplayID, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if !onlineDisplays().contains(id) { return true }
            pump(0.05)
        } while Date() < deadline
        return false
    }
}
