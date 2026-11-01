import Foundation

/// Shared audio format constants for the Mac Audio Bridge pipeline.
public enum AudioFormat {
    public static let sampleRate: Double = 48_000
    public static let channelCount: Int = 2
    /// Duration of one audio frame (one jitter-buffer slot). 5 ms keeps a
    /// PCM16 stereo frame at 960 bytes, so a datagram stays below
    /// `maxDatagramBytes` and is never IP-fragmented (losing either fragment
    /// of a fragmented datagram loses the whole frame).
    public static let frameDurationMs: Int = 5
    /// `frameDurationMs` in seconds.
    public static var frameDuration: TimeInterval { Double(frameDurationMs) / 1000 }
    /// Samples per channel in one frame (240 at 5 ms).
    public static var samplesPerFrame: Int { Int(sampleRate) * frameDurationMs / 1000 }
    /// Payload bytes of one PCM16 interleaved frame (960 at 5 ms).
    public static var pcm16FrameBytes: Int { samplesPerFrame * channelCount * MemoryLayout<Int16>.size }
    /// Upper bound for one UDP payload: comfortably below the 1472-byte
    /// IPv4/Ethernet limit (and any VPN/tunnel overhead), so datagrams are
    /// never fragmented.
    public static let maxDatagramBytes = 1200

    /// Whole frames covering `milliseconds` (rounded up, at least 1).
    public static func frames(milliseconds: Double) -> Int {
        max(1, Int((milliseconds / Double(frameDurationMs) - 1e-9).rounded(.up)))
    }
}
