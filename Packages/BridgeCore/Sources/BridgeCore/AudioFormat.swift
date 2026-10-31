/// Shared audio format constants for the Mac Audio Bridge pipeline.
public enum AudioFormat {
    public static let sampleRate: Double = 48_000
    public static let channelCount: Int = 2
    public static let frameDurationMs: Int = 10
    public static var samplesPerFrame: Int { Int(sampleRate) * frameDurationMs / 1000 } // per channel = 480
}
