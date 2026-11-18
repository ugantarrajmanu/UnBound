import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit

public enum ScreenCaptureError: Error, CustomStringConvertible {
    case permissionDenied
    case displayNotFound(CGDirectDisplayID)

    public var description: String {
        switch self {
        case .permissionDenied:
            "Screen Recording permission is required. Grant it in System Settings › Privacy & Security › Screen Recording, then relaunch."
        case .displayNotFound(let id):
            "ScreenCaptureKit could not find display \(id)"
        }
    }
}

public struct CaptureConfiguration: Sendable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var framesPerSecond: Int
    public var showsCursor: Bool

    public init(pixelWidth: Int, pixelHeight: Int, framesPerSecond: Int = 60, showsCursor: Bool = true) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.framesPerSecond = framesPerSecond
        self.showsCursor = showsCursor
    }
}

/// Captures exactly one display (the virtual one) and hands NV12 frames to the encoder.
/// ScreenCaptureKit only emits frames when content changes; idle desktops produce no frames.
public final class ScreenCaptureManager: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public typealias FrameHandler = @Sendable (CVPixelBuffer, CMTime) -> Void
    public typealias StopHandler = @Sendable (Error) -> Void

    private let queue = DispatchQueue(label: "unbound.capture", qos: .userInteractive)
    private let lock = NSLock()
    private var stream: SCStream?
    private let onFrame: FrameHandler
    private let onStop: StopHandler

    public init(onFrame: @escaping FrameHandler, onStop: @escaping StopHandler) {
        self.onFrame = onFrame
        self.onStop = onStop
    }

    public static func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }

    /// Triggers the system prompt on first use. Returns current state.
    @discardableResult
    public static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    public func start(displayID: CGDirectDisplayID, configuration: CaptureConfiguration) async throws {
        guard Self.hasPermission() else { throw ScreenCaptureError.permissionDenied }
        let display = try await Self.findDisplay(displayID, timeout: 5)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = configuration.pixelWidth
        config.height = configuration.pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.framesPerSecond))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange // NV12: native encoder input
        config.queueDepth = 5
        config.showsCursor = configuration.showsCursor
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        lock.withLock { self.stream = stream }
    }

    public func stop() async {
        let stream = lock.withLock { () -> SCStream? in
            defer { self.stream = nil }
            return self.stream
        }
        try? await stream?.stopCapture()
    }

    // MARK: SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }
        onFrame(pixelBuffer, sampleBuffer.presentationTimeStamp)
    }

    // MARK: SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock { self.stream = nil }
        onStop(error)
    }

    /// Whether WindowServer currently offers this display for capture (out-of-process truth).
    public static func isDisplayAvailable(_ id: CGDirectDisplayID) async -> Bool {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        else { return false }
        return content.displays.contains { $0.displayID == id }
    }

    // A freshly created virtual display can take a moment to appear in SCShareableContent.
    private static func findDisplay(_ id: CGDirectDisplayID, timeout: TimeInterval) async throws -> SCDisplay {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let match = content.displays.first(where: { $0.displayID == id }) { return match }
            if Date() >= deadline { throw ScreenCaptureError.displayNotFound(id) }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }
}
