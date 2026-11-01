import Foundation
import os

/// Named latency modes for the jitter buffer: the trade-off between
/// end-to-end latency and tolerance to delay variation on the network path.
///
/// What the target covers (all adaptive, rising immediately and decaying
/// slowly):
/// - `.low`: the p99 delay of the last 10 s + 10 ms (20–120 ms). Wi-Fi
///   bursts longer than that are bridged by smooth concealment (a fade-out
///   and fade-in), so this mode trades occasional soft dropouts for latency.
/// - `.balanced` (default): the largest delay of the last 45 s + 10 ms
///   (30–300 ms). Covers the recurring 100–180 ms Wi-Fi power-save bursts,
///   so playback stays continuous.
/// - `.safe`: the largest delay of the last 90 s + 30 ms (80–500 ms), for
///   congested links with longer stalls.
public enum JitterLatencyMode: String, CaseIterable, Sendable {
    case low
    case balanced
    case safe
}

/// Tuning parameters for the adaptive jitter buffer. Frame counts are in
/// `frameDuration` units (5 ms); the presets are written in milliseconds.
public struct JitterBufferConfig: Sendable, Equatable {
    /// How the adaptive target depth is derived from the network observations.
    public enum TargetEstimator: Sendable, Equatable {
        /// RFC 3550 interarrival jitter × `jitterMultiplier` (the pre-M2.6
        /// rule). Retained for comparison; the smoothed mean deviation
        /// underestimates bursty delay.
        case rfc3550
        /// The `delayQuantile` of the windowed relative-delay distribution +
        /// `safetyMargin` (the default): the target covers the actual delay
        /// tail, which is what Wi-Fi power-save bursts stress.
        case delayPercentile
    }

    /// Nominal duration of one audio frame (5 ms at 48 kHz).
    public var frameDuration: TimeInterval = AudioFormat.frameDuration
    /// Lower clamp for the adaptive target depth (40 ms).
    public var minTargetFrames = AudioFormat.frames(milliseconds: 40)
    /// Upper clamp for the adaptive target depth (80 ms).
    public var maxTargetFrames = AudioFormat.frames(milliseconds: 80)
    /// Target multiplier for the `.rfc3550` estimator:
    /// ceil(multiplier * jitter / frameDuration) + 1, clamped.
    public var jitterMultiplier = 3.0
    /// Depth above this resyncs the buffer by dropping the oldest frames
    /// down to the target (160 ms). Guards against clock drift (until the
    /// receiver resamples to the output clock) and against the latency a
    /// long stall leaves behind.
    public var overflowFrames = AudioFormat.frames(milliseconds: 160)
    /// How the adaptive target is derived; see `TargetEstimator`.
    public var targetEstimator: TargetEstimator = .delayPercentile
    /// Quantile of the windowed relative-delay distribution the target
    /// covers (`.delayPercentile`): 0.99 = p99, 1.0 = the largest delay.
    public var delayQuantile = 0.99
    /// Headroom added to the delay quantile before converting it to frames
    /// (`.delayPercentile` estimator).
    public var safetyMargin: TimeInterval = 0.010
    /// Sliding window of the delay histogram behind `.delayPercentile`. A
    /// longer window remembers bursts that recur every few seconds.
    public var delayWindowSeconds: TimeInterval = 10.0
    /// The target may only fall once the estimate has stayed below the
    /// current target for this many seconds (arrival clock).
    public var targetFallHoldSeconds: TimeInterval = 5.0
    /// Once falling, at most one frame per this many seconds (5 ms per 1 s,
    /// the same 10 ms per 2 s as with 10 ms frames).
    public var targetFallStepSeconds: TimeInterval = 1.0
    /// An arrival gap longer than this is an outage (Wi-Fi gone for
    /// seconds), not jitter: the delay history restarts and the backlog that
    /// floods in afterwards (`outageSettleSeconds`) is not recorded, so one
    /// outage does not pin the target at the mode maximum for a whole window.
    public var outageThresholdSeconds: TimeInterval = 1.0
    /// After an outage, arrivals are not recorded for this long.
    public var outageSettleSeconds: TimeInterval = 0.5
    /// Latency trim: when the peak depth over a `latencyTrimWindowSeconds`
    /// window of playout exceeds `target + latencyTrimSlackFrames` (20 ms),
    /// one frame is skipped (and crossfaded by the reader) so the real
    /// buffering delay follows a falling target. Nil disables it.
    public var latencyTrimSlackFrames: Int? = AudioFormat.frames(milliseconds: 20)
    /// Playout time per trim decision: at most one 5 ms frame per 0.5 s
    /// (10 ms per second, as before).
    public var latencyTrimWindowSeconds: TimeInterval = 0.5
    /// A missing next frame is given up (reported lost) once a frame this
    /// many sequences newer has arrived: by then its primary and its
    /// redundant copies (sent up to `AudioRedundancy.maxOffset` frames later)
    /// should all have been delivered, so waiting would only stretch the
    /// concealment. Nil = wait whenever the buffer is below its target.
    public var lossHorizonFrames: Int? = AudioRedundancy.maxOffset + 2

    public init() {}

    /// Preset for a latency mode (see `JitterLatencyMode`).
    public static func latency(_ mode: JitterLatencyMode) -> JitterBufferConfig {
        var config = JitterBufferConfig()
        let overflowSlackMs: Double
        switch mode {
        case .low:
            config.minTargetFrames = AudioFormat.frames(milliseconds: 20)
            config.maxTargetFrames = AudioFormat.frames(milliseconds: 120)
            config.delayQuantile = 0.99
            config.delayWindowSeconds = 10
            config.safetyMargin = 0.010
            overflowSlackMs = 30
        case .balanced:
            config.minTargetFrames = AudioFormat.frames(milliseconds: 30)
            config.maxTargetFrames = AudioFormat.frames(milliseconds: 300)
            config.delayQuantile = 1.0
            config.delayWindowSeconds = 45
            config.safetyMargin = 0.010
            overflowSlackMs = 30
        case .safe:
            config.minTargetFrames = AudioFormat.frames(milliseconds: 80)
            config.maxTargetFrames = AudioFormat.frames(milliseconds: 500)
            config.delayQuantile = 1.0
            config.delayWindowSeconds = 90
            config.safetyMargin = 0.030
            overflowSlackMs = 60
        }
        config.overflowFrames = config.maxTargetFrames + AudioFormat.frames(milliseconds: overflowSlackMs)
        return config
    }
}

/// One playout slot of output from the jitter buffer (allocating
/// convenience form, see `JitterBuffer.pop()`).
public enum JitterBufferOutput: Sendable, Equatable {
    /// The next frame, in order.
    case packet(AudioPacket)
    /// The expected frame is missing for good; the caller conceals it and
    /// playout moves past it.
    case lost(sequence: UInt32)
    /// Nothing playable yet (the buffer ran dry, or the next frame is still
    /// in flight while the buffer is shallower than its target): the caller
    /// conceals, and playout waits — no frame is skipped, the latency grows
    /// by one frame instead.
    case underrun
    /// Prebuffering (at start, or after a reset); the caller outputs silence.
    case buffering
}

/// A frame handed out by the realtime `pop(payload:skippedPayload:)`; its
/// payload bytes were copied into the caller's buffer.
public struct PlayoutFrame: Sendable, Equatable {
    public var sequence: UInt32
    public var sampleTime: UInt64
    public var codec: AudioCodec
    public var flags: AudioPacketFlags
    /// Payload bytes copied into the caller's `payload` buffer.
    public var byteCount: Int
    /// When the latency trim skipped the frame right before this one: its
    /// payload size in the caller's `skippedPayload` buffer, so the reader
    /// can crossfade the skipped frame into this one. 0 otherwise.
    public var skippedByteCount: Int
    /// Played from a redundant copy (the primary never arrived).
    public var recovered: Bool
    /// Codec of the skipped frame (meaningful when `hasSkipped`).
    public var skippedCodec: AudioCodec = .pcm16
    /// 5 ms slots of the coded frame this slot belongs to (4 for a 20 ms
    /// Opus frame) and this slot's place in it: part 0 carries the payload,
    /// parts 1... carry none (the reader serves them from the frame it
    /// decoded at part 0).
    public var frameSlots: Int = 1
    public var part: Int = 0
    /// The latency trim skipped the slot right before this one (its payload,
    /// if it is a part 0, is in `skippedPayload`).
    public var hasSkipped = false
    public var skippedFrameSlots: Int = 1
    public var skippedPart: Int = 0
    /// Played from a low-rate redundant copy.
    public var lowRateCopy = false
}

/// One playout slot from the realtime `pop(payload:skippedPayload:)`.
public enum PlayoutSlot: Sendable, Equatable {
    case frame(PlayoutFrame)
    case lost(sequence: UInt32)
    case underrun
    case buffering
}

/// Session counters and the current buffer state, for diagnostics.
public struct JitterBufferStats: Sendable, Equatable {
    /// Primary frames handed to `insert` (including duplicates and late ones).
    public var received = 0
    /// Redundant copies handed to `insert`.
    public var redundantReceived = 0
    /// Playout slots that returned a frame.
    public var played = 0
    /// Frames played from a redundant copy because the primary never arrived.
    public var recovered = 0
    /// Of `recovered`: slots played from a low-rate copy.
    public var lowRateRecovered = 0
    /// Frames skipped at playout time because neither copy arrived in time.
    public var lost = 0
    /// Primary frames discarded because their playout slot had already passed.
    public var late = 0
    /// Redundant copies that arrived after their slot had passed (harmless:
    /// the primary normally played).
    public var redundantLate = 0
    /// Repeated primary frames discarded (network duplicates). Redundant
    /// copies of frames already buffered are not counted here.
    public var duplicates = 0
    /// Oldest frames dropped to recover from depth overflow.
    public var overflowDropped = 0
    /// Frames skipped by the latency trim (depth above target + slack).
    public var trimmed = 0
    /// Underrun events: the buffer ran completely dry while playing, so
    /// playout had to wait (conceal). Each event is one concealment.
    public var underruns = 0
    /// Playout slots spent waiting in underruns (5 ms each).
    public var underrunFrames = 0
    /// Playout slots spent waiting for a missing next frame while later
    /// frames were buffered but the depth was below the target (the frame is
    /// probably late, and the cushion is short anyway). Concealed too.
    public var waitFrames = 0
    /// Returns to prebuffering after a sustained underrun.
    public var rebuffers = 0
    /// Pops that returned `.buffering` after the first playing run started,
    /// i.e. silence gaps mid-stream (initial prebuffering excluded).
    public var bufferingPops = 0
    /// Frames currently buffered.
    public var depthFrames = 0
    /// Current adaptive target depth in frames.
    public var targetFrames = 0
    /// Current RFC 3550 interarrival jitter estimate, in seconds (a stat;
    /// only drives the target with `targetEstimator = .rfc3550`).
    public var jitterSeconds: Double = 0
    /// Relative-delay percentiles over the delay window (arrival minus media
    /// time, anchored at the fastest observed path), in seconds.
    public var delayP50Seconds: Double = 0
    public var delayP95Seconds: Double = 0
    public var delayP99Seconds: Double = 0
    public var delayMaxSeconds: Double = 0
}

/// Payload-agnostic adaptive jitter buffer for `AudioPacket` frames.
/// Decoding and concealment happen in the caller; this type only reorders,
/// times and accounts for frames.
///
/// Threading: `insert` is called from one network queue, `pop` from the
/// audio render thread. The playout state lives behind one short unfair
/// lock; the delay estimator (histogram, jitter, target rules) lives behind
/// a second lock that only `insert`, `stats` and the control calls take, so
/// the render thread never waits for estimator work.
///
/// Realtime: frames are stored in a preallocated ring of fixed-size payload
/// slots (`insert` copies the bytes in, `pop(payload:skippedPayload:)`
/// copies them out), so no `Data` is retained or freed on the render thread
/// and `pop` never allocates.
///
/// Adaptivity: the target depth is `ceil((q + safetyMargin) / frameDuration)`,
/// clamped, where q is the `delayQuantile` of a sliding-window
/// `DelayHistogram` of primary-frame delays. It rises immediately and falls
/// one frame per `targetFallStepSeconds`, only after the estimate stayed low
/// for `targetFallHoldSeconds`.
///
/// Playout: when the next frame is missing and the buffer is shallower than
/// the target (in particular when it ran dry), playout waits (`.underrun`)
/// instead of skipping: the frame is usually only late (a Wi-Fi burst holds
/// packets, it does not lose them), and waiting grows the cushion by the
/// stall. Once the frame shows up, the same dropout continues until the
/// depth reaches the target, so one concealment builds the whole cushion
/// the next burst needs (no separate silent rebuild). A missing frame is
/// reported lost and skipped when the buffer is at its target, or when
/// frames past `lossHorizonFrames` have arrived (its redundant copy would
/// have come with them). Redundant copies fill slots whose primary never
/// arrived (`recovered`).
///
/// Latency trim: the depth does not shrink when the target falls, because
/// arrivals and pops both run at the frame rate. So when the peak depth over
/// a trim window stays above `target + latencyTrimSlackFrames`, one frame is
/// skipped (the reader crossfades it into the next one).
public final class JitterBuffer: @unchecked Sendable {
    /// Payload bytes per slot: the largest frame payload accepted.
    public static let maxFramePayloadBytes = AudioFormat.maxDatagramBytes
    /// Slots in the ring (2.56 s at 5 ms); must exceed every overflow limit.
    public static let slotCount = 512
    private static let slotMask = UInt32(slotCount - 1)

    private enum SlotKind: UInt8 {
        case empty = 0
        case primary = 1
        case redundant = 2
    }

    /// Playout state, guarded by `lock`.
    private struct State: Sendable {
        enum Phase {
            case buffering
            case playing
        }

        var config: JitterBufferConfig
        /// Bumped on every reset; estimator updates from before a reset are
        /// ignored.
        var generation = 0
        var phase: Phase = .buffering
        // Slot ring, indexed by `sequence & slotMask`.
        var slotSequence = [UInt32](repeating: 0, count: JitterBuffer.slotCount)
        var slotKind = [UInt8](repeating: 0, count: JitterBuffer.slotCount)
        var slotSampleTime = [UInt64](repeating: 0, count: JitterBuffer.slotCount)
        var slotLength = [Int](repeating: 0, count: JitterBuffer.slotCount)
        var slotCodec = [UInt8](repeating: 0, count: JitterBuffer.slotCount)
        var slotFlags = [UInt8](repeating: 0, count: JitterBuffer.slotCount)
        /// Slots of the coded frame (1 / 2 / 4) and the slot's part in it.
        var slotSpan = [UInt8](repeating: 1, count: JitterBuffer.slotCount)
        var slotPart = [UInt8](repeating: 0, count: JitterBuffer.slotCount)
        var slotLowRate = [Bool](repeating: false, count: JitterBuffer.slotCount)
        var bufferedCount = 0
        /// Newest sequence accepted since the reset.
        var newestSequence: UInt32?
        /// Next sequence to hand out. Nil until the first buffering exit;
        /// kept across rebuffering so stragglers are still classified as late.
        var nextExpected: UInt32?
        /// Frames before this sequence belong to a previous run (set by a
        /// discontinuity) and are rejected.
        var floorSequence: UInt32?
        var hasPlayedOnce = false
        var inUnderrun = false
        /// The previous pop returned `.underrun` (playout is concealing).
        var waiting = false
        /// Slots added after the missing frame showed up, to finish growing
        /// the cushion to the target within the same concealment.
        var growFrames = 0
        /// Adaptive target depth (owned by the estimator, mirrored here).
        var target: Int
        var consecutiveEmptyPops = 0
        /// Media-clock anchor of the newest primary, used to extrapolate the
        /// media time of any sequence number.
        var anchorSequence: UInt32?
        var anchorMediaTime: TimeInterval = 0
        /// How far playout lags the newest arrival, relative to the fastest
        /// observed path since the reset: the cushion.
        var cushionEstimate: TimeInterval = 0
        var minOffsetSeen: TimeInterval?
        var trimWindowPops = 0
        var trimWindowMaxDepth = 0
        var trimPending = false
        var counters = JitterBufferStats()
        /// Overflow resync threshold in effect: `config.overflowFrames`,
        /// except right after a `retune` to a smaller limit than the current
        /// depth — then it follows the depth down (the latency trim drains it
        /// smoothly) instead of dropping the excess at once.
        var overflowLimit: Int

        init(config: JitterBufferConfig) {
            self.config = config
            target = config.minTargetFrames
            overflowLimit = config.overflowFrames
        }
    }

    /// Delay estimator, guarded by `estimatorLock` (never taken by `pop`).
    private struct Estimator: Sendable {
        var config: JitterBufferConfig
        var generation = 0
        var histogram: DelayHistogram
        var jitter: TimeInterval = 0
        var lastArrival: TimeInterval?
        var lastMediaTime: TimeInterval?
        var target: Int
        var lowEstimateSince: TimeInterval?
        var lastTargetDecreaseAt: TimeInterval = -.infinity
        /// Arrivals before this time are an outage backlog (not recorded).
        var suppressUntil: TimeInterval = -.infinity

        init(config: JitterBufferConfig) {
            self.config = config
            target = config.minTargetFrames
            histogram = Self.makeHistogram(config)
        }

        static func makeHistogram(_ config: JitterBufferConfig) -> DelayHistogram {
            DelayHistogram(
                window: config.delayWindowSeconds,
                capacity: DelayHistogram.capacity(
                    window: config.delayWindowSeconds, packetsPerSecond: 1 / config.frameDuration))
        }

        mutating func reset(keepTarget: Bool) {
            histogram.reset()
            jitter = 0
            lastArrival = nil
            lastMediaTime = nil
            lowEstimateSince = nil
            suppressUntil = -.infinity
            if !keepTarget {
                target = config.minTargetFrames
                lastTargetDecreaseAt = -.infinity
            }
        }
    }

    private let lock: OSAllocatedUnfairLock<State>
    private let estimatorLock: OSAllocatedUnfairLock<Estimator>
    private let payloads = PayloadStore(
        slots: JitterBuffer.slotCount, slotBytes: JitterBuffer.maxFramePayloadBytes)

    public init(config: JitterBufferConfig = .init()) {
        precondition(config.overflowFrames < Self.slotCount - 16, "overflowFrames exceeds the slot ring")
        lock = OSAllocatedUnfairLock(initialState: State(config: config))
        estimatorLock = OSAllocatedUnfairLock(initialState: Estimator(config: config))
    }

    // MARK: - Insert (network queue)

    /// Buffers a received frame. `arrivalTime` is injected by the caller
    /// (receive timestamp, in seconds) so tests can drive the clock.
    ///
    /// A primary carrying `.discontinuity` resets the buffer first. Frames
    /// whose sequence was already played or skipped are counted as late and
    /// discarded; a repeated primary is counted as a duplicate. A redundant
    /// copy is stored only when its slot is still empty.
    public func insert(_ packet: AudioPacket, arrivalTime: TimeInterval) {
        let mediaTime = Double(packet.sampleTime) / AudioFormat.sampleRate
        let accepted: Int? = lock.withLock { (state: inout State) -> Int? in
            self.store(&state, packet, arrivalTime: arrivalTime, mediaTime: mediaTime)
        }
        // Primaries (on time or late) feed the delay distribution; duplicates,
        // redundant copies and frames of a previous run do not.
        guard let generation = accepted else { return }
        let target: Int = estimatorLock.withLock { (estimator: inout Estimator) -> Int in
            if estimator.generation != generation {
                estimator.generation = generation
                estimator.reset(keepTarget: true)
            }
            Self.observe(&estimator, arrivalTime: arrivalTime, mediaTime: mediaTime)
            return estimator.target
        }
        lock.withLock { (state: inout State) in
            if state.generation == generation {
                state.target = target
            }
        }
    }

    /// Classifies and stores one frame; returns the generation when the
    /// primary's delay should feed the estimator.
    private func store(
        _ state: inout State, _ packet: AudioPacket, arrivalTime: TimeInterval, mediaTime: TimeInterval
    ) -> Int? {
        let sequence = packet.sequence
        let redundant = packet.isRedundant
        if !redundant, packet.flags.contains(.discontinuity) {
            resetPlayout(&state)
            state.floorSequence = sequence
        }
        if redundant {
            state.counters.redundantReceived += 1
        } else {
            state.counters.received += 1
        }
        if let floor = state.floorSequence, sequenceIsAfter(floor, sequence) {
            countLate(&state, redundant: redundant)
            return nil
        }
        if !redundant {
            state.anchorSequence = sequence
            state.anchorMediaTime = mediaTime
            updateCushionEstimate(&state, arrivalTime: arrivalTime)
        }

        let index = Int(sequence & Self.slotMask)
        let kind = SlotKind(rawValue: state.slotKind[index]) ?? .empty
        let span = min(max(packet.frameSlots, 1), Int(UInt8.max))
        if kind != .empty, state.slotSequence[index] == sequence {
            if redundant {
                return nil  // primary (or an earlier copy) already here
            }
            if kind == .redundant {
                // The primary was only late: it supersedes the copy (whose
                // low-rate payload it replaces), which then does not count
                // as a recovery.
                state.slotKind[index] = SlotKind.primary.rawValue
                if packet.payload.count <= Self.maxFramePayloadBytes {
                    writeSlot(&state, index, packet, part: 0, span: span)
                }
                for part in 1..<max(span, 1) {
                    let partIndex = Int((sequence &+ UInt32(part)) & Self.slotMask)
                    if state.slotKind[partIndex] == SlotKind.redundant.rawValue,
                        state.slotSequence[partIndex] == sequence &+ UInt32(part)
                    {
                        state.slotKind[partIndex] = SlotKind.primary.rawValue
                    }
                }
                return state.generation
            }
            state.counters.duplicates += 1
            return nil
        }
        if let expected = state.nextExpected, sequenceIsAfter(expected, sequence) {
            countLate(&state, redundant: redundant)
            // A late primary still feeds the estimator: its delay is real,
            // and exactly what the target failed to cover. A frame whose
            // first slot has passed is dropped whole: its later slots could
            // not be decoded without it.
            return redundant ? nil : state.generation
        }
        guard packet.payload.count <= Self.maxFramePayloadBytes else { return nil }
        for part in 0..<span {
            let slotSequence = sequence &+ UInt32(part)
            let slotIndex = Int(slotSequence & Self.slotMask)
            if part > 0, state.slotKind[slotIndex] != SlotKind.empty.rawValue,
                state.slotSequence[slotIndex] == slotSequence
            {
                continue  // already held (an overlapping frame)
            }
            guard occupy(&state, slotIndex, sequence: slotSequence) else { continue }
            state.slotKind[slotIndex] = (redundant ? SlotKind.redundant : .primary).rawValue
            writeSlot(&state, slotIndex, packet, part: part, span: span)
            state.bufferedCount += 1
            if state.newestSequence.map({ sequenceIsAfter(slotSequence, $0) }) ?? true {
                state.newestSequence = slotSequence
            }
        }

        if state.overflowLimit > state.config.overflowFrames {
            state.overflowLimit = max(
                state.config.overflowFrames, min(state.overflowLimit, state.bufferedCount + Self.retuneOverflowSlack))
        }
        if state.bufferedCount > state.overflowLimit {
            dropOldest(&state, keeping: state.target)
        }
        return redundant ? nil : state.generation
    }

    /// Frees `index` for `sequence`: false when it holds a newer frame (ring
    /// collision with a frame 512 slots away: keep the newer one).
    private func occupy(_ state: inout State, _ index: Int, sequence: UInt32) -> Bool {
        guard state.slotKind[index] != SlotKind.empty.rawValue else { return true }
        state.counters.overflowDropped += 1
        guard sequenceIsAfter(sequence, state.slotSequence[index]) else { return false }
        removeSlot(&state, index)
        return true
    }

    /// Fills slot `index` with part `part` of `packet` (the payload goes to
    /// part 0 only); the slot kind is set by the caller.
    private func writeSlot(_ state: inout State, _ index: Int, _ packet: AudioPacket, part: Int, span: Int) {
        state.slotSequence[index] = packet.sequence &+ UInt32(part)
        state.slotSampleTime[index] = packet.sampleTime &+ UInt64(part * AudioFormat.samplesPerFrame)
        state.slotCodec[index] = packet.codec.rawValue
        state.slotFlags[index] = part == 0 ? packet.flags.rawValue : 0
        state.slotSpan[index] = UInt8(span)
        state.slotPart[index] = UInt8(part)
        state.slotLowRate[index] = packet.isRedundant && packet.isLowRateCopy
        guard part == 0 else {
            state.slotLength[index] = 0
            return
        }
        state.slotLength[index] = packet.payload.count
        let destination = payloads.slot(index)
        packet.payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            if let source = raw.baseAddress, raw.count > 0 {
                destination.copyMemory(from: source, byteCount: raw.count)
            }
        }
    }

    private func countLate(_ state: inout State, redundant: Bool) {
        if redundant {
            state.counters.redundantLate += 1
        } else {
            state.counters.late += 1
        }
    }

    // MARK: - Pop (render thread)

    /// Returns the next playout slot and copies the frame's payload into
    /// `payload` (at least `maxFramePayloadBytes`). When the latency trim
    /// skips a frame, the skipped frame's payload goes into `skippedPayload`
    /// so the caller can crossfade it away. Must be called exactly once per
    /// `frameDuration` by the playout clock. Realtime-safe: no allocation,
    /// one short lock.
    public func pop(
        payload: UnsafeMutableRawBufferPointer,
        skippedPayload: UnsafeMutableRawBufferPointer
    ) -> PlayoutSlot {
        // Unchecked: the closure captures the caller's buffers, which are
        // only used synchronously inside the lock.
        lock.withLockUnchecked { (state: inout State) -> PlayoutSlot in
            self.popLocked(&state, payload: payload, skippedPayload: skippedPayload)
        }
    }

    /// Allocating convenience form of `pop(payload:skippedPayload:)` (tests,
    /// tools): the frame comes back as an `AudioPacket`.
    public func pop() -> JitterBufferOutput {
        let payload = UnsafeMutableRawBufferPointer.allocate(
            byteCount: Self.maxFramePayloadBytes, alignment: 16)
        let skipped = UnsafeMutableRawBufferPointer.allocate(
            byteCount: Self.maxFramePayloadBytes, alignment: 16)
        defer {
            payload.deallocate()
            skipped.deallocate()
        }
        switch pop(payload: payload, skippedPayload: skipped) {
        case .frame(let frame):
            return .packet(
                AudioPacket(
                    codec: frame.codec,
                    flags: AudioPacketFlags(rawValue: frame.flags.rawValue),
                    sequence: frame.sequence,
                    sampleTime: frame.sampleTime,
                    payload: Data(bytes: payload.baseAddress!, count: frame.byteCount),
                    frameSlots: frame.frameSlots))
        case .lost(let sequence):
            return .lost(sequence: sequence)
        case .underrun:
            return .underrun
        case .buffering:
            return .buffering
        }
    }

    private func popLocked(
        _ state: inout State,
        payload: UnsafeMutableRawBufferPointer,
        skippedPayload: UnsafeMutableRawBufferPointer
    ) -> PlayoutSlot {
        if state.phase == .buffering {
            let deepEnough = state.bufferedCount >= state.target
            let cushioned = state.bufferedCount > 0
                && state.cushionEstimate >= requiredCushion(forTarget: state.target, state.config)
            guard deepEnough || cushioned else {
                if state.hasPlayedOnce {
                    state.counters.bufferingPops += 1
                }
                return .buffering
            }
            state.phase = .playing
            state.hasPlayedOnce = true
            state.consecutiveEmptyPops = 0
            state.inUnderrun = false
            state.waiting = false
            state.growFrames = 0
            resetTrimWindow(&state)
            // Playback (re)starts from the lowest buffered sequence.
            state.nextExpected = lowestSequence(state)
        }

        guard var expected = state.nextExpected else { return .buffering }
        var skippedBytes = 0
        var skippedCodec = AudioCodec.pcm16
        var hasSkipped = false
        var skippedSpan = 1
        var skippedPart = 0
        if shouldTrim(&state, expected: expected) {
            // Skip the oldest frame (its successor is buffered too) and hand
            // it to the reader for the crossfade.
            let index = Int(expected & Self.slotMask)
            skippedBytes = copyOut(state, index, into: skippedPayload)
            skippedCodec = AudioCodec(rawValue: state.slotCodec[index]) ?? .pcm16
            hasSkipped = true
            skippedSpan = Int(state.slotSpan[index])
            skippedPart = Int(state.slotPart[index])
            removeSlot(&state, index)
            state.counters.trimmed += 1
            expected = expected &+ 1
            state.nextExpected = expected
        }

        let index = Int(expected & Self.slotMask)
        if state.slotKind[index] != SlotKind.empty.rawValue, state.slotSequence[index] == expected {
            if state.waiting, state.bufferedCount < state.target, state.growFrames < state.target {
                // Playout is concealing anyway: finish growing the cushion to
                // the target now, inside this one dropout, instead of
                // leaving it short (the next burst of the same length would
                // underrun again) or opening a second gap later.
                state.growFrames += 1
                state.counters.waitFrames += 1
                return .underrun
            }
            state.waiting = false
            state.growFrames = 0
            let recovered = state.slotKind[index] == SlotKind.redundant.rawValue
            let lowRate = recovered && state.slotLowRate[index]
            let frame = PlayoutFrame(
                sequence: expected,
                sampleTime: state.slotSampleTime[index],
                codec: AudioCodec(rawValue: state.slotCodec[index]) ?? .pcm16,
                flags: AudioPacketFlags(rawValue: state.slotFlags[index]),
                byteCount: copyOut(state, index, into: payload),
                skippedByteCount: skippedBytes,
                recovered: recovered,
                skippedCodec: skippedCodec,
                frameSlots: Int(state.slotSpan[index]),
                part: Int(state.slotPart[index]),
                hasSkipped: hasSkipped,
                skippedFrameSlots: skippedSpan,
                skippedPart: skippedPart,
                lowRateCopy: lowRate)
            removeSlot(&state, index)
            state.consecutiveEmptyPops = 0
            state.inUnderrun = false
            state.counters.played += 1
            if recovered {
                state.counters.recovered += 1
            }
            if lowRate {
                state.counters.lowRateRecovered += 1
            }
            state.nextExpected = expected &+ 1
            return .frame(frame)
        }

        let beyondHorizon = state.config.lossHorizonFrames.map { horizon in
            state.newestSequence.map { sequenceIsAfter($0, expected &+ UInt32(horizon - 1)) } ?? false
        } ?? false
        if state.bufferedCount > 0, state.bufferedCount >= state.target || beyondHorizon {
            // Missing while the buffer is at its target depth, or while much
            // newer frames (and so its redundant copy) have already arrived:
            // lost for good.
            state.waiting = false
            state.growFrames = 0
            state.counters.lost += 1
            state.consecutiveEmptyPops = 0
            state.inUnderrun = false
            state.nextExpected = expected &+ 1
            return .lost(sequence: expected)
        }

        // Nothing playable: wait one frame (the caller conceals). The frame
        // keeps its slot, so a late arrival still plays.
        state.waiting = true
        if state.bufferedCount == 0 {
            if !state.inUnderrun {
                state.inUnderrun = true
                state.counters.underruns += 1
            }
            state.counters.underrunFrames += 1
            state.consecutiveEmptyPops += 1
            if state.consecutiveEmptyPops >= state.config.maxTargetFrames {
                // A sustained stall (the sender stopped, or an outage): back
                // to prebuffering.
                state.phase = .buffering
                state.counters.rebuffers += 1
                state.consecutiveEmptyPops = 0
                state.inUnderrun = false
                resetTrimWindow(&state)
            }
        } else {
            state.counters.waitFrames += 1
            state.consecutiveEmptyPops = 0
        }
        return .underrun
    }

    // MARK: - Control

    /// Clears buffered audio and returns to prebuffering, e.g. before a fresh
    /// engine run. Session counters and the adaptive target are kept; the
    /// delay history restarts.
    public func reset() {
        lock.withLock { (state: inout State) in
            self.resetPlayout(&state)
        }
    }

    /// Swaps the configuration (e.g. a latency-mode change) and resets the
    /// buffered audio so the new target range takes effect immediately;
    /// session counters are kept, the adaptive target restarts at the new
    /// minimum.
    public func applyConfig(_ newConfig: JitterBufferConfig) {
        precondition(newConfig.overflowFrames < Self.slotCount - 16, "overflowFrames exceeds the slot ring")
        estimatorLock.withLock { (estimator: inout Estimator) in
            estimator.config = newConfig
            estimator.histogram = Estimator.makeHistogram(newConfig)
            estimator.reset(keepTarget: false)
        }
        lock.withLock { (state: inout State) in
            state.config = newConfig
            state.overflowLimit = newConfig.overflowFrames
            state.target = newConfig.minTargetFrames
            self.resetPlayout(&state)
        }
    }

    /// Headroom above the current depth kept by a retune that lowers the
    /// overflow limit (40 ms).
    private static let retuneOverflowSlack = AudioFormat.frames(milliseconds: 40)

    /// Swaps the configuration in place — no reset, no gap: the buffered
    /// frames keep playing and the adaptive target is clamped into the new
    /// range. A higher floor takes effect at the next stall (the cushion
    /// grows inside that one concealment, as for any target rise); a lower
    /// ceiling is reached by the latency trim's crossfaded skips, never by
    /// dropping buffered audio at once. Used for the LAN ↔ WAN profile
    /// switch (`StreamProfile.jitterConfig`).
    public func retune(_ newConfig: JitterBufferConfig) {
        precondition(newConfig.overflowFrames < Self.slotCount - 16, "overflowFrames exceeds the slot ring")
        let target: Int = estimatorLock.withLock { (estimator: inout Estimator) -> Int in
            let windowChanged = estimator.config.delayWindowSeconds != newConfig.delayWindowSeconds
                || estimator.config.frameDuration != newConfig.frameDuration
            estimator.config = newConfig
            if windowChanged {
                estimator.histogram = Estimator.makeHistogram(newConfig)
            }
            estimator.target = min(max(estimator.target, newConfig.minTargetFrames), newConfig.maxTargetFrames)
            estimator.lowEstimateSince = nil
            return estimator.target
        }
        lock.withLock { (state: inout State) in
            let previousLimit = state.overflowLimit
            state.config = newConfig
            state.overflowLimit = max(
                newConfig.overflowFrames,
                min(previousLimit, state.bufferedCount + Self.retuneOverflowSlack))
            state.target = target
        }
    }

    /// Frames buffered and the adaptive target, read under the playout lock
    /// only (no estimator work, no allocation): cheap enough for the render
    /// thread, where the mic reader's drift correction reads it once per
    /// frame.
    public func playoutDepth() -> (depth: Int, target: Int) {
        lock.withLock { ($0.bufferedCount, $0.target) }
    }

    /// The configuration in effect.
    public var config: JitterBufferConfig {
        lock.withLock { $0.config }
    }

    /// Current session statistics and buffer state.
    public var stats: JitterBufferStats {
        var stats = lock.withLock { (state: inout State) -> JitterBufferStats in
            var stats = state.counters
            stats.depthFrames = state.bufferedCount
            stats.targetFrames = state.target
            return stats
        }
        let (jitter, percentiles) = estimatorLock.withLock {
            (estimator: inout Estimator) -> (TimeInterval, DelayPercentiles?) in
            (estimator.jitter, estimator.histogram.percentiles(now: estimator.lastArrival ?? 0))
        }
        stats.jitterSeconds = jitter
        if let percentiles {
            stats.delayP50Seconds = percentiles.p50
            stats.delayP95Seconds = percentiles.p95
            stats.delayP99Seconds = percentiles.p99
            stats.delayMaxSeconds = percentiles.max
        }
        return stats
    }

    // MARK: - Estimator (estimatorLock held)

    /// Feeds one accepted primary into the jitter estimate and the delay
    /// histogram and recomputes the target: rises immediately, falls one
    /// frame per `targetFallStepSeconds` after `targetFallHoldSeconds` low.
    private static func observe(
        _ estimator: inout Estimator, arrivalTime: TimeInterval, mediaTime: TimeInterval
    ) {
        let config = estimator.config
        if let lastArrival = estimator.lastArrival,
            arrivalTime - lastArrival > config.outageThresholdSeconds
        {
            // Outage: restart the delay history and skip the backlog.
            estimator.histogram.reset()
            estimator.lowEstimateSince = nil
            estimator.suppressUntil = arrivalTime + config.outageSettleSeconds
        } else if let lastArrival = estimator.lastArrival, let lastMediaTime = estimator.lastMediaTime {
            // RFC 3550 section 6.4.1 interarrival jitter (1/16 smoothing).
            let deviation = abs((arrivalTime - lastArrival) - (mediaTime - lastMediaTime))
            estimator.jitter += (deviation - estimator.jitter) / 16
        }
        estimator.lastArrival = arrivalTime
        estimator.lastMediaTime = mediaTime
        guard arrivalTime >= estimator.suppressUntil else { return }
        estimator.histogram.record(arrivalTime: arrivalTime, mediaTime: mediaTime)

        let computed: Int
        switch config.targetEstimator {
        case .rfc3550:
            let scaled = config.jitterMultiplier * estimator.jitter / config.frameDuration
            computed = Int(ceil(scaled)) + 1
        case .delayPercentile:
            guard let delay = estimator.histogram.quantile(config.delayQuantile, now: arrivalTime)
            else { return }
            // The epsilon keeps ceil() honest at exact frame boundaries.
            computed = Int(ceil((delay + config.safetyMargin) / config.frameDuration - 1e-9))
        }
        let clamped = min(max(computed, config.minTargetFrames), config.maxTargetFrames)

        if clamped > estimator.target {
            estimator.target = clamped
            estimator.lowEstimateSince = nil
            return
        }
        guard clamped < estimator.target else {
            estimator.lowEstimateSince = nil
            return
        }
        if estimator.lowEstimateSince == nil {
            estimator.lowEstimateSince = arrivalTime
        }
        let hold = config.targetEstimator == .delayPercentile ? config.targetFallHoldSeconds : 0
        if arrivalTime - estimator.lowEstimateSince! >= hold,
            arrivalTime - estimator.lastTargetDecreaseAt >= config.targetFallStepSeconds
        {
            estimator.target = max(clamped, estimator.target - 1)
            estimator.lastTargetDecreaseAt = arrivalTime
        }
    }

    // MARK: - Playout internals (lock held)

    /// Latency trim decision for this pop: tracks the peak depth over the
    /// trim window and, once a window ends with the peak above
    /// `target + slack`, arms a trim that fires on the first pop where the
    /// expected frame and its successor are both buffered. The peak — not
    /// the instantaneous depth — is compared because bursty delivery makes
    /// the depth swing below the target between bursts.
    private func shouldTrim(_ state: inout State, expected: UInt32) -> Bool {
        guard let slack = state.config.latencyTrimSlackFrames else { return false }
        state.trimWindowMaxDepth = max(state.trimWindowMaxDepth, state.bufferedCount)
        state.trimWindowPops += 1
        if TimeInterval(state.trimWindowPops) * state.config.frameDuration
            >= state.config.latencyTrimWindowSeconds - 1e-9
        {
            if state.trimWindowMaxDepth > state.target + slack {
                state.trimPending = true
            }
            state.trimWindowPops = 0
            state.trimWindowMaxDepth = 0
        }
        guard state.trimPending,
            state.bufferedCount > state.target,
            holds(state, expected),
            holds(state, expected &+ 1)
        else { return false }
        state.trimPending = false
        return true
    }

    private func holds(_ state: State, _ sequence: UInt32) -> Bool {
        let index = Int(sequence & Self.slotMask)
        return state.slotKind[index] != SlotKind.empty.rawValue && state.slotSequence[index] == sequence
    }

    private func copyOut(_ state: State, _ index: Int, into buffer: UnsafeMutableRawBufferPointer) -> Int {
        let count = min(state.slotLength[index], buffer.count)
        if count > 0, let base = buffer.baseAddress {
            base.copyMemory(from: payloads.slot(index), byteCount: count)
        }
        return count
    }

    private func removeSlot(_ state: inout State, _ index: Int) {
        guard state.slotKind[index] != SlotKind.empty.rawValue else { return }
        state.slotKind[index] = SlotKind.empty.rawValue
        state.bufferedCount -= 1
    }

    /// Drops the oldest frames until `keeping` remain (overflow resync).
    private func dropOldest(_ state: inout State, keeping: Int) {
        guard var sequence = lowestSequence(state) else { return }
        var steps = 0
        while state.bufferedCount > keeping, steps < Self.slotCount {
            let index = Int(sequence & Self.slotMask)
            if holds(state, sequence) {
                removeSlot(&state, index)
                state.counters.overflowDropped += 1
            }
            sequence = sequence &+ 1
            steps += 1
        }
        if let expected = state.nextExpected, sequenceIsAfter(sequence, expected) {
            state.nextExpected = sequence
        }
    }

    private func resetTrimWindow(_ state: inout State) {
        state.trimWindowPops = 0
        state.trimWindowMaxDepth = 0
        state.trimPending = false
    }

    /// Cushion a buffering exit needs for `target`: with `target - 1` frames
    /// of spacing plus the newest packet's network delay, no on-time packet
    /// can arrive after its playout slot.
    private func requiredCushion(forTarget target: Int, _ config: JitterBufferConfig) -> TimeInterval {
        TimeInterval(max(target - 1, 0)) * config.frameDuration
    }

    /// Refreshes the cushion estimate after a primary insert, anchored at the
    /// running minimum of `arrival - mediaTime` (the fastest path observed
    /// since the reset). While playing the reference is the next expected
    /// sequence; while buffering, the sequence playback will restart from.
    private func updateCushionEstimate(_ state: inout State, arrivalTime: TimeInterval) {
        guard let anchorSequence = state.anchorSequence else { return }
        let currentOffset = arrivalTime - state.anchorMediaTime
        if state.minOffsetSeen == nil || currentOffset < state.minOffsetSeen! {
            state.minOffsetSeen = currentOffset
        }
        let reference = state.phase == .playing ? state.nextExpected : lowestSequence(state)
        guard let reference else { return }
        let offset = Int64(Int32(bitPattern: reference &- anchorSequence))
        let referenceMediaTime = state.anchorMediaTime + TimeInterval(offset) * state.config.frameDuration
        state.cushionEstimate = arrivalTime - referenceMediaTime - (state.minOffsetSeen ?? currentOffset)
    }

    /// Lowest buffered sequence, wrap-around aware. Linear scan of the slot
    /// ring (512 entries, no allocation).
    private func lowestSequence(_ state: State) -> UInt32? {
        var lowest: UInt32?
        for index in 0..<Self.slotCount where state.slotKind[index] != SlotKind.empty.rawValue {
            let sequence = state.slotSequence[index]
            if let current = lowest {
                if sequenceIsAfter(current, sequence) { lowest = sequence }
            } else {
                lowest = sequence
            }
        }
        return lowest
    }

    private func resetPlayout(_ state: inout State) {
        for index in 0..<Self.slotCount {
            state.slotKind[index] = SlotKind.empty.rawValue
        }
        state.bufferedCount = 0
        state.newestSequence = nil
        state.generation += 1
        state.nextExpected = nil
        state.floorSequence = nil
        state.phase = .buffering
        state.inUnderrun = false
        state.waiting = false
        state.growFrames = 0
        state.consecutiveEmptyPops = 0
        state.anchorSequence = nil
        state.anchorMediaTime = 0
        state.cushionEstimate = 0
        state.minOffsetSeen = nil
        resetTrimWindow(&state)
    }
}

/// Preallocated payload memory for the jitter buffer's slot ring. Accessed
/// only under the jitter buffer's playout lock.
private final class PayloadStore: @unchecked Sendable {
    private let base: UnsafeMutableRawPointer
    private let slotBytes: Int

    init(slots: Int, slotBytes: Int) {
        self.slotBytes = slotBytes
        base = UnsafeMutableRawPointer.allocate(byteCount: slots * slotBytes, alignment: 16)
        base.initializeMemory(as: UInt8.self, repeating: 0, count: slots * slotBytes)
    }

    deinit {
        base.deallocate()
    }

    func slot(_ index: Int) -> UnsafeMutableRawPointer {
        base + index * slotBytes
    }
}
