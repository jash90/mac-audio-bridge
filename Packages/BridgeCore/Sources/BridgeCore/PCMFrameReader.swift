import Foundation
import Synchronization

/// Concealment counters of a `PCMFrameReader`, for the stats line.
public struct ConcealmentStats: Sendable, Equatable {
    /// Playout slots synthesized instead of played (losses, underrun waits,
    /// mid-stream buffering), counted once audio has started.
    public var concealedFrames = 0
    /// Concealment events: transitions from real audio into concealment.
    public var concealments = 0
    /// Concealments that ran long enough to fade all the way to silence.
    public var fadeOuts = 0
    /// Resumes into real audio after concealment or silence (crossfaded or
    /// faded in).
    public var fadeIns = 0
    /// Splices inside real audio (latency trim, overflow resync) that were
    /// crossfaded.
    public var crossfades = 0

    public init() {}
}

/// Serves arbitrary-size reads of interleaved stereo Float samples from the
/// jitter buffer's 5 ms playout slots, decoding PCM16 and concealing every
/// gap so that the output never jumps: no step between audio and silence,
/// no hard splice.
///
/// Realtime contract: all storage is preallocated at init; `read(into:)`
/// performs no allocation, uses no Swift concurrency, and meets no locks of
/// its own (the source — the jitter buffer's realtime `pop` — copies the
/// payload into the reader's buffers under its short unfair lock). `read`
/// must be called from a single thread (the render thread); the stats and
/// `partiallyPlayedFrames` may be read from any thread.
///
/// Playout rules, one slot at a time:
/// - a frame continuing the previous one is played as is;
/// - a frame after the latency trim skipped its predecessor is crossfaded
///   from the skipped frame over the whole 5 ms slot (both ends stay
///   continuous with their real neighbours);
/// - a frame after any other skip (overflow resync) is crossfaded from a
///   concealment continuation over 5 ms;
/// - a loss / underrun / buffering slot after audio starts concealment:
///   the last 10–20 ms of output are looped (loop length chosen by
///   autocorrelation, loop seam blended), joined to the last output sample
///   with a 2 ms offset correction, held at full level for 10 ms and then
///   faded to silence with a raised cosine over 40 ms;
/// - the first frame after concealment is crossfaded from the (still
///   running) concealment over 5 ms; after silence it fades in over 5 ms.
public final class PCMFrameReader: @unchecked Sendable {
    /// Supplies the next playout slot, copying the payload (and a trimmed
    /// predecessor's payload) into the given buffers. Called exactly once per
    /// playout frame consumed.
    public typealias Source = @Sendable (
        _ payload: UnsafeMutableRawBufferPointer,
        _ skippedPayload: UnsafeMutableRawBufferPointer
    ) -> PlayoutSlot

    // MARK: Tunables (in sample frames at 48 kHz)

    private static let channels = AudioFormat.channelCount
    /// Sample frames per playout slot (240 = 5 ms).
    private static let slotFrames = AudioFormat.samplesPerFrame
    /// Fade-in / resume / splice crossfade length: one whole slot (5 ms).
    public static let fadeFrames = AudioFormat.samplesPerFrame
    /// Concealment holds full level for 10 ms …
    public static let concealHoldFrames = 480
    /// … then fades to silence over 40 ms (total 50 ms of concealment).
    public static let concealDecayFrames = 1_920
    /// Output history kept for the concealment loop (42.7 ms).
    private static let historyFrames = 2_048
    /// Loop length range (10–20 ms), searched by autocorrelation.
    private static let minLoopFrames = 480
    private static let maxLoopFrames = 960
    /// Blend at the loop seam and offset correction at the join (2 ms).
    private static let seamFrames = 96
    /// Decimation factor of the loop search.
    private static let decimation = 4
    /// Correlation window of the decimated search (5 ms).
    private static let searchWindow = 60

    private let source: Source
    private let interleavedPerSlot = PCMFrameReader.slotFrames * PCMFrameReader.channels

    // Preallocated buffers (render thread only).
    private let current: UnsafeMutablePointer<Float>
    private let skippedFrame: UnsafeMutablePointer<Float>
    private let scratch: UnsafeMutablePointer<Float>
    private let payload: UnsafeMutableRawBufferPointer
    private let skippedPayload: UnsafeMutableRawBufferPointer
    private let history: UnsafeMutablePointer<Float>
    private let loop: UnsafeMutablePointer<Float>
    private let decimated: UnsafeMutablePointer<Float>
    private let fadeTable: UnsafeMutablePointer<Float>
    private let seamTable: UnsafeMutablePointer<Float>
    private let decayTable: UnsafeMutablePointer<Float>

    // State confined to the render thread.
    private enum Mode {
        /// Silence (start, after a reset, or after concealment decayed).
        case silent
        /// The last slot was real audio.
        case audio
        /// The concealment generator is running.
        case concealing
    }

    private var mode: Mode = .silent
    private var hasStarted = false
    /// Sequence of the last frame played, while `mode == .audio`.
    private var previousSequence: UInt32?
    /// Interleaved samples of `current` already served; `interleavedPerSlot`
    /// when no slot is loaded, so the next read pops a fresh one.
    private var cursor: Int
    private var currentIsAudio = false
    /// Next write position in the history ring (sample frames).
    private var historyWrite = 0
    // Concealment generator.
    private var loopLength = PCMFrameReader.minLoopFrames
    private var loopPhase = 0
    private var concealPosition = 0
    private var correctionLeft: Float = 0
    private var correctionRight: Float = 0

    /// Remaining interleaved samples of the frame being played, published for
    /// the latency readout. Relaxed and approximate by design.
    private let pendingSamples = Atomic<Int>(0)
    private let concealedFrames = Atomic<Int>(0)
    private let concealments = Atomic<Int>(0)
    private let fadeOuts = Atomic<Int>(0)
    private let fadeIns = Atomic<Int>(0)
    private let crossfades = Atomic<Int>(0)

    public init(source: @escaping Source) {
        self.source = source
        let slot = interleavedPerSlot
        current = .allocate(capacity: slot)
        skippedFrame = .allocate(capacity: slot)
        scratch = .allocate(capacity: slot)
        payload = .allocate(byteCount: JitterBuffer.maxFramePayloadBytes, alignment: 16)
        skippedPayload = .allocate(byteCount: JitterBuffer.maxFramePayloadBytes, alignment: 16)
        history = .allocate(capacity: Self.historyFrames * Self.channels)
        loop = .allocate(capacity: Self.maxLoopFrames * Self.channels)
        decimated = .allocate(capacity: Self.historyFrames / Self.decimation)
        fadeTable = .allocate(capacity: Self.fadeFrames)
        seamTable = .allocate(capacity: Self.seamFrames)
        decayTable = .allocate(capacity: Self.concealDecayFrames)
        for buffer in [current, skippedFrame, scratch] {
            buffer.initialize(repeating: 0, count: slot)
        }
        history.initialize(repeating: 0, count: Self.historyFrames * Self.channels)
        loop.initialize(repeating: 0, count: Self.maxLoopFrames * Self.channels)
        decimated.initialize(repeating: 0, count: Self.historyFrames / Self.decimation)
        // Raised-cosine ramps 0 → 1 (fade, seam) and 1 → 0 (decay), with
        // zero slope at both ends.
        func rise(_ i: Int, _ length: Int) -> Float {
            Float(0.5 - 0.5 * cos(Double.pi * (Double(i) + 0.5) / Double(length)))
        }
        for i in 0..<Self.fadeFrames { fadeTable[i] = rise(i, Self.fadeFrames) }
        for i in 0..<Self.seamFrames { seamTable[i] = rise(i, Self.seamFrames) }
        for i in 0..<Self.concealDecayFrames { decayTable[i] = 1 - rise(i, Self.concealDecayFrames) }
        cursor = slot
    }

    deinit {
        current.deallocate()
        skippedFrame.deallocate()
        scratch.deallocate()
        payload.deallocate()
        skippedPayload.deallocate()
        history.deallocate()
        loop.deallocate()
        decimated.deallocate()
        fadeTable.deallocate()
        seamTable.deallocate()
        decayTable.deallocate()
    }

    /// Fraction of the in-flight playout frame (0..<1, in frames) not yet
    /// rendered — the "partially played frame" part of the receiver's
    /// buffer-depth readout.
    public var partiallyPlayedFrames: Double {
        Double(pendingSamples.load(ordering: .relaxed)) / Double(interleavedPerSlot)
    }

    /// Concealment counters since launch (relaxed snapshot).
    public var stats: ConcealmentStats {
        var stats = ConcealmentStats()
        stats.concealedFrames = concealedFrames.load(ordering: .relaxed)
        stats.concealments = concealments.load(ordering: .relaxed)
        stats.fadeOuts = fadeOuts.load(ordering: .relaxed)
        stats.fadeIns = fadeIns.load(ordering: .relaxed)
        stats.crossfades = crossfades.load(ordering: .relaxed)
        return stats
    }

    /// Fills exactly `sampleCount` interleaved samples from the playout
    /// stream, popping a new slot whenever the current one is exhausted.
    /// Never runs dry: gaps are concealed or silent.
    public func read(into destination: UnsafeMutablePointer<Float>, sampleCount: Int) {
        var served = 0
        while served < sampleCount {
            if cursor >= interleavedPerSlot {
                advance()
            }
            let chunk = min(sampleCount - served, interleavedPerSlot - cursor)
            (destination + served).update(from: current + cursor, count: chunk)
            cursor += chunk
            served += chunk
        }
        pendingSamples.store(
            currentIsAudio && cursor < interleavedPerSlot ? interleavedPerSlot - cursor : 0,
            ordering: .relaxed)
    }

    /// Discards the in-flight frame and the concealment state before a fresh
    /// run (with the render thread stopped). The next audio fades in.
    public func reset() {
        cursor = interleavedPerSlot
        currentIsAudio = false
        mode = .silent
        previousSequence = nil
        history.update(repeating: 0, count: Self.historyFrames * Self.channels)
        historyWrite = 0
        pendingSamples.store(0, ordering: .relaxed)
    }

    // MARK: - Slot processing (render thread)

    private func advance() {
        cursor = 0
        switch source(payload, skippedPayload) {
        case .frame(let frame) where frame.codec == .pcm16:
            decode(payload, byteCount: frame.byteCount, into: current)
            play(frame)
        case .frame, .lost, .underrun, .buffering:
            // Non-PCM frames are concealed until a decoder exists for them.
            conceal()
        }
        appendToHistory(current)
    }

    private func play(_ frame: PlayoutFrame) {
        switch mode {
        case .audio:
            if frame.skippedByteCount > 0, let previous = previousSequence,
                frame.sequence == previous &+ 2
            {
                // Latency trim: the skipped frame continues the last output
                // exactly; crossfade it into this one across the slot.
                decode(skippedPayload, byteCount: frame.skippedByteCount, into: skippedFrame)
                crossfade(from: skippedFrame)
                crossfades.add(1, ordering: .relaxed)
            } else if let previous = previousSequence, frame.sequence != previous &+ 1 {
                // Any other jump: crossfade from a continuation of the old
                // stream.
                startConcealment()
                generate(into: scratch, frames: Self.fadeFrames)
                crossfade(from: scratch)
                crossfades.add(1, ordering: .relaxed)
            }
        case .concealing:
            // Resume: the concealment keeps running under the crossfade.
            generate(into: scratch, frames: Self.fadeFrames)
            crossfade(from: scratch)
            fadeIns.add(1, ordering: .relaxed)
        case .silent:
            for i in 0..<Self.fadeFrames {
                let gain = fadeTable[i]
                current[2 * i] *= gain
                current[2 * i + 1] *= gain
            }
            if hasStarted {
                fadeIns.add(1, ordering: .relaxed)
            }
        }
        mode = .audio
        hasStarted = true
        previousSequence = frame.sequence
        currentIsAudio = true
    }

    private func conceal() {
        if hasStarted {
            concealedFrames.add(1, ordering: .relaxed)
        }
        currentIsAudio = false
        previousSequence = nil
        switch mode {
        case .audio:
            startConcealment()
            concealments.add(1, ordering: .relaxed)
            mode = .concealing
        case .concealing:
            break
        case .silent:
            current.update(repeating: 0, count: interleavedPerSlot)
            return
        }
        generate(into: current, frames: Self.slotFrames)
        if concealPosition >= Self.concealHoldFrames + Self.concealDecayFrames {
            mode = .silent
            fadeOuts.add(1, ordering: .relaxed)
        }
    }

    /// `current[i] = from[i] × (1 − w) + current[i] × w` over the first
    /// `fadeFrames` frames, w a raised cosine 0 → 1.
    private func crossfade(from source: UnsafeMutablePointer<Float>) {
        for i in 0..<Self.fadeFrames {
            let weight = fadeTable[i]
            for channel in 0..<Self.channels {
                let index = 2 * i + channel
                current[index] = source[index] + (current[index] - source[index]) * weight
            }
        }
    }

    // MARK: - Concealment generator

    /// History sample `back` frames before the newest one (1 = newest).
    @inline(__always)
    private func historySample(back: Int, channel: Int) -> Float {
        let index = (historyWrite - back + Self.historyFrames) % Self.historyFrames
        return history[index * Self.channels + channel]
    }

    /// Builds the loop from the output history: the last `loopLength`
    /// frames, with the seam blended towards the period before so that the
    /// loop wraps without a step, and an offset correction that joins the
    /// first generated sample to the last output sample.
    private func startConcealment() {
        let length = findLoopLength()
        loopLength = length
        for j in 0..<length {
            for channel in 0..<Self.channels {
                var value = historySample(back: length - j, channel: channel)
                let seamStart = length - Self.seamFrames
                if j >= seamStart {
                    // Towards the sample one loop earlier, whose successor is
                    // exactly loop[0].
                    let earlier = historySample(back: 2 * length - j, channel: channel)
                    value += (earlier - value) * seamTable[j - seamStart]
                }
                loop[j * Self.channels + channel] = value
            }
        }
        let lastLeft = historySample(back: 1, channel: 0)
        let lastRight = historySample(back: 1, channel: 1)
        // loop[0]'s natural predecessor is loop[length − 1].
        correctionLeft = lastLeft - loop[(length - 1) * Self.channels]
        correctionRight = lastRight - loop[(length - 1) * Self.channels + 1]
        loopPhase = 0
        concealPosition = 0
    }

    /// Writes `frames` concealment frames (interleaved) into `out`.
    private func generate(into out: UnsafeMutablePointer<Float>, frames: Int) {
        let end = Self.concealHoldFrames + Self.concealDecayFrames
        for i in 0..<frames {
            let position = concealPosition
            let gain: Float
            if position < Self.concealHoldFrames {
                gain = 1
            } else if position < end {
                gain = decayTable[position - Self.concealHoldFrames]
            } else {
                gain = 0
            }
            var left = loop[loopPhase * Self.channels]
            var right = loop[loopPhase * Self.channels + 1]
            if position < Self.seamFrames {
                let fade = 1 - seamTable[position]
                left += correctionLeft * fade
                right += correctionRight * fade
            }
            out[2 * i] = left * gain
            out[2 * i + 1] = right * gain
            loopPhase += 1
            if loopPhase == loopLength { loopPhase = 0 }
            concealPosition = min(position + 1, end)
        }
    }

    /// Loop length in [10, 20] ms that best repeats the recent output:
    /// normalized autocorrelation on a 4× decimated mono copy, refined at
    /// full rate. Bounded work (≈ 10 k multiply-adds), no allocation.
    private func findLoopLength() -> Int {
        let decimatedCount = 2 * Self.maxLoopFrames / Self.decimation  // 480
        // decimated[k], k = 0 oldest … decimatedCount − 1 newest.
        for k in 0..<decimatedCount {
            var sum: Float = 0
            for d in 0..<Self.decimation {
                let back = (decimatedCount - k) * Self.decimation - d
                sum += historySample(back: back, channel: 0) + historySample(back: back, channel: 1)
            }
            decimated[k] = sum
        }
        let window = Self.searchWindow
        let minLag = Self.minLoopFrames / Self.decimation
        let maxLag = Self.maxLoopFrames / Self.decimation
        var energyTail: Float = 0
        for i in 0..<window {
            let value = decimated[decimatedCount - window + i]
            energyTail += value * value
        }
        guard energyTail > 1e-9 else { return Self.minLoopFrames }
        var bestLag = minLag
        var bestScore: Float = -.infinity
        for lag in minLag...maxLag {
            var cross: Float = 0
            var energy: Float = 0
            for i in 0..<window {
                let a = decimated[decimatedCount - window + i]
                let b = decimated[decimatedCount - window + i - lag]
                cross += a * b
                energy += b * b
            }
            let score = cross / sqrt(max(energy * energyTail, 1e-12))
            if score > bestScore + 1e-4 {
                bestScore = score
                bestLag = lag
            }
        }
        // Full-rate refinement around the decimated lag.
        let coarse = bestLag * Self.decimation
        let low = max(Self.minLoopFrames, coarse - Self.decimation)
        let high = min(Self.maxLoopFrames, coarse + Self.decimation)
        let fullWindow = Self.slotFrames
        var best = coarse
        bestScore = -.infinity
        for length in low...high {
            var cross: Float = 0
            var energyA: Float = 0
            var energyB: Float = 0
            for back in 1...fullWindow {
                let a = historySample(back: back, channel: 0) + historySample(back: back, channel: 1)
                let b = historySample(back: back + length, channel: 0)
                    + historySample(back: back + length, channel: 1)
                cross += a * b
                energyA += a * a
                energyB += b * b
            }
            let score = cross / sqrt(max(energyA * energyB, 1e-12))
            if score > bestScore + 1e-6 {
                bestScore = score
                best = length
            }
        }
        return best
    }

    // MARK: - Helpers

    private func appendToHistory(_ frame: UnsafeMutablePointer<Float>) {
        for i in 0..<Self.slotFrames {
            let index = historyWrite * Self.channels
            history[index] = frame[2 * i]
            history[index + 1] = frame[2 * i + 1]
            historyWrite = historyWrite + 1 == Self.historyFrames ? 0 : historyWrite + 1
        }
    }

    /// Decodes little-endian Int16 interleaved bytes into `out`, zero-filling
    /// any shortfall (defensive against short payloads).
    private func decode(_ bytes: UnsafeMutableRawBufferPointer, byteCount: Int, into out: UnsafeMutablePointer<Float>) {
        let bytesPerSample = MemoryLayout<Int16>.size
        let toDecode = min(min(byteCount, bytes.count) / bytesPerSample, interleavedPerSlot)
        for i in 0..<toDecode {
            let value = bytes.loadUnaligned(fromByteOffset: i * bytesPerSample, as: Int16.self)
            out[i] = Float(Int16(littleEndian: value)) / 32768
        }
        if toDecode < interleavedPerSlot {
            (out + toDecode).update(repeating: 0, count: interleavedPerSlot - toDecode)
        }
    }
}
