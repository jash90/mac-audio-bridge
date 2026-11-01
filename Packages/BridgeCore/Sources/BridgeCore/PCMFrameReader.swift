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
    /// Splices inside real audio (latency trim, overflow resync, codec
    /// switch) that were crossfaded.
    public var crossfades = 0
    /// Slots synthesized by Opus packet-loss concealment (the decoder's own
    /// continuation of an Opus stream).
    public var opusPlcFrames = 0
    /// Frames whose payload could not be decoded (concealed instead).
    public var decodeErrors = 0

    public init() {}
}

/// The codec and frame size of the stream being played, for the UI.
public struct PlayoutStream: Sendable, Equatable {
    public var codec: AudioCodec
    /// Payload bytes of the last frame played (a primary, not a copy).
    public var payloadBytes: Int
    /// 5 ms slots of that frame (4 = 20 ms).
    public var frameSlots: Int

    public init(codec: AudioCodec, payloadBytes: Int, frameSlots: Int = 1) {
        self.codec = codec
        self.payloadBytes = payloadBytes
        self.frameSlots = frameSlots
    }

    /// "Opus 192 kbit/s" / "Opus 96 kbit/s · 20 ms" / "PCM (uncompressed)".
    public var displayName: String {
        StreamQuality.receiverDescription(codec: codec, payloadBytes: payloadBytes, frameSlots: frameSlots)
    }
}

/// Serves arbitrary-size reads of interleaved stereo Float samples from the
/// jitter buffer's 5 ms playout slots, decoding PCM16 and Opus (per frame,
/// following each frame's codec) and concealing every gap so that the output
/// never jumps: no step between audio and silence, no hard splice.
///
/// Realtime contract: all storage — including the Opus decoder state — is
/// preallocated at init; `read(into:)` performs no allocation, uses no Swift
/// concurrency, and meets no locks of its own (the source — the jitter
/// buffer's realtime `pop` — copies the payload into the reader's buffers
/// under its short unfair lock). `read` must be called from a single thread
/// (the render thread); the stats and `partiallyPlayedFrames` may be read
/// from any thread.
///
/// Why Opus is decoded here, on the render thread, and not on packet
/// arrival: the decoder is stateful and must see the frames in playout
/// order, with a concealment call exactly where a frame is missing. Arrival
/// order is not playout order (reordering, redundant copies filling earlier
/// slots, late frames, trims), and whether a slot is lost is only known at
/// playout time. libopus decode / PLC never allocates (stack scratch via
/// `USE_ALLOCA`) and takes no locks; one 5 ms frame costs ≈ 40–50 µs.
///
/// 20 ms Opus frames (the Internet profile) occupy four consecutive slots:
/// the frame is decoded whole (960 samples) when its first slot comes up, and
/// the next three slots are served from that decoded block. A missing slot is
/// concealed by Opus PLC 5 ms at a time, so a lost 20 ms frame becomes four
/// PLC slots and the next frame joins the PLC signal as after any loss. A
/// low-rate copy that stands in for a lost frame goes through the same
/// decoder (Opus follows bitrate changes from packet to packet).
///
/// Playout rules, one slot at a time:
/// - a frame continuing the previous one is played as is;
/// - a frame after the latency trim skipped its predecessor is crossfaded
///   from the skipped frame over the whole 5 ms slot (both ends stay
///   continuous with their real neighbours);
/// - a frame after any other skip (overflow resync), or of another codec
///   or a restarted Opus stream, is crossfaded from a continuation of the
///   old stream over 5 ms;
/// - a loss / underrun / buffering slot after audio starts concealment.
///   PCM16: the last 10–20 ms of output are looped (loop length chosen by
///   autocorrelation, loop seam blended), joined to the last output sample
///   with a 2 ms offset correction, held at full level for 10 ms and then
///   faded to silence with a raised cosine over 40 ms. Opus: the decoder's
///   own PLC continues the signal, at full level for 20 ms and then under
///   the same 40 ms fade (a short gap is pure Opus PLC; only a long one
///   fades);
/// - the first frame after concealment is crossfaded from the (still
///   running) concealment over 5 ms — after Opus PLC, the decoded frame
///   already continues the PLC signal, so only the fade gain ramps back to
///   1; after silence it fades in over 5 ms.
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
    /// Loop concealment (PCM16) holds full level for 10 ms …
    public static let concealHoldFrames = 480
    /// … Opus PLC for 20 ms (it is a real continuation, not a loop) …
    public static let opusConcealHoldFrames = 960
    /// … then both fade to silence over 40 ms (50 / 60 ms of concealment).
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
    /// The decoded multi-slot frame being served (up to 20 ms).
    private let block: UnsafeMutablePointer<Float>
    /// Opus decoder (render thread only); nil only if libopus failed to
    /// create one, in which case Opus frames are concealed.
    private let opus: OpusDecoderBox?

    // State confined to the render thread.
    /// What generates concealment samples.
    private enum ConcealSource {
        /// Loop of the output history (PCM16 streams).
        case loop
        /// The Opus decoder's packet-loss concealment.
        case opusPlc
    }

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
    private var concealSource = ConcealSource.loop
    /// Full-level part of the running concealment (loop or Opus hold).
    private var holdFrames = PCMFrameReader.concealHoldFrames
    /// Codec of the last frame decoded (nil before the first): the stream
    /// the Opus decoder state belongs to.
    private var streamCodec: AudioCodec?
    /// `block` holds the decoded frame whose first slot is `blockBase`,
    /// `blockSlots` slots long.
    private var blockValid = false
    private var blockBase: UInt32 = 0
    private var blockSlots = 0

    /// Remaining interleaved samples of the frame being played, published for
    /// the latency readout. Relaxed and approximate by design.
    private let pendingSamples = Atomic<Int>(0)
    private let concealedFrames = Atomic<Int>(0)
    private let concealments = Atomic<Int>(0)
    private let fadeOuts = Atomic<Int>(0)
    private let fadeIns = Atomic<Int>(0)
    private let crossfades = Atomic<Int>(0)
    private let opusPlcFrames = Atomic<Int>(0)
    private let decodeErrors = Atomic<Int>(0)
    /// `AudioCodec` raw value of the last frame played; `UInt8.max` = none.
    private let lastCodec = Atomic<UInt8>(.max)
    private let lastPayloadBytes = Atomic<Int>(0)
    private let lastFrameSlots = Atomic<Int>(1)

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
        block = .allocate(capacity: slot * OpusSettings.maxFrameSlots)
        block.initialize(repeating: 0, count: slot * OpusSettings.maxFrameSlots)
        opus = try? OpusDecoderBox()
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
        block.deallocate()
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
        stats.opusPlcFrames = opusPlcFrames.load(ordering: .relaxed)
        stats.decodeErrors = decodeErrors.load(ordering: .relaxed)
        return stats
    }

    /// Codec and frame size of the last frame played; nil before the first
    /// (relaxed snapshot).
    public var stream: PlayoutStream? {
        AudioCodec(rawValue: lastCodec.load(ordering: .relaxed)).map {
            PlayoutStream(
                codec: $0, payloadBytes: lastPayloadBytes.load(ordering: .relaxed),
                frameSlots: lastFrameSlots.load(ordering: .relaxed))
        }
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
        blockValid = false
        history.update(repeating: 0, count: Self.historyFrames * Self.channels)
        historyWrite = 0
        pendingSamples.store(0, ordering: .relaxed)
    }

    // MARK: - Slot processing (render thread)

    private func advance() {
        cursor = 0
        if case .frame(let frame) = source(payload, skippedPayload) {
            play(frame)
        } else {
            conceal()
        }
        appendToHistory(current)
    }

    /// How a frame joins the output before it.
    private enum Join {
        /// Continues the previous frame exactly.
        case asIs
        /// From silence: 5 ms fade-in.
        case fadeIn
        /// After a trimmed frame: crossfade from the skipped frame.
        case trim
        /// Crossfade from a continuation of the old stream (`scratch`).
        case continuation
        /// After Opus PLC of the same stream: the decoded frame continues the
        /// PLC signal, only the concealment gain ramps back to 1.
        case rampFromPlc
    }

    private func play(_ frame: PlayoutFrame) {
        // A fresh Opus stream (codec switch, or a sender restart) needs a
        // fresh decoder; either way the old stream's state does not continue.
        let restartsOpus = frame.codec == .opus
            && (streamCodec != .opus || frame.flags.contains(.discontinuity))
        let switchesStream = streamCodec != nil && (frame.codec != streamCodec || restartsOpus)

        let join: Join
        switch mode {
        case .silent:
            join = .fadeIn
        case .audio:
            if frame.hasSkipped, let previous = previousSequence,
                frame.sequence == previous &+ 2, !switchesStream, frame.skippedCodec == frame.codec
            {
                join = .trim
            } else if let previous = previousSequence, frame.sequence == previous &+ 1, !switchesStream {
                join = .asIs
            } else {
                join = .continuation
            }
        case .concealing:
            join = concealSource == .opusPlc && frame.codec == .opus && !restartsOpus
                ? .rampFromPlc : .continuation
        }

        // The continuation is generated BEFORE the new frame is decoded: an
        // Opus PLC continuation must come from the old decoder state.
        if join == .continuation {
            if mode == .audio {
                startConcealment()
            }
            generate(into: scratch, frames: Self.fadeFrames)
        }
        if restartsOpus {
            opus?.reset()
        }
        if join == .trim,
            !render(
                frame.skippedCodec, skippedPayload, frame.skippedByteCount, sequence: frame.sequence &- 1,
                slots: frame.skippedFrameSlots, part: frame.skippedPart, into: skippedFrame)
        {
            // The skipped frame continues the last output exactly; when it
            // cannot be decoded, conceal it instead (Opus: PLC, which keeps
            // the decoder in step).
            decodeErrors.add(1, ordering: .relaxed)
            startConcealment()
            generate(into: skippedFrame, frames: Self.fadeFrames)
        }
        guard
            render(
                frame.codec, payload, frame.byteCount, sequence: frame.sequence, slots: frame.frameSlots,
                part: frame.part, into: current)
        else {
            decodeErrors.add(1, ordering: .relaxed)
            if restartsOpus {
                // The decoder was just reset: its PLC would be silence, so
                // conceal from the output history instead.
                streamCodec = nil
            }
            conceal()
            return
        }
        streamCodec = frame.codec

        switch join {
        case .asIs:
            break
        case .fadeIn:
            for i in 0..<Self.fadeFrames {
                let gain = fadeTable[i]
                current[2 * i] *= gain
                current[2 * i + 1] *= gain
            }
            if hasStarted {
                fadeIns.add(1, ordering: .relaxed)
            }
        case .trim:
            // Latency trim: the skipped frame continues the last output
            // exactly; crossfade it into this one across the slot.
            crossfade(from: skippedFrame)
            crossfades.add(1, ordering: .relaxed)
        case .continuation:
            crossfade(from: scratch)
            if mode == .audio {
                crossfades.add(1, ordering: .relaxed)
            } else {
                fadeIns.add(1, ordering: .relaxed)
            }
        case .rampFromPlc:
            let gain = envelopeGain(at: concealPosition)
            if gain < 1 {
                for i in 0..<Self.fadeFrames {
                    let weight = gain + (1 - gain) * fadeTable[i]
                    current[2 * i] *= weight
                    current[2 * i + 1] *= weight
                }
            }
            fadeIns.add(1, ordering: .relaxed)
        }
        mode = .audio
        hasStarted = true
        previousSequence = frame.sequence
        currentIsAudio = true
        if frame.part == 0, !frame.recovered {
            lastCodec.store(frame.codec.rawValue, ordering: .relaxed)
            lastPayloadBytes.store(frame.byteCount, ordering: .relaxed)
            lastFrameSlots.store(frame.frameSlots, ordering: .relaxed)
        }
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
        if concealPosition >= holdFrames + Self.concealDecayFrames {
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

    /// Starts a concealment of the current stream at full level: Opus PLC
    /// for an Opus stream (the decoder continues the signal), the history
    /// loop otherwise.
    private func startConcealment() {
        concealPosition = 0
        if streamCodec == .opus, opus != nil {
            concealSource = .opusPlc
            holdFrames = Self.opusConcealHoldFrames
        } else {
            buildLoop()
            concealSource = .loop
            holdFrames = Self.concealHoldFrames
        }
    }

    /// Concealment gain at `position` frames into the concealment: 1 during
    /// the hold, then the raised-cosine decay, then 0.
    @inline(__always)
    private func envelopeGain(at position: Int) -> Float {
        if position < holdFrames { return 1 }
        let decayIndex = position - holdFrames
        return decayIndex < Self.concealDecayFrames ? decayTable[decayIndex] : 0
    }

    /// Builds the loop from the output history: the last `loopLength`
    /// frames, with the seam blended towards the period before so that the
    /// loop wraps without a step, and an offset correction that joins the
    /// first generated sample to the last output sample.
    private func buildLoop() {
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
    }

    /// Writes `frames` concealment frames (interleaved) into `out`.
    private func generate(into out: UnsafeMutablePointer<Float>, frames: Int) {
        let end = holdFrames + Self.concealDecayFrames
        if concealSource == .opusPlc, let opus, frames == Self.slotFrames {
            if opus.conceal(into: out) == frames {
                opusPlcFrames.add(1, ordering: .relaxed)
                for i in 0..<frames {
                    let gain = envelopeGain(at: concealPosition)
                    out[2 * i] *= gain
                    out[2 * i + 1] *= gain
                    concealPosition = min(concealPosition + 1, end)
                }
                return
            }
            // PLC failed (should not happen): fall back to the loop.
            decodeErrors.add(1, ordering: .relaxed)
            buildLoop()
            concealSource = .loop
        }
        for i in 0..<frames {
            let position = concealPosition
            let gain = envelopeGain(at: position)
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

    /// One slot of audio into `out`: a single-slot frame is decoded
    /// directly; part 0 of a multi-slot frame decodes the whole frame into
    /// `block` and serves its first slot, later parts are served from that
    /// block. False when the payload is not a valid frame, or a later part's
    /// first slot was never decoded (dropped by an overflow resync).
    private func render(
        _ codec: AudioCodec, _ bytes: UnsafeMutableRawBufferPointer, _ byteCount: Int, sequence: UInt32,
        slots: Int, part: Int, into out: UnsafeMutablePointer<Float>
    ) -> Bool {
        guard slots > 1 else {
            blockValid = false
            return decode(codec, bytes, byteCount, into: out)
        }
        guard slots <= OpusSettings.maxFrameSlots, part < slots else { return false }
        if part == 0 {
            blockValid = false
            let frames = slots * Self.slotFrames
            guard codec == .opus, let opus, let base = bytes.baseAddress, byteCount > 0, byteCount <= bytes.count,
                opus.decode(base, count: byteCount, into: block, maxFrames: frames) == frames
            else { return false }
            blockValid = true
            blockBase = sequence
            blockSlots = slots
        } else if !blockValid || blockSlots != slots || blockBase &+ UInt32(part) != sequence {
            return false
        }
        out.update(from: block + part * interleavedPerSlot, count: interleavedPerSlot)
        return true
    }

    /// Decodes one frame of `codec` into `out` (one whole slot); false when
    /// the payload is not a valid frame.
    private func decode(
        _ codec: AudioCodec, _ bytes: UnsafeMutableRawBufferPointer, _ byteCount: Int,
        into out: UnsafeMutablePointer<Float>
    ) -> Bool {
        switch codec {
        case .pcm16:
            decodePCM16(bytes, byteCount: byteCount, into: out)
            return true
        case .opus:
            guard let opus, let base = bytes.baseAddress, byteCount > 0, byteCount <= bytes.count else {
                return false
            }
            return opus.decode(base, count: byteCount, into: out) == Self.slotFrames
        }
    }

    /// Decodes little-endian Int16 interleaved bytes into `out`, zero-filling
    /// any shortfall (defensive against short payloads).
    private func decodePCM16(_ bytes: UnsafeMutableRawBufferPointer, byteCount: Int, into out: UnsafeMutablePointer<Float>) {
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
