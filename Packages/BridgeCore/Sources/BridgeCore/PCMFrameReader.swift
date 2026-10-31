import Foundation
import Synchronization

/// Serves arbitrary-size reads of interleaved stereo Float samples from a
/// stream of jitter-buffer playout outputs, applying simple packet-loss
/// concealment, so the audio render callback never has to care about 10 ms
/// frame boundaries or render quantum sizes that are not a multiple of one
/// frame.
///
/// Realtime contract: all storage is preallocated at init; `read(into:)`
/// performs no allocation, uses no Swift concurrency, and meets no locks of
/// its own (the source closure — the jitter buffer's `pop()` — takes its
/// short unfair lock). `read(into:)` must be called from a single thread
/// (the render thread); `partiallyPlayedFrames` may be read from any thread.
///
/// Playout rules, one playout frame at a time from `source`:
/// - `.packet`: the little-endian Int16 payload is decoded into the current
///   frame and copied into the last-good frame for concealment.
/// - first `.lost` in a streak: the last good frame is replayed with a
///   linear fade to silence across the frame.
/// - second and later `.lost` in a streak: silence.
/// - `.buffering`: silence.
/// - a `.packet` that does not continue the previous slot's packet (the
///   jitter buffer's latency trim skipped a frame): the first
///   `spliceRampFrames` frames ramp linearly from the last output sample into
///   the new audio, so the splice does not click.
public final class PCMFrameReader: @unchecked Sendable {
    /// Interleaved samples per playout frame (480 frames × 2 channels).
    private let samplesPerFrame = AudioFormat.samplesPerFrame * AudioFormat.channelCount
    /// Length of the splice ramp after a skipped frame (1 ms at 48 kHz).
    public static let spliceRampFrames = 48

    /// Supplies the next playout output; called exactly once per playout
    /// frame consumed.
    private let source: @Sendable () -> JitterBufferOutput

    // State confined to the calling (render) thread.
    private let current: UnsafeMutablePointer<Float>
    private let lastGood: UnsafeMutablePointer<Float>
    /// Interleaved samples of `current` already served; `samplesPerFrame`
    /// when no frame is loaded, so the next read pops a fresh one.
    private var cursor: Int
    /// Whether the loaded frame carries real audio (a packet); loss and
    /// buffering frames are concealment or silence and do not count towards
    /// the buffer-depth readout.
    private var currentIsAudio = false
    private var hasLastGood = false
    private var lossStreak = 0
    /// Sequence of the packet decoded into `current`, when the previous slot
    /// was a packet; nil after a loss, buffering or reset.
    private var previousPacketSequence: UInt32?
    /// Remaining interleaved samples of the frame being played, published for
    /// the latency readout. Relaxed and approximate by design.
    private let pendingSamples = Atomic<Int>(0)

    public init(source: @escaping @Sendable () -> JitterBufferOutput) {
        self.source = source
        self.current = UnsafeMutablePointer<Float>.allocate(capacity: samplesPerFrame)
        self.lastGood = UnsafeMutablePointer<Float>.allocate(capacity: samplesPerFrame)
        current.initialize(repeating: 0, count: samplesPerFrame)
        lastGood.initialize(repeating: 0, count: samplesPerFrame)
        cursor = samplesPerFrame
    }

    deinit {
        current.deallocate()
        lastGood.deallocate()
    }

    /// Fraction of the in-flight playout frame (0..<1, in frames) not yet
    /// rendered — the "partially played frame" part of the receiver's
    /// buffer-depth readout.
    public var partiallyPlayedFrames: Double {
        Double(pendingSamples.load(ordering: .relaxed)) / Double(samplesPerFrame)
    }

    /// Fills exactly `sampleCount` interleaved samples from the playout
    /// stream, popping a new output whenever the current frame is exhausted.
    /// Reads never run dry: the source's `.buffering` (and exhausted
    /// concealment) yields silence.
    public func read(into destination: UnsafeMutablePointer<Float>, sampleCount: Int) {
        var served = 0
        while served < sampleCount {
            if cursor >= samplesPerFrame {
                advance()
            }
            let chunk = min(sampleCount - served, samplesPerFrame - cursor)
            (destination + served).update(from: current + cursor, count: chunk)
            cursor += chunk
            served += chunk
        }
        pendingSamples.store(
            currentIsAudio && cursor < samplesPerFrame ? samplesPerFrame - cursor : 0,
            ordering: .relaxed)
    }

    /// Discards the in-flight frame and the concealment history before a
    /// fresh run (with the render thread stopped).
    public func reset() {
        cursor = samplesPerFrame
        currentIsAudio = false
        hasLastGood = false
        lossStreak = 0
        previousPacketSequence = nil
        pendingSamples.store(0, ordering: .relaxed)
    }

    // MARK: - Internals

    /// Pops the next playout output into `current`. Realtime-safe.
    private func advance() {
        cursor = 0
        switch source() {
        case .packet(let packet):
            decodePayload(of: packet, into: current)
            if let previous = previousPacketSequence, packet.sequence != previous &+ 1 {
                // `lastGood` still holds the previous frame, whose last
                // samples were the last ones output.
                smoothSplice(
                    fromLeft: lastGood[samplesPerFrame - 2],
                    right: lastGood[samplesPerFrame - 1])
            }
            previousPacketSequence = packet.sequence
            lastGood.update(from: current, count: samplesPerFrame)
            hasLastGood = true
            lossStreak = 0
            currentIsAudio = true
        case .lost:
            lossStreak += 1
            if lossStreak == 1, hasLastGood {
                // Simple PLC: replay the last good frame, fading linearly to
                // silence across the frame.
                let total = Float(samplesPerFrame)
                for i in 0..<samplesPerFrame {
                    current[i] = lastGood[i] * (1 - Float(i) / total)
                }
            } else {
                current.update(repeating: 0, count: samplesPerFrame)
            }
            currentIsAudio = false
            previousPacketSequence = nil
        case .buffering:
            current.update(repeating: 0, count: samplesPerFrame)
            lossStreak = 0
            currentIsAudio = false
            previousPacketSequence = nil
        }
    }

    /// Ramps the start of `current` from the previous output sample of each
    /// channel into the new audio (linear crossfade over `spliceRampFrames`).
    private func smoothSplice(fromLeft left: Float, right: Float) {
        let rampFrames = Self.spliceRampFrames
        for frame in 0..<rampFrames {
            let weight = Float(frame + 1) / Float(rampFrames + 1)
            let l = frame * 2
            current[l] = left + (current[l] - left) * weight
            current[l + 1] = right + (current[l + 1] - right) * weight
        }
    }

    /// Decodes a little-endian Int16 interleaved payload into `out`,
    /// zero-filling any shortfall (defensive against short payloads).
    private func decodePayload(of packet: AudioPacket, into out: UnsafeMutablePointer<Float>) {
        let bytesPerSample = MemoryLayout<Int16>.size
        let toDecode = min(packet.payload.count / bytesPerSample, samplesPerFrame)
        packet.payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<toDecode {
                let value = raw.loadUnaligned(
                    fromByteOffset: i * bytesPerSample, as: Int16.self)
                out[i] = Float(Int16(littleEndian: value)) / 32768
            }
        }
        if toDecode < samplesPerFrame {
            (out + toDecode).update(repeating: 0, count: samplesPerFrame - toDecode)
        }
    }
}
