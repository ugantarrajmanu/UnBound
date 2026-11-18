import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public struct EncoderSettings: Sendable {
    public var width: Int
    public var height: Int
    public var framesPerSecond: Int
    public var bitrate: Int               // bits per second
    public var keyframeIntervalSeconds: Double
    public var preferLowLatencyRateControl: Bool

    public init(width: Int, height: Int, framesPerSecond: Int = 60, bitrate: Int = 12_000_000,
                keyframeIntervalSeconds: Double = 2, preferLowLatencyRateControl: Bool = true) {
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.bitrate = bitrate
        self.keyframeIntervalSeconds = keyframeIntervalSeconds
        self.preferLowLatencyRateControl = preferLowLatencyRateControl
    }
}

public enum EncoderError: Error, CustomStringConvertible {
    case sessionCreationFailed(OSStatus)
    case prepareFailed(OSStatus)

    public var description: String {
        switch self {
        case .sessionCreationFailed(let s): "VTCompressionSessionCreate failed (\(s))"
        case .prepareFailed(let s): "VTCompressionSessionPrepareToEncodeFrames failed (\(s))"
        }
    }
}

public struct CodecConfig: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var sps: Data
    public var pps: Data
}

public struct EncodedFrame: Sendable {
    public var annexB: Data
    public var ptsMicros: Int64
    public var isKeyframe: Bool
    /// Wall time spent inside the encoder (submit → callback).
    public var encodeDurationMicros: Int64
}

/// Hardware H.264 encoder. Output is Annex-B; SPS/PPS are emitted as a separate
/// CodecConfig before every keyframe so late-joining clients can start decoding.
public final class H264Encoder: @unchecked Sendable {
    public let settings: EncoderSettings
    /// nil when the encoder can't answer (the low-latency `rtvc` encoder doesn't expose it).
    public private(set) var usingHardware: Bool?
    public private(set) var encoderID = "?"
    public var hardwareDescription: String {
        switch usingHardware {
        case true?: "yes"
        case false?: "NO (software)"
        case nil: encoderID.hasSuffix(".rtvc") ? "yes (low-latency rtvc)" : "unknown"
        }
    }
    public private(set) var usingLowLatencyRateControl = false

    public var onConfig: (@Sendable (CodecConfig) -> Void)?
    public var onFrame: (@Sendable (EncodedFrame) -> Void)?

    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var forceKeyframe = true
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastPTS = CMTime.invalid
    private let repeatQueue = DispatchQueue(label: "unbound.encoder.repeat")
    private var lastForcedKeyframeAt: UInt64 = 0
    private var keyframeDeferred = false
    private let minKeyframeSpacingNanos: UInt64 = 500_000_000

    public init(settings: EncoderSettings) throws {
        self.settings = settings
        try createSession()
    }

    deinit { invalidate() }

    private func createSession() throws {
        var attempts: [[CFString: Any]] = []
        if settings.preferLowLatencyRateControl {
            attempts.append([
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
                kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
            ])
        }
        attempts.append([kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true])

        var lastStatus: OSStatus = noErr
        for (index, spec) in attempts.enumerated() {
            var created: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: Int32(settings.width),
                height: Int32(settings.height),
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: spec as CFDictionary,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &created
            )
            lastStatus = status
            if status == noErr, let created {
                session = created
                usingLowLatencyRateControl = settings.preferLowLatencyRateControl && index == 0
                break
            }
        }
        guard let session else { throw EncoderError.sessionCreationFailed(lastStatus) }

        let fps = settings.framesPerSecond
        set(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        set(session, kVTCompressionPropertyKey_AverageBitRate, settings.bitrate as CFNumber)
        set(session, kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        set(session, kVTCompressionPropertyKey_MaxKeyFrameInterval,
            Int(Double(fps) * settings.keyframeIntervalSeconds) as CFNumber)
        set(session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, settings.keyframeIntervalSeconds as CFNumber)
        set(session, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
        // Cap bursts at 1.5x the average over one second.
        let bytesPerSecond = Int(Double(settings.bitrate) * 1.5 / 8)
        set(session, kVTCompressionPropertyKey_DataRateLimits, [bytesPerSecond, 1] as CFArray)

        var hw: Unmanaged<CFTypeRef>?
        let hwStatus = withUnsafeMutablePointer(to: &hw) {
            VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                  allocator: nil, valueOut: UnsafeMutableRawPointer($0))
        }
        if hwStatus == noErr, let value = hw?.takeRetainedValue() {
            usingHardware = (value as? Bool) == true
        }
        var idRef: Unmanaged<CFTypeRef>?
        let idStatus = withUnsafeMutablePointer(to: &idRef) {
            VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_EncoderID,
                                  allocator: nil, valueOut: UnsafeMutableRawPointer($0))
        }
        if idStatus == noErr, let value = idRef?.takeRetainedValue() as? String { encoderID = value }

        let status = VTCompressionSessionPrepareToEncodeFrames(session)
        guard status == noErr else { throw EncoderError.prepareFailed(status) }
    }

    @discardableResult
    private func set(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef) -> OSStatus {
        VTSessionSetProperty(session, key: key, value: value)
    }

    /// Forces the next frame to be an IDR. Requests within `minKeyframeSpacing`
    /// of the previous forced keyframe are coalesced (prevents keyframe storms).
    /// `repeatLastFrame` re-encodes the last captured frame right away so a newly
    /// connected client gets a picture even when the desktop is idle.
    public func requestKeyframe(repeatLastFrame: Bool = false) {
        let now = DispatchTime.now().uptimeNanoseconds
        let (buffer, pts) = lock.withLock { () -> (CVPixelBuffer?, CMTime) in
            let elapsed = now &- lastForcedKeyframeAt
            if !repeatLastFrame, elapsed < minKeyframeSpacingNanos {
                // Too soon: defer (never drop) — coalesce into one keyframe when the window opens.
                if !keyframeDeferred {
                    keyframeDeferred = true
                    repeatQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(minKeyframeSpacingNanos - elapsed))) { [self] in
                        lock.withLock { keyframeDeferred = false }
                        requestKeyframe()
                    }
                }
                return (nil, .invalid)
            }
            lastForcedKeyframeAt = now
            forceKeyframe = true
            return repeatLastFrame ? (lastPixelBuffer, lastPTS) : (nil, .invalid)
        }
        if let buffer, pts.isValid {
            nonisolated(unsafe) let buffer = buffer // CVPixelBuffer is immutable once captured
            repeatQueue.async { [self] in
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                encode(buffer, presentationTime: CMTimeMaximum(now, CMTimeAdd(pts, CMTime(value: 1, timescale: 1000))))
            }
        }
    }

    /// Changes the target bitrate of the live session (used by adaptive bitrate).
    public func setBitrate(_ bitsPerSecond: Int) {
        lock.withLock {
            guard let session else { return }
            set(session, kVTCompressionPropertyKey_AverageBitRate, bitsPerSecond as CFNumber)
            set(session, kVTCompressionPropertyKey_DataRateLimits,
                [Int(Double(bitsPerSecond) * 1.5 / 8), 1] as CFArray)
        }
    }

    public func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        let (session, keyframe) = lock.withLock { () -> (VTCompressionSession?, Bool) in
            guard let session = self.session else { return (nil, false) }
            // Keep PTS strictly increasing (repeated frames can race with live ones).
            if lastPTS.isValid, CMTimeCompare(presentationTime, lastPTS) <= 0 { return (nil, false) }
            lastPixelBuffer = pixelBuffer
            lastPTS = presentationTime
            defer { forceKeyframe = false }
            return (session, forceKeyframe)
        }
        guard let session else { return }

        let properties: CFDictionary? = keyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            : nil
        let submitted = DispatchTime.now().uptimeNanoseconds

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self, status == noErr, let sampleBuffer else { return }
            let elapsed = Int64(DispatchTime.now().uptimeNanoseconds - submitted) / 1000
            self.handleEncoded(sampleBuffer, encodeMicros: elapsed)
        }
        if status != noErr, keyframe {
            lock.withLock { forceKeyframe = true }
        }
    }

    public func invalidate() {
        let session = lock.withLock { () -> VTCompressionSession? in
            defer { self.session = nil; lastPixelBuffer = nil }
            return self.session
        }
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }

    private func handleEncoded(_ sampleBuffer: CMSampleBuffer, encodeMicros: Int64) {
        let isKeyframe = Self.isKeyframe(sampleBuffer)
        if isKeyframe, let format = sampleBuffer.formatDescription, let config = Self.codecConfig(from: format) {
            onConfig?(config)
        }
        guard let block = sampleBuffer.dataBuffer, let avcc = try? block.dataBytes() else { return }
        let pts = sampleBuffer.presentationTimeStamp
        let micros = pts.isValid ? Int64(CMTimeGetSeconds(pts) * 1_000_000) : 0
        onFrame?(EncodedFrame(annexB: NALUtil.avccToAnnexB(avcc), ptsMicros: micros,
                              isKeyframe: isKeyframe, encodeDurationMicros: encodeMicros))
    }

    static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[CFString: Any]], let first = attachments.first
        else { return true }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }

    static func codecConfig(from format: CMFormatDescription) -> CodecConfig? {
        func parameterSet(_ index: Int) -> Data? {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            guard status == noErr, let pointer else { return nil }
            return Data(bytes: pointer, count: size)
        }
        guard let sps = parameterSet(0), let pps = parameterSet(1) else { return nil }
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        return CodecConfig(width: Int(dims.width), height: Int(dims.height), sps: sps, pps: pps)
    }
}

public enum NALUtil {
    static let startCode: [UInt8] = [0, 0, 0, 1]

    /// Converts 4-byte length-prefixed NAL units (AVCC) to start-code-delimited (Annex B).
    public static func avccToAnnexB(_ avcc: Data, lengthSize: Int = 4) -> Data {
        var out = Data(capacity: avcc.count + 16)
        avcc.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset + lengthSize <= raw.count {
                var length = 0
                for i in 0..<lengthSize { length = (length << 8) | Int(raw[offset + i]) }
                offset += lengthSize
                guard length > 0, offset + length <= raw.count else { break }
                out.append(contentsOf: startCode)
                out.append(contentsOf: raw[offset..<(offset + length)])
                offset += length
            }
        }
        return out
    }
}
