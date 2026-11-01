import COpus
import COpusShim
import Foundation

/// libopus encoder for the phone's microphone stream: 48 kHz mono,
/// `OPUS_APPLICATION_VOIP`, 10 ms frames (`MicFormat.samplesPerFrame`), hard
/// CBR so every frame has the same size (bitrate / 800 bytes: 50 B at
/// 40 kbit/s) and the datagram size stays bounded, voice signal, wideband
/// and up.
///
/// Loss resilience comes from our own redundancy (`MicPacker`: every frame
/// travels again in the next datagrams), not from Opus in-band FEC: with
/// the copies a lost frame is replayed exactly, while LBRR would only give
/// a lower-quality guess and cost bits in every frame.
///
/// Realtime: all memory is allocated at init; `encode` writes into a
/// preallocated packet buffer and libopus uses only stack scratch. Not
/// thread-safe: owned by one queue (the phone's mic send queue).
public final class VoiceOpusEncoder: @unchecked Sendable {
    public static let frameSamples = MicFormat.samplesPerFrame

    private let encoder: OpaquePointer
    private let packet: UnsafeMutablePointer<UInt8>
    public private(set) var bitrate: Int

    public init(bitrate: Int = MicFormat.lanBitrate, complexity: Int = 8) throws(OpusCodecError) {
        var error: Int32 = OPUS_OK
        guard
            let encoder = opus_encoder_create(
                Int32(MicFormat.sampleRate), 1, OPUS_APPLICATION_VOIP, &error),
            error == OPUS_OK
        else { throw .createFailed(error) }
        self.encoder = encoder
        self.bitrate = bitrate
        packet = .allocate(capacity: OpusSettings.maxPacketBytes)
        let settings: [(Int32, Int32)] = [
            (OPUS_SET_VBR_REQUEST, 0),
            (OPUS_SET_BITRATE_REQUEST, Int32(bitrate)),
            (OPUS_SET_COMPLEXITY_REQUEST, Int32(complexity)),
            (OPUS_SET_SIGNAL_REQUEST, OPUS_SIGNAL_VOICE),
            (OPUS_SET_INBAND_FEC_REQUEST, 0),
            (OPUS_SET_DTX_REQUEST, 0),
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

    /// Changes the bitrate in-stream (LAN ↔ WAN profile).
    public func setBitrate(_ newBitrate: Int) throws(OpusCodecError) {
        guard newBitrate != bitrate else { return }
        let status = mab_opus_encoder_set(encoder, OPUS_SET_BITRATE_REQUEST, Int32(newBitrate))
        guard status == OPUS_OK else { throw .controlFailed(status) }
        bitrate = newBitrate
    }

    /// Back to the freshly created state: the next frame starts a new stream
    /// (sent with `.discontinuity`, so the Mac resets its decoder too).
    public func reset() {
        _ = mab_opus_encoder_reset(encoder)
    }

    /// Encodes one frame of `frameSamples` mono Float samples. The returned
    /// bytes live in the encoder's packet buffer until the next call.
    public func encode(_ pcm: UnsafePointer<Float>) throws(OpusCodecError) -> UnsafeBufferPointer<UInt8> {
        let count = opus_encode_float(
            encoder, pcm, Int32(Self.frameSamples), packet, Int32(OpusSettings.maxPacketBytes))
        guard count > 0 else { throw .encodeFailed(count) }
        return UnsafeBufferPointer(start: packet, count: Int(count))
    }
}

/// libopus decoder for the microphone stream on the Mac (48 kHz mono).
///
/// Realtime: allocated at init; `decode` and `conceal` write into the
/// caller's buffer, take no locks and never allocate, so both run on the
/// feeder's IO thread. Not thread-safe: that thread only.
public final class VoiceOpusDecoder: @unchecked Sendable {
    public static let frameSamples = MicFormat.samplesPerFrame

    private let decoder: OpaquePointer

    public init() throws(OpusCodecError) {
        var error: Int32 = OPUS_OK
        guard let decoder = opus_decoder_create(Int32(MicFormat.sampleRate), 1, &error), error == OPUS_OK
        else { throw .createFailed(error) }
        self.decoder = decoder
    }

    deinit {
        opus_decoder_destroy(decoder)
    }

    /// Decodes one packet into `out` (`frameSamples` mono samples). Returns
    /// the decoded samples or a negative libopus error.
    public func decode(_ bytes: UnsafeRawPointer, count: Int, into out: UnsafeMutablePointer<Float>) -> Int {
        Int(
            opus_decode_float(
                decoder, bytes.assumingMemoryBound(to: UInt8.self), Int32(count), out,
                Int32(Self.frameSamples), 0))
    }

    /// Packet-loss concealment for one missing 10 ms frame.
    public func conceal(into out: UnsafeMutablePointer<Float>) -> Int {
        Int(opus_decode_float(decoder, nil, 0, out, Int32(Self.frameSamples), 0))
    }

    public func reset() {
        _ = mab_opus_decoder_reset(decoder)
    }
}
