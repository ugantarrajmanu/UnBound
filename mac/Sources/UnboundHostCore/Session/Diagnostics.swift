import CoreGraphics
import CoreMedia
import Foundation
import VideoToolbox

public enum Diagnostics {
    public static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    /// True when an x86_64 build is running under Rosetta on Apple Silicon.
    public static var isTranslated: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("sysctl.proc_translated", &value, &size, nil, 0) == 0 && value == 1
    }

    public static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "?" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public struct EncoderEntry: Sendable {
        public var codec: String
        public var name: String
        public var isHardware: Bool
    }

    public static func videoEncoders() -> [EncoderEntry] {
        var list: CFArray?
        guard VTCopyVideoEncoderList(nil, &list) == noErr, let entries = list as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let type = entry[kVTVideoEncoderList_CodecType as String] as? UInt32 else { return nil }
            let codec: String
            switch type {
            case kCMVideoCodecType_H264: codec = "H.264"
            case kCMVideoCodecType_HEVC: codec = "HEVC"
            default: return nil
            }
            return EncoderEntry(
                codec: codec,
                name: entry[kVTVideoEncoderList_DisplayName as String] as? String ?? "?",
                isHardware: entry[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool ?? false)
        }
    }

    /// Attempts to create real encoder sessions at the given size; reports what actually works.
    public static func probeEncoder(width: Int, height: Int) -> String {
        do {
            let low = try H264Encoder(settings: EncoderSettings(width: width, height: height))
            defer { low.invalidate() }
            return "H.264 \(width)x\(height): ok, hardware=\(low.hardwareDescription) [\(low.encoderID)], lowLatencyRC=\(low.usingLowLatencyRateControl)"
        } catch {
            return "H.264 \(width)x\(height): FAILED — \(error)"
        }
    }
}
