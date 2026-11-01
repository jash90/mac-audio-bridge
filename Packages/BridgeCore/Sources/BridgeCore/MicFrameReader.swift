import Foundation
import Synchronization

/// Counters of the mic reader (relaxed snapshot).
public struct MicReaderStats: Sendable, Equatable {
    /// 10 ms frames decoded from the jitter buffer.
    public var framesPlayed = 0
    /// Frames concealed (lost, late, or the buffer ran dry while playing).
    public var concealedFrames = 0
    /// Single samples dropped / inserted by the drift correction.
    public var samplesDropped = 0
    public var samplesInserted = 0
    public var decodeErrors = 0

    public init() {}
}

/// Turns the mic jitter buffer's 10 ms slots into the feeder device's
/// arbitrary-size reads (mono Float32, 48 kHz) — the Mac side of "Talk
/// through iPhone".
///
/// - Decoding: Opus (`VoiceOpusDecoder`) or PCM16, in playout order.
/// - Concealment: the first missing frame is Opus PLC (PCM: the previous
///   frame again); a longer gap fades to silence within 5 ms, and audio
///   fades back in over 5 ms. Start, stop (`fadeOut`) and the end of a
///   stream fade too, so the call never hears a step.
/// - Clock drift: the phone's and the Mac's audio clocks differ by tens of
///   ppm, so the buffer would slowly fill up or run dry. Once per frame the
///   reader reads the buffer depth (`playoutDepth`), smooths the fill
///   (buffered frames + what it still holds) and, when the smoothed fill
///   leaves a band around the jitter buffer's target, drops or repeats ONE
///   sample, crossfading the stream into its one-sample-shifted self over
///   2 ms. At most one correction per 5 ms (≈ 4000 ppm of range); ±200 ppm
///   needs about 10 per second, which is inaudible.
///
/// Realtime: every buffer is allocated at init; `read` never allocates,
/// takes no lock of its own (the jitter buffer's pop and depth probe take
/// its short unfair lock) and never logs. Control from other threads goes
/// through atomics (`fadeOut`, `requestReset`). One reading thread only.
public final class MicFrameReader: @unchecked Sendable {
    public typealias Source = @Sendable (
        _ payload: UnsafeMutableRawBufferPointer, _ skippedPayload: UnsafeMutableRawBufferPointer
    ) -> PlayoutSlot
    public typealias DepthProbe = @Sendable () -> (depth: Int, target: Int)

    public static let frameSamples = MicFormat.samplesPerFrame
    /// Fade length for starts, stops and concealment: 5 ms.
    public static let fadeSamples = 240
    /// Crossfade of one drift correction: 2 ms.
    public static let correctionCrossfade = 96
    /// Minimum spacing between corrections: 5 ms.
    public static let correctionSpacing = 240
    /// Smoothing of the fill (per frame): time constant ≈ 0.5 s.
    public static let fillSmoothing = 0.02
    /// Band around the target, in frames: drop above `target + dropAbove`
    /// until back at `target + dropUntil`; repeat below `target − insertBelow`
    /// until back at `target − insertUntil`.
    public static let dropAbove = 1.0
    public static let dropUntil = 0.5
    public static let insertBelow = 1.25
    public static let insertUntil = 0.75
    /// Frames of steady playout before the correction acts (the smoothed
    /// fill settles first): 1 s.
    public static let correctionWarmUpFrames = 100

    private let source: Source
    private let depthProbe: DepthProbe
    private let decoder: VoiceOpusDecoder?

    // Sample buffer: decoded frames appended at `count`, read at `cursor`;
    // the sample before `cursor` is kept (a repeat needs it).
    private static let bufferCapacity = 4 * MicFormat.samplesPerFrame + 4
    private let buffer: UnsafeMutablePointer<Float>
    private var cursor = 1
    private var count = 1
    private let lastFrame: UnsafeMutablePointer<Float>
    private let payload: UnsafeMutableRawBufferPointer
    private let skipped: UnsafeMutableRawBufferPointer

    private var gain: Float = 0
    private var targetGain: Float = 0
    private var concealRun = 0
    private var hasAudio = false
    private var lastCodec: AudioCodec?

    private var fillEstimate: Double?
    private var steadyFrames = 0
    private var correcting: Int = 0  // +1 drop, −1 repeat, 0 none
    private var correctionPhase = 0
    private var correctionDirection = 0  // the band we are correcting out of
    private var samplesSinceCorrection = 0

    private let fadeOutFlag = Atomic<Bool>(false)
    private let resetFlag = Atomic<Bool>(false)
    private let levelBits = Atomic<UInt32>(0)
    private let played = Atomic<Int>(0)
    private let concealed = Atomic<Int>(0)
    private let dropped = Atomic<Int>(0)
    private let inserted = Atomic<Int>(0)
    private let decodeErrors = Atomic<Int>(0)
    private var level: Float = 0

    public init(source: @escaping Source, depthProbe: @escaping DepthProbe) {
        self.source = source
        self.depthProbe = depthProbe
        decoder = try? VoiceOpusDecoder()
        buffer = .allocate(capacity: Self.bufferCapacity)
        buffer.initialize(repeating: 0, count: Self.bufferCapacity)
        lastFrame = .allocate(capacity: Self.frameSamples)
        lastFrame.initialize(repeating: 0, count: Self.frameSamples)
        payload = .allocate(byteCount: JitterBuffer.maxFramePayloadBytes, alignment: 16)
        skipped = .allocate(byteCount: JitterBuffer.maxFramePayloadBytes, alignment: 16)
    }

    deinit {
        buffer.deallocate()
        lastFrame.deallocate()
        payload.deallocate()
        skipped.deallocate()
    }

    /// True: fade to silence and stay silent (stop, Mac-side mute); false:
    /// play again (fading in).
    public var fadeOut: Bool {
        get { fadeOutFlag.load(ordering: .relaxed) }
        set { fadeOutFlag.store(newValue, ordering: .relaxed) }
    }

    /// The next `read` starts from scratch (silence, decoder reset).
    public func requestReset() {
        resetFlag.store(true, ordering: .relaxed)
    }

    /// Output level, a decaying RMS (0...1), for the menu's meter.
    public var outputLevel: Float {
        Float(bitPattern: levelBits.load(ordering: .relaxed))
    }

    public var stats: MicReaderStats {
        var stats = MicReaderStats()
        stats.framesPlayed = played.load(ordering: .relaxed)
        stats.concealedFrames = concealed.load(ordering: .relaxed)
        stats.samplesDropped = dropped.load(ordering: .relaxed)
        stats.samplesInserted = inserted.load(ordering: .relaxed)
        stats.decodeErrors = decodeErrors.load(ordering: .relaxed)
        return stats
    }

    /// Fills `out` with `sampleCount` mono samples. Realtime-safe.
    public func read(into out: UnsafeMutablePointer<Float>, sampleCount: Int) {
        if resetFlag.exchange(false, ordering: .relaxed) {
            resetState()
        }
        let wantGain: Float = fadeOutFlag.load(ordering: .relaxed) ? 0 : 1
        let gainStep = 1 / Float(Self.fadeSamples)
        var sumSquares: Float = 0
        var i = 0
        while i < sampleCount {
            if count - cursor < 2 {
                pullFrame()
            }
            // Hot loop on locals (no per-sample property access); state is
            // written back before the next pull, which reads and changes it.
            let samples = buffer
            let available = count
            let goal = min(targetGain, wantGain)
            var position = cursor
            var direction = correcting
            var phase = correctionPhase
            var since = samplesSinceCorrection
            var currentGain = gain
            while i < sampleCount, available - position >= 2 {
                var sample = samples[position]
                if direction != 0 {
                    phase += 1
                    let weight = Float(phase) / Float(Self.correctionCrossfade + 1)
                    sample += weight * (samples[position + direction] - sample)
                    if phase == Self.correctionCrossfade {
                        position += direction
                        direction = 0
                        since = 0
                    }
                }
                position += 1
                since += 1
                if currentGain < goal {
                    currentGain = min(goal, currentGain + gainStep)
                } else if currentGain > goal {
                    currentGain = max(goal, currentGain - gainStep)
                }
                let value = sample * currentGain
                out[i] = value
                sumSquares += value * value
                i += 1
            }
            cursor = position
            correcting = direction
            correctionPhase = phase
            samplesSinceCorrection = since
            gain = currentGain
        }
        if sampleCount > 0 {
            let rms = (sumSquares / Float(sampleCount)).squareRoot()
            level = max(rms, level * 0.9)
            levelBits.store(level.bitPattern, ordering: .relaxed)
        }
    }

    // MARK: - Frames

    private func resetState() {
        cursor = 1
        count = 1
        buffer[0] = 0
        gain = 0
        targetGain = 0
        concealRun = 0
        hasAudio = false
        lastCodec = nil
        fillEstimate = nil
        steadyFrames = 0
        correcting = 0
        correctionPhase = 0
        correctionDirection = 0
        samplesSinceCorrection = 0
        level = 0
        lastFrame.update(repeating: 0, count: Self.frameSamples)
        decoder?.reset()
    }

    /// Compacts the buffer (keeping one sample before the cursor) and
    /// appends the next 10 ms frame or its concealment.
    private func pullFrame() {
        let keepFrom = cursor - 1
        let keep = count - keepFrom
        if keepFrom > 0 {
            buffer.update(from: buffer + keepFrom, count: keep)
            cursor -= keepFrom
            count = keep
        }
        let destination = buffer + count
        count += Self.frameSamples

        switch source(payload, skipped) {
        case .frame(let frame):
            if frame.flags.contains(.discontinuity) || frame.codec != lastCodec {
                decoder?.reset()
                fillEstimate = nil
                steadyFrames = 0
            }
            lastCodec = frame.codec
            if decode(frame, into: destination) {
                played.wrappingAdd(1, ordering: .relaxed)
                hasAudio = true
                concealRun = 0
                targetGain = 1
                lastFrame.update(from: destination, count: Self.frameSamples)
                steadyFrames += 1
                updateDriftCorrection()
            } else {
                decodeErrors.wrappingAdd(1, ordering: .relaxed)
                conceal(into: destination, starved: false)
            }
        case .lost:
            // Playout moves past the frame: the fill is not disturbed.
            conceal(into: destination, starved: false)
        case .underrun:
            conceal(into: destination, starved: true)
        case .buffering:
            if gain > 0 || targetGain > 0 {
                conceal(into: destination, starved: true)
            } else {
                destination.update(repeating: 0, count: Self.frameSamples)
            }
        }
    }

    private func decode(_ frame: PlayoutFrame, into out: UnsafeMutablePointer<Float>) -> Bool {
        switch frame.codec {
        case .opus:
            guard let decoder, let base = payload.baseAddress, frame.byteCount > 0 else { return false }
            return decoder.decode(base, count: frame.byteCount, into: out) == Self.frameSamples
        case .pcm16:
            let samples = min(frame.byteCount / 2, Self.frameSamples)
            for i in 0..<samples {
                let value = payload.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)
                out[i] = Float(Int16(littleEndian: value)) / 32768
            }
            if samples < Self.frameSamples {
                (out + samples).update(repeating: 0, count: Self.frameSamples - samples)
            }
            return samples > 0
        }
    }

    /// One missing frame: PLC (or the previous frame) at full level for the
    /// first one, fading to silence from the second; silence once faded.
    /// `starved`: the buffer ran dry, so its cushion is rebuilt and the fill
    /// estimate starts over.
    private func conceal(into out: UnsafeMutablePointer<Float>, starved: Bool) {
        concealRun += 1
        if starved {
            fillEstimate = nil
            steadyFrames = 0
        }
        guard hasAudio else {
            out.update(repeating: 0, count: Self.frameSamples)
            return
        }
        concealed.wrappingAdd(1, ordering: .relaxed)
        if lastCodec == .opus, let decoder, decoder.conceal(into: out) == Self.frameSamples {
            // Opus PLC continues the voice smoothly.
        } else {
            out.update(from: lastFrame, count: Self.frameSamples)
        }
        if concealRun >= 2 {
            targetGain = 0
        }
    }

    /// Once per decoded frame: smooth the fill and start a one-sample
    /// correction when it leaves the band around the target.
    private func updateDriftCorrection() {
        let (depth, target) = depthProbe()
        let fill = Double(depth) + Double(count - cursor) / Double(Self.frameSamples)
        let estimate = fillEstimate.map { $0 + Self.fillSmoothing * (fill - $0) } ?? fill
        fillEstimate = estimate
        guard steadyFrames >= Self.correctionWarmUpFrames, correcting == 0,
            samplesSinceCorrection >= Self.correctionSpacing
        else { return }
        let deviation = estimate - Double(target)
        switch correctionDirection {
        case 1 where deviation <= Self.dropUntil, -1 where deviation >= -Self.insertUntil:
            correctionDirection = 0
        case 0 where deviation > Self.dropAbove:
            correctionDirection = 1
        case 0 where deviation < -Self.insertBelow:
            correctionDirection = -1
        default:
            break
        }
        guard correctionDirection != 0 else { return }
        // Drop: crossfade into the stream one sample ahead; repeat: into the
        // stream one sample behind. The buffer holds ≥ 2 samples past the
        // cursor plus the full new frame, and one sample before it.
        correcting = correctionDirection
        correctionPhase = 0
        let shift = Double(correctionDirection) / Double(Self.frameSamples)
        fillEstimate = estimate - shift
        if correctionDirection > 0 {
            dropped.wrappingAdd(1, ordering: .relaxed)
        } else {
            inserted.wrappingAdd(1, ordering: .relaxed)
        }
    }
}
