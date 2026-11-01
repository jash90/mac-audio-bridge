import Foundation

/// Turns the sender's 5 ms frames of interleaved Float samples into
/// `AudioPacket`s in the selected `StreamEncoding`, switching live between
/// Opus bitrates, Opus frame durations and PCM16 from one frame to the next.
///
/// 20 ms frames (the Internet profile): four 5 ms input frames are collected
/// and encoded as one Opus frame covering their four sequence slots (the
/// packet carries the first slot's sequence, sample time and flags). A second
/// encoder at `StreamEncoding.copyBitrate` encodes the same 20 ms of audio
/// for the redundant copies (`AudioPacket.copyPayload`). A group cut short —
/// a switch to 5 ms frames or PCM, a discontinuity — is sent first as 5 ms
/// Opus frames, so the sequence stays continuous and in order.
///
/// Switching rules (the receiver mirrors them, see `PCMFrameReader`):
/// - a bitrate or frame-duration change stays in the same Opus stream (no
///   reset: every Opus packet carries its own frame size);
/// - the first Opus frame after PCM, and the first frame of a run
///   (`.discontinuity`), start a fresh Opus stream (encoder reset);
/// - should libopus fail, the frame goes out as PCM16 instead.
///
/// No allocation per frame apart from the packets' `Data` (which the network
/// send needs anyway): the scaled input, the 20 ms accumulator, both encoder
/// states and their packet buffers are preallocated, and packets are handed
/// to a non-escaping closure. Not thread-safe: owned by the sender's drain
/// queue.
public final class StreamFrameEncoder: @unchecked Sendable {
    /// Interleaved samples per 5 ms frame (240 × 2).
    public static let frameSampleCount = AudioFormat.samplesPerFrame * AudioFormat.channelCount

    private let scaled: UnsafeMutablePointer<Float>
    /// The 5 ms frames of the 20 ms group being collected.
    private let group: UnsafeMutablePointer<Float>
    private let opus: OpusEncoderBox?
    /// The low-rate encoder for the redundant copies.
    private let copyOpus: OpusEncoderBox?
    /// The previous frame was Opus from the current encoder state.
    private var opusStreamOpen = false
    /// The copy encoder continues the current run's 20 ms frames.
    private var copyStreamOpen = false

    // The group being collected.
    private var groupFrames = 0
    private var groupSequence: UInt32 = 0
    private var groupSampleTime: UInt64 = 0
    private var groupFlags: AudioPacketFlags = []
    private var groupEncoding = StreamEncoding.lan(.default)

    public init() {
        scaled = .allocate(capacity: Self.frameSampleCount)
        scaled.initialize(repeating: 0, count: Self.frameSampleCount)
        let groupCapacity = Self.frameSampleCount * OpusSettings.maxFrameSlots
        group = .allocate(capacity: groupCapacity)
        group.initialize(repeating: 0, count: groupCapacity)
        opus = try? OpusEncoderBox(bitrate: StreamQuality.default.opusBitrate ?? 192_000)
        copyOpus = try? OpusEncoderBox(bitrate: StreamEncoding.wanCopyBitrate)
    }

    deinit {
        scaled.deallocate()
        group.deallocate()
    }

    /// Whether libopus is available (false only if it failed to create an
    /// encoder; Opus qualities then fall back to PCM16).
    public var opusAvailable: Bool { opus != nil }

    /// Encoder delay of the Opus stream in samples per channel (120).
    public var opusLookaheadSamples: Int { opus?.lookaheadSamples ?? 0 }

    /// 5 ms frames collected for an incomplete 20 ms group.
    public var pendingFrames: Int { groupFrames }

    /// Starts a new run: the next Opus frame opens a fresh stream; a group
    /// still being collected is dropped (it belongs to the previous run).
    public func reset() {
        opusStreamOpen = false
        copyStreamOpen = false
        groupFrames = 0
    }

    /// Encodes one 5 ms frame at a fixed 5 ms frame duration and returns its
    /// packet (convenience form of `encode(_:gain:encoding:…)`).
    public func encode(
        _ samples: UnsafePointer<Float>,
        gain: Float,
        quality: StreamQuality,
        flags: AudioPacketFlags,
        sequence: UInt32,
        sampleTime: UInt64
    ) -> AudioPacket {
        var last: AudioPacket?
        encode(
            samples, gain: gain, encoding: .lan(quality), flags: flags, sequence: sequence,
            sampleTime: sampleTime
        ) { last = $0 }
        // A 5 ms encoding always emits the frame itself (last).
        return last!
    }

    /// Feeds one 5 ms frame: `samples` holds `frameSampleCount` interleaved
    /// Float samples, scaled by `gain` and clipped to −1...1 first. Hands
    /// every finished packet to `emit`, in sequence order: none while a
    /// 20 ms group is filling, one per completed group or 5 ms frame, plus
    /// the 5 ms frames of a group cut short.
    public func encode(
        _ samples: UnsafePointer<Float>,
        gain: Float,
        encoding: StreamEncoding,
        flags: AudioPacketFlags,
        sequence: UInt32,
        sampleTime: UInt64,
        emit: (AudioPacket) -> Void
    ) {
        for i in 0..<Self.frameSampleCount {
            scaled[i] = min(1, max(-1, samples[i] * gain))
        }
        let grouped = encoding.frameSlots > 1 && encoding.quality.opusBitrate != nil && opus != nil
        if groupFrames > 0,
            !grouped || encoding.frameSlots != groupEncoding.frameSlots || flags.contains(.discontinuity)
        {
            flushGroup(emit: emit)
        }
        guard grouped else {
            copyStreamOpen = false
            emit(encodeSingle(scaled, quality: encoding.quality, flags: flags, sequence: sequence, sampleTime: sampleTime))
            return
        }
        if groupFrames == 0 {
            groupSequence = sequence
            groupSampleTime = sampleTime
            groupFlags = flags
        }
        // The latest pick wins for the whole group (bitrate changes apply
        // from the next packet either way).
        groupEncoding = encoding
        (group + groupFrames * Self.frameSampleCount).update(from: scaled, count: Self.frameSampleCount)
        groupFrames += 1
        guard groupFrames == encoding.frameSlots else { return }
        if let packet = encodeGroup() {
            groupFrames = 0
            emit(packet)
        } else {
            flushGroup(emit: emit)
        }
    }

    /// The collected group as one Opus frame (nil if libopus failed).
    private func encodeGroup() -> AudioPacket? {
        guard let opus, let bitrate = groupEncoding.quality.opusBitrate else { return nil }
        let restart = !opusStreamOpen || groupFlags.contains(.discontinuity)
        if restart {
            opus.reset()
        }
        let frames = groupFrames * AudioFormat.samplesPerFrame
        guard (try? opus.setBitrate(bitrate)) != nil, let packet = try? opus.encode(group, frames: frames) else {
            opusStreamOpen = false
            return nil
        }
        opusStreamOpen = true
        let payload = Data(buffer: packet)
        var copyPayload: Data?
        if let copyBitrate = groupEncoding.copyBitrate, let copyOpus {
            if restart || !copyStreamOpen {
                copyOpus.reset()
            }
            if (try? copyOpus.setBitrate(copyBitrate)) != nil, let copy = try? copyOpus.encode(group, frames: frames) {
                copyPayload = Data(buffer: copy)
                copyStreamOpen = true
            } else {
                copyStreamOpen = false
            }
        }
        return AudioPacket(
            codec: .opus, flags: groupFlags, sequence: groupSequence, sampleTime: groupSampleTime,
            payload: payload, frameSlots: groupFrames, copyPayload: copyPayload)
    }

    /// Sends the collected frames as 5 ms frames (a group cut short, or a
    /// failed 20 ms encode).
    private func flushGroup(emit: (AudioPacket) -> Void) {
        let count = groupFrames
        groupFrames = 0
        copyStreamOpen = false
        for index in 0..<count {
            emit(
                encodeSingle(
                    group + index * Self.frameSampleCount, quality: groupEncoding.quality,
                    flags: index == 0 ? groupFlags : [], sequence: groupSequence &+ UInt32(index),
                    sampleTime: groupSampleTime &+ UInt64(index * AudioFormat.samplesPerFrame)))
        }
    }

    /// One 5 ms frame of already-scaled samples, Opus or PCM16.
    private func encodeSingle(
        _ frame: UnsafePointer<Float>, quality: StreamQuality, flags: AudioPacketFlags, sequence: UInt32,
        sampleTime: UInt64
    ) -> AudioPacket {
        if let bitrate = quality.opusBitrate, let opus {
            if !opusStreamOpen || flags.contains(.discontinuity) {
                opus.reset()
            }
            if (try? opus.setBitrate(bitrate)) != nil, let packet = try? opus.encode(frame) {
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
                let value = UInt16(bitPattern: Int16(frame[i] * 32767)).littleEndian
                raw.storeBytes(of: value, toByteOffset: i * 2, as: UInt16.self)
            }
        }
        return AudioPacket(
            codec: .pcm16, flags: flags, sequence: sequence, sampleTime: sampleTime, payload: payload)
    }
}
