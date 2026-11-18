import Foundation

/// Transport seam (ADR-007/008). TCP today; WebRTC and USB/AOA later — the
/// encoder, decoder and session manager must not know which one is in use.
public protocol MediaTransport: AnyObject, Sendable {
    var events: MediaTransportEvents { get set }
    func start() throws
    func stop()
    func sendCodecConfig(_ config: CodecConfig)
    func sendFrame(_ frame: EncodedFrame)
    var statistics: TransportStatistics { get }
}

public struct MediaTransportEvents: Sendable {
    public var clientConnected: @Sendable (ClientHello?) -> Void = { _ in }
    public var clientDisconnected: @Sendable (String) -> Void = { _ in }
    /// A new client needs a picture, the client's decoder lost sync, or congestion cleared.
    public var keyframeNeeded: @Sendable (KeyframeReason) -> Void = { _ in }
    public var input: @Sendable (InputEvent) -> Void = { _ in }
    public init() {}
}

public enum KeyframeReason: Sendable {
    case newClient, clientRequest, congestionRecovered
}

public struct TransportStatistics: Sendable {
    public var connected = false
    public var client: ClientHello?
    public var bytesSent: Int64 = 0
    public var framesSent: Int64 = 0
    public var framesDropped: Int64 = 0
    /// Subset of `framesDropped` caused by a full send queue (the ABR signal).
    /// Excludes deltas skipped while waiting for a keyframe after connect/resync.
    public var congestionDrops: Int64 = 0
    public var queuedBytes: Int = 0
}
