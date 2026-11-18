import CoreGraphics
import Foundation

/// macOS advertises every mode we allow (and several smaller ones) but picks its
/// own default — usually not the one we asked for. This selects ours explicitly.
public enum DisplayModeManager {
    public enum ModeError: Error, CustomStringConvertible {
        case modeNotOffered(String, available: [String])
        case configurationFailed(CGError)

        public var description: String {
            switch self {
            case .modeNotOffered(let want, let available):
                "Mode \(want) not offered by the display. Available: \(available.joined(separator: ", "))"
            case .configurationFailed(let e): "CGConfigureDisplayWithDisplayMode failed (\(e.rawValue))"
            }
        }
    }

    /// Returns true if the display is already in, or was switched to, the requested mode.
    @discardableResult
    public static func select(_ config: VirtualDisplayConfiguration, on id: CGDirectDisplayID) throws -> Bool {
        let scale = config.hiDPI ? 2 : 1
        let wantPixels = (config.width * scale, config.height * scale)

        if let current = CGDisplayCopyDisplayMode(id),
           current.pixelWidth == wantPixels.0, current.pixelHeight == wantPixels.1,
           current.width == config.width, current.height == config.height {
            return true
        }

        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
        let candidates = modes.filter { $0.pixelWidth == wantPixels.0 && $0.pixelHeight == wantPixels.1 }
        // Prefer the exact point size (HiDPI vs. 1x), then the closest refresh rate.
        guard let mode = candidates.min(by: { a, b in
            let aw = (a.width == config.width ? 0 : 1, abs(a.refreshRate - config.refreshRate))
            let bw = (b.width == config.width ? 0 : 1, abs(b.refreshRate - config.refreshRate))
            return aw < bw
        }) else {
            throw ModeError.modeNotOffered("\(wantPixels.0)x\(wantPixels.1)px",
                                           available: modes.map { "\($0.pixelWidth)x\($0.pixelHeight)px" })
        }

        var txn: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&txn) == .success, let txn else {
            throw ModeError.configurationFailed(.failure)
        }
        let set = CGConfigureDisplayWithDisplayMode(txn, id, mode, nil)
        guard set == .success else {
            CGCancelDisplayConfiguration(txn)
            throw ModeError.configurationFailed(set)
        }
        let done = CGCompleteDisplayConfiguration(txn, .forSession)
        guard done == .success else { throw ModeError.configurationFailed(done) }
        return true
    }
}
