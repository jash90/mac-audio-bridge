import COpus
import COpusShim
import Foundation

/// One codec setting the sender can encode. The LAN picker offers
/// `lanChoices` (5 ms frames); the Internet profile encodes the Opus rung of
/// the `InternetQuality` ladder (20 ms frames, see `StreamEncoding`).
public enum StreamQuality: String, CaseIterable, Sendable {
    /// Opus, 192 kbit/s CBR (the LAN default).
    case opus192
    /// Opus, 128 kbit/s CBR.
    case opus128
    /// Opus, 96 kbit/s CBR.
    case opus96
    /// Opus, 64 kbit/s CBR (Internet "Saver").
    case opus64
    /// Opus, 48 kbit/s CBR (Internet "Floor"; only at 20 ms frames).
    case opus48
    /// Uncompressed PCM16 (1536 kbit/s), the fallback.
    case pcm

    public static let `default` = StreamQuality.opus192

    /// What the LAN quality picker offers (Mac menu and phone).
    public static let lanChoices: [StreamQuality] = [.opus192, .opus128, .opus96, .pcm]

    public var codec: AudioCodec {
        switch self {
        case .opus192, .opus128, .opus96, .opus64, .opus48: .opus
        case .pcm: .pcm16
        }
    }

    /// Opus target bitrate in bit/s; nil for PCM.
    public var opusBitrate: Int? {
        switch self {
        case .opus192: 192_000
        case .opus128: 128_000
        case .opus96: 96_000
        case .opus64: 64_000
        case .opus48: 48_000
        case .pcm: nil
        }
    }

    /// Bit rate of the audio payload in bit/s (PCM16: 48 kHz × 2 × 16).
    public var payloadBitrate: Int {
        opusBitrate ?? Int(AudioFormat.sampleRate) * AudioFormat.channelCount * 16
    }

    public var displayName: String {
        switch self {
        case .pcm: "PCM (uncompressed)"
        default: "Opus \((opusBitrate ?? 0) / 1000) kbit/s"
        }
    }

    /// Short codec name for the stats lines ("opus" / "pcm16").
    public static func statsName(_ codec: AudioCodec) -> String {
        switch codec {
        case .opus: "opus"
        case .pcm16: "pcm16"
        }
    }

    /// What the receiver shows for a stream it plays: the codec and, for
    /// Opus, the bitrate derived from the frame size (the sender encodes
    /// CBR, so payload bytes per frame pin the bitrate exactly: 120 B per
    /// 5 ms = 192 kbit/s, 240 B per 20 ms = 96 kbit/s).
    public static func receiverDescription(codec: AudioCodec, payloadBytes: Int, frameSlots: Int = 1) -> String {
        switch codec {
        case .opus:
            let durationMs = AudioFormat.frameDurationMs * max(frameSlots, 1)
            let bitsPerSecond = payloadBytes * 8 * 1000 / durationMs
            let name = "Opus \(Int((Double(bitsPerSecond) / 1000).rounded())) kbit/s"
            return frameSlots > 1 ? name + " · \(durationMs) ms" : name
        case .pcm16:
            return "PCM (uncompressed)"
        }
    }
}

/// Errors from the libopus wrappers (the libopus error code attached).
public enum OpusCodecError: Error, Equatable {
    case createFailed(Int32)
    case controlFailed(Int32)
    case encodeFailed(Int32)
}

/// Opus settings shared by the sender and the receiver.
public enum OpusSettings {
    /// The largest Opus packet for one frame (RFC 6716).
    public static let maxPacketBytes = 1275
    /// Longest Opus frame the stream uses, in 5 ms slots (20 ms on WAN).
    public static let maxFrameSlots = 4
    /// Encoder complexity: 10 (the maximum). A 5 ms CELT stereo frame costs
    /// tens of microseconds at 10 on Apple silicon (see the encode-cost
    /// test), far below the 5 ms budget.
    public static let complexity = 10
}

/// One libopus encoder for the sender's stream: 48 kHz stereo,
/// `OPUS_APPLICATION_RESTRICTED_LOWDELAY` (CELT only, 2.5 ms look-ahead),
/// hard CBR so every 5 ms frame has the same size (bitrate / 1600 bytes) and
/// the datagram size stays bounded, full band, music signal.
///
/// Realtime: all memory is allocated at init; `encode` writes into a
/// preallocated packet buffer and libopus uses only stack scratch
/// (`USE_ALLOCA`). Not thread-safe: owned by one queue (the sender's drain
/// queue).
public final class OpusEncoderBox: @unchecked Sendable {
    /// Samples per channel per frame (240 = 5 ms).
    public static let frameSamples = AudioFormat.samplesPerFrame

    private let encoder: OpaquePointer
    private let packet: UnsafeMutablePointer<UInt8>
    public private(set) var bitrate: Int

    public init(bitrate: Int, complexity: Int = OpusSettings.complexity) throws(OpusCodecError) {
        var error: Int32 = OPUS_OK
        guard
            let encoder = opus_encoder_create(
                Int32(AudioFormat.sampleRate), Int32(AudioFormat.channelCount),
                OPUS_APPLICATION_RESTRICTED_LOWDELAY, &error),
            error == OPUS_OK
        else { throw .createFailed(error) }
        self.encoder = encoder
        self.bitrate = bitrate
        packet = .allocate(capacity: OpusSettings.maxPacketBytes)
        let settings: [(Int32, Int32)] = [
            (OPUS_SET_VBR_REQUEST, 0),
            (OPUS_SET_BITRATE_REQUEST, Int32(bitrate)),
            (OPUS_SET_COMPLEXITY_REQUEST, Int32(complexity)),
            (OPUS_SET_SIGNAL_REQUEST, OPUS_SIGNAL_MUSIC),
            (OPUS_SET_BANDWIDTH_REQUEST, OPUS_BANDWIDTH_FULLBAND),
        ]
        for (request, value) in settings {
            let status = mab_opus_encoder_set(encoder, request, value)
            guard status == OPUS_OK else {
                opus_encoder_destroy(encoder)
                packet.deallocate()
                throw .controlFailed(status)
            }
        }
    }

    deinit {
        opus_encoder_destroy(encoder)
        packet.deallocate()
    }

    /// Changes the bitrate in-stream (takes effect with the next frame; no
    /// reset, the receiver's decoder follows seamlessly).
    public func setBitrate(_ newBitrate: Int) throws(OpusCodecError) {
        guard newBitrate != bitrate else { return }
        let status = mab_opus_encoder_set(encoder, OPUS_SET_BITRATE_REQUEST, Int32(newBitrate))
        guard status == OPUS_OK else { throw .controlFailed(status) }
        bitrate = newBitrate
    }

    /// Back to the freshly created state (settings kept): the next frame
    /// starts a new Opus stream, as the receiver expects after a codec switch
    /// or a stream restart (it resets its decoder then too).
    public func reset() {
        _ = mab_opus_encoder_reset(encoder)
    }

    /// Encoder delay in samples per channel (120 = 2.5 ms in restricted
    /// low-delay mode): decoded audio lags the input by this much.
    public var lookaheadSamples: Int {
        var value: Int32 = 0
        _ = mab_opus_encoder_get(encoder, OPUS_GET_LOOKAHEAD_REQUEST, &value)
        return Int(value)
    }

    /// Encodes one frame of `frameSamples` interleaved stereo Float samples
    /// (nominally −1...1). The returned bytes live in the encoder's packet
    /// buffer and stay valid until the next call.
    public func encode(_ pcm: UnsafePointer<Float>) throws(OpusCodecError) -> UnsafeBufferPointer<UInt8> {
        try encode(pcm, frames: Self.frameSamples)
    }

    /// Encodes one frame of `frames` samples per channel (an Opus frame
    /// size: 240 = 5 ms or 960 = 20 ms). The frame size may change from one
    /// call to the next within the same stream (each packet's TOC carries
    /// it), so the decoder follows without a reset.
    public func encode(_ pcm: UnsafePointer<Float>, frames: Int) throws(OpusCodecError) -> UnsafeBufferPointer<UInt8> {
        let count = opus_encode_float(
            encoder, pcm, Int32(frames), packet, Int32(OpusSettings.maxPacketBytes))
        guard count > 0 else { throw .encodeFailed(count) }
        return UnsafeBufferPointer(start: packet, count: Int(count))
    }
}

/// One libopus decoder for the receiver's stream (48 kHz stereo).
///
/// Realtime: allocated at init; `decode` and `conceal` write into the
/// caller's buffer, libopus uses only stack scratch (`USE_ALLOCA`), takes no
/// locks and never allocates, so both may run on the audio render thread.
/// Not thread-safe: one thread (the render thread) only.
public final class OpusDecoderBox: @unchecked Sendable {
    /// Samples per channel per frame (240 = 5 ms).
    public static let frameSamples = AudioFormat.samplesPerFrame

    private let decoder: OpaquePointer

    public init() throws(OpusCodecError) {
        var error: Int32 = OPUS_OK
        guard
            let decoder = opus_decoder_create(
                Int32(AudioFormat.sampleRate), Int32(AudioFormat.channelCount), &error),
            error == OPUS_OK
        else { throw .createFailed(error) }
        self.decoder = decoder
    }

    deinit {
        opus_decoder_destroy(decoder)
    }

    /// Decodes one packet into `out` (`frameSamples` interleaved stereo
    /// frames). Returns the decoded frames per channel (`frameSamples` for a
    /// valid 5 ms packet) or a negative libopus error.
    public func decode(
        _ bytes: UnsafeRawPointer, count: Int, into out: UnsafeMutablePointer<Float>
    ) -> Int {
        decode(bytes, count: count, into: out, maxFrames: Self.frameSamples)
    }

    /// Decodes one packet of up to `maxFrames` samples per channel (`out`
    /// holds `maxFrames` interleaved stereo frames): a 20 ms packet needs
    /// 960. Returns the decoded frames per channel or a negative error.
    public func decode(
        _ bytes: UnsafeRawPointer, count: Int, into out: UnsafeMutablePointer<Float>, maxFrames: Int
    ) -> Int {
        Int(
            opus_decode_float(
                decoder, bytes.assumingMemoryBound(to: UInt8.self), Int32(count), out,
                Int32(maxFrames), 0))
    }

    /// Opus packet-loss concealment for one missing 5 ms frame: continues the
    /// signal from the decoder state (and keeps that state consistent, so the
    /// next real packet joins smoothly). Returns frames or a negative error.
    public func conceal(into out: UnsafeMutablePointer<Float>) -> Int {
        Int(opus_decode_float(decoder, nil, 0, out, Int32(Self.frameSamples), 0))
    }

    /// Forgets all previous frames: the next packet starts a new stream.
    public func reset() {
        _ = mab_opus_decoder_reset(decoder)
    }
}
