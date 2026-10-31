import Foundation

/// Turns the sender's 5 ms frames of interleaved Float samples into
/// `AudioPacket`s in the selected `StreamQuality`, switching live between
/// Opus bitrates and PCM16 from one frame to the next.
///
/// Switching rules (the receiver mirrors them, see `PCMFrameReader`):
/// - a bitrate change stays in the same Opus stream (no reset);
/// - the first Opus frame after PCM, and the first frame of a run
///   (`.discontinuity`), start a fresh Opus stream (encoder reset);
/// - should libopus fail, the frame goes out as PCM16 instead.
///
/// No allocation per frame apart from the packet's `Data` (which the
/// network send needs anyway): the scaled input frame, the encoder state and
/// its packet buffer are preallocated. Not thread-safe: owned by the
/// sender's drain queue.
public final class StreamFrameEncoder: @unchecked Sendable {
    /// Interleaved samples per frame (240 × 2).
    public static let frameSampleCount = AudioFormat.samplesPerFrame * AudioFormat.channelCount

    private let scaled: UnsafeMutablePointer<Float>
    private let opus: OpusEncoderBox?
    /// The previous frame was Opus from the current encoder state.
    private var opusStreamOpen = false

    public init() {
        scaled = .allocate(capacity: Self.frameSampleCount)
        scaled.initialize(repeating: 0, count: Self.frameSampleCount)
        opus = try? OpusEncoderBox(bitrate: StreamQuality.default.opusBitrate ?? 192_000)
    }

    deinit {
        scaled.deallocate()
    }

    /// Whether libopus is available (false only if it failed to create an
    /// encoder; Opus qualities then fall back to PCM16).
    public var opusAvailable: Bool { opus != nil }

    /// Encoder delay of the Opus stream in samples per channel (120).
    public var opusLookaheadSamples: Int { opus?.lookaheadSamples ?? 0 }

    /// Starts a new run: the next Opus frame opens a fresh stream.
    public func reset() {
        opusStreamOpen = false
    }

    /// Encodes one frame: `samples` holds `frameSampleCount` interleaved
    /// Float samples, scaled by `gain` and clipped to −1...1 first.
    public func encode(
        _ samples: UnsafePointer<Float>,
        gain: Float,
        quality: StreamQuality,
        flags: AudioPacketFlags,
        sequence: UInt32,
        sampleTime: UInt64
    ) -> AudioPacket {
        for i in 0..<Self.frameSampleCount {
            scaled[i] = min(1, max(-1, samples[i] * gain))
        }
        if let bitrate = quality.opusBitrate, let opus {
            if !opusStreamOpen || flags.contains(.discontinuity) {
                opus.reset()
            }
            if (try? opus.setBitrate(bitrate)) != nil, let packet = try? opus.encode(scaled) {
                opusStreamOpen = true
                return AudioPacket(
                    codec: .opus, flags: flags, sequence: sequence, sampleTime: sampleTime,
                    payload: Data(buffer: packet))
            }
        }
        opusStreamOpen = false
        var payload = Data(count: Self.frameSampleCount * MemoryLayout<Int16>.size)
        payload.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            for i in 0..<Self.frameSampleCount {
                let value = UInt16(bitPattern: Int16(scaled[i] * 32767)).littleEndian
                raw.storeBytes(of: value, toByteOffset: i * 2, as: UInt16.self)
            }
        }
        return AudioPacket(
            codec: .pcm16, flags: flags, sequence: sequence, sampleTime: sampleTime, payload: payload)
    }
}
