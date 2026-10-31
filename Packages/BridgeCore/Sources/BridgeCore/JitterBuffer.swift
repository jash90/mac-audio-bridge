import Foundation
import os

/// Named latency modes for the jitter buffer: the trade-off between
/// end-to-end latency and tolerance to delay variation on the network path.
public enum JitterLatencyMode: String, CaseIterable, Sendable {
    /// 30–120 ms cushion: streaming over a clean LAN/Wi-Fi link.
    case low
    /// 50–250 ms cushion: the default; survives typical iPhone Wi-Fi
    /// power-save burst delivery (gaps of 50–150 ms and more).
    case balanced
    /// 100–400 ms cushion: congested links, long burst gaps, or downstream
    /// chains (e.g. Bluetooth headphones) that buffer on their own.
    case safe
}

/// Tuning parameters for the adaptive jitter buffer.
public struct JitterBufferConfig: Sendable {
    /// How the adaptive target depth is derived from the network observations.
    public enum TargetEstimator: Sendable, Equatable {
        /// RFC 3550 interarrival jitter × `jitterMultiplier` (the pre-M2.6
        /// rule). Retained for comparison; the smoothed mean deviation
        /// underestimates bursty delay.
        case rfc3550
        /// p99 of the windowed relative-delay distribution + `safetyMargin`
        /// (the default): the target covers the actual delay tail, which is
        /// what Wi-Fi power-save bursts stress.
        case delayPercentile
    }

    /// Nominal duration of one audio frame (10 ms at 48 kHz).
    public var frameDuration: TimeInterval = 0.010
    /// Lower clamp for the adaptive target depth (40 ms).
    public var minTargetFrames = 4
    /// Upper clamp for the adaptive target depth (80 ms).
    public var maxTargetFrames = 8
    /// Target multiplier for the `.rfc3550` estimator:
    /// ceil(multiplier * jitter / frameDuration) + 1, clamped.
    public var jitterMultiplier = 3.0
    /// Depth above this resyncs the buffer by dropping the oldest frames
    /// down to the target. An interim drift guard: until the receiver
    /// resamples playout to the output audio clock (separate task), the two
    /// clocks drift apart and the depth slowly ramps in one direction.
    public var overflowFrames = 16
    /// How the adaptive target is derived; see `TargetEstimator`.
    public var targetEstimator: TargetEstimator = .delayPercentile
    /// Headroom added to the delay p99 before converting it to frames
    /// (`.delayPercentile` estimator): it bridges the p99-to-max tail, so a
    /// burst does not have to be seen twice before the target covers it.
    public var safetyMargin: TimeInterval = 0.010
    /// Sliding window of the delay histogram behind `.delayPercentile`.
    public var delayWindowSeconds: TimeInterval = 10.0
    /// The target may only fall once the p99-based estimate has stayed below
    /// the current target for this many seconds of playout
    /// (`.delayPercentile` estimator).
    public var targetFallHoldSeconds: TimeInterval = 5.0
    /// Latency trim: when the peak depth over a `latencyTrimWindowSeconds`
    /// window of playout exceeds `target + latencyTrimSlackFrames`, one frame
    /// is skipped so the real buffering delay follows a falling target.
    /// Without it, a target that decays after a transient leaves the depth —
    /// the actual latency — where the transient put it (arrivals and pops
    /// both run at 100/s, so nothing drains the surplus). Nil disables it.
    public var latencyTrimSlackFrames: Int? = 2
    /// Playout time per trim decision: at most one frame (10 ms) is skipped
    /// per window.
    public var latencyTrimWindowSeconds: TimeInterval = 1.0

    public init() {}

    /// Preset for a latency mode: clamps and overflow resync tuned per mode
    /// (`overflowFrames = maxTargetFrames + 6`).
    public static func latency(_ mode: JitterLatencyMode) -> JitterBufferConfig {
        var config = JitterBufferConfig()
        switch mode {
        case .low:
            config.minTargetFrames = 3
            config.maxTargetFrames = 12
        case .balanced:
            config.minTargetFrames = 5
            config.maxTargetFrames = 25
        case .safe:
            config.minTargetFrames = 10
            config.maxTargetFrames = 40
        }
        config.overflowFrames = config.maxTargetFrames + 6
        return config
    }
}

/// One playout slot of output from the jitter buffer.
public enum JitterBufferOutput: Sendable, Equatable {
    /// The next frame, in order.
    case packet(AudioPacket)
    /// The expected frame is missing; the caller conceals it (PLC or silence).
    case lost(sequence: UInt32)
    /// Prebuffering (at start, or after a reset); the caller outputs silence.
    case buffering
}

/// Session counters and the current buffer state, for diagnostics.
public struct JitterBufferStats: Sendable, Equatable {
    /// Packets handed to `insert` (including duplicates and late ones).
    public var received = 0
    /// Playout slots that returned a packet.
    public var played = 0
    /// Frames reported missing at playout time.
    public var lost = 0
    /// Packets discarded because their playout slot had already passed.
    public var late = 0
    /// Repeated sequence numbers discarded.
    public var duplicates = 0
    /// Oldest frames dropped to recover from depth overflow.
    public var overflowDropped = 0
    /// Frames skipped by the latency trim (depth above target + slack).
    public var trimmed = 0
    /// Playout slots that found the buffer completely empty.
    public var underruns = 0
    /// Transitions from playing back to buffering: cushion rebuilds after a
    /// target rise, plus returns to prebuffering after a sustained underrun.
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

/// Payload-agnostic adaptive jitter buffer for `AudioPacket`s. Decoding and
/// packet-loss concealment happen in the caller; this type only reorders,
/// times and accounts for frames.
///
/// Threading: `insert` is called from the network queue, `pop()` from the
/// audio thread; all state lives behind a single short unfair lock. `pop()`
/// does not allocate beyond handing back the buffered packet.
///
/// Adaptivity: the target depth follows the delay distribution. With the
/// default `.delayPercentile` estimator the target is
/// `ceil((p99 + safetyMargin) / frameDuration)`, clamped to
/// `[minTargetFrames, maxTargetFrames]`, where p99 comes from a
/// `DelayHistogram` over a sliding window — an RFC 3550 mean-deviation
/// estimate underestimates bursty delay (Wi-Fi power save delivers UDP in
/// 100 ms+ batches), while p99 tracks the actual tail. The target rises
/// immediately and falls slowly: at most one frame per two seconds of
/// playout, and only after the p99-based estimate has stayed below the
/// current target for `targetFallHoldSeconds`. The RFC 3550 jitter estimate
/// is still computed and reported as a stat (and drives the target with
/// `targetEstimator = .rfc3550`).
///
/// Cushion: the buffer tracks how far playout lags the newest arrival (the
/// cushion), measured against the running minimum of
/// `arrival - mediaTime` — the fastest path observed since the reset
/// (anchoring at the first packet after a reset is wrong: that packet may
/// itself have arrived late, e.g. at the tail of a burst). The sender's
/// media clock and the receiver's arrival clock have unrelated epochs, so
/// only the cushion's growth over that anchor is meaningful. When a risen
/// target demands more cushion than the current playing run started with,
/// the buffer returns to `.buffering` and rebuilds it; the rebuild ends as
/// soon as the cushion reaches `(target - 1) * frameDuration`, so the
/// audible gap stays short. Rising through several target steps (a
/// staircase) is debounced into a single rebuild, so one jitter step costs
/// at most a rebuild or two rather than one per step.
///
/// Latency trim: the target only says how deep the buffer should be; the
/// depth itself does not shrink when the target falls, because arrivals and
/// pops both run at the frame rate. A transient that built a 200 ms cushion
/// would otherwise keep 200 ms of latency long after the target decayed.
/// So when the peak depth over a one-second playout window stays above
/// `target + latencyTrimSlackFrames`, one frame is skipped (at most one per
/// window, i.e. ≤ 10 ms of shortening per second; the reader smooths the
/// splice).
public final class JitterBuffer: @unchecked Sendable {
    /// All mutable state, guarded by `lock`.
    private struct State: Sendable {
        enum Phase {
            case buffering
            case playing
        }

        var phase: Phase = .buffering
        var buffered: [UInt32: AudioPacket] = [:]
        /// Next sequence to hand out. Nil until the first buffering exit;
        /// kept across rebuffering so stragglers are still classified as late.
        var nextExpected: UInt32?
        /// True once playback has started at least once; gates the
        /// `bufferingPops` counter (initial prebuffering is not a gap).
        var hasPlayedOnce = false
        /// Target the current playing run left buffering with; 0 while
        /// prebuffering or after a reset.
        var exitTarget = 0
        /// Adaptive target depth, clamped to the configured range.
        var target: Int
        var consecutiveEmptyPops = 0
        /// Playout time consumed by non-buffering pops; the clock for the
        /// rate-limited target decrease.
        var playoutSeconds: TimeInterval = 0
        var lastTargetDecreaseAt: TimeInterval = 0
        /// RFC 3550 interarrival jitter estimate, in seconds.
        var jitter: TimeInterval = 0
        var lastArrival: TimeInterval?
        var lastMediaTime: TimeInterval?
        /// Media-clock anchor of the newest inserted packet, used to
        /// extrapolate the media time of any sequence number.
        var anchorSequence: UInt32?
        var anchorMediaTime: TimeInterval = 0
        /// Arrival time of the newest insert minus the media time of the
        /// playback reference (the expected sequence while playing, the
        /// lowest buffered sequence while rebuffering), relative to the
        /// fastest observed path since the reset: the cushion.
        var cushionEstimate: TimeInterval = 0
        /// Running minimum of `arrival - mediaTime` over accepted inserts
        /// since the reset — the fastest network path. Anchors the cushion so
        /// its growth measures real buffering, not the arbitrary delay of
        /// whichever packet happened to arrive first.
        var minOffsetSeen: TimeInterval?
        /// Relative-delay distribution over the sliding window; drives the
        /// `.delayPercentile` target estimator.
        var histogram = DelayHistogram()
        /// Playout time at which the p99-based estimate first dropped below
        /// the current target; nil while the estimate covers the target.
        var lowEstimateSince: TimeInterval?
        /// Insert counter, and the count at which a pending cushion rebuild
        /// first became due; the rebuild is debounced by insert count so a
        /// rising staircase of targets collapses into one rebuild.
        var insertCount = 0
        var pendingRiseInsert: Int?
        /// Latency-trim window: pops counted and peak depth seen in it, and
        /// whether a trim is due (it waits for two consecutive frames to be
        /// buffered so the skip never turns into a loss).
        var trimWindowPops = 0
        var trimWindowMaxDepth = 0
        var trimPending = false
        var counters = JitterBufferStats()

        init(config: JitterBufferConfig) {
            target = config.minTargetFrames
            histogram = DelayHistogram(window: config.delayWindowSeconds)
        }
    }

    private var config: JitterBufferConfig
    private let lock: OSAllocatedUnfairLock<State>
    /// A target rise must persist this many inserts (~350 ms at stream rate)
    /// before the cushion rebuild fires.
    private let rebuildDebounceInserts = 35

    public init(config: JitterBufferConfig = .init()) {
        self.config = config
        lock = OSAllocatedUnfairLock(initialState: State(config: config))
    }

    /// Buffers a received packet. `arrivalTime` is injected by the caller
    /// (receive timestamp, in seconds) so tests can drive the clock.
    ///
    /// A packet carrying `.discontinuity` resets the buffer first. Packets
    /// whose sequence was already played or skipped are counted as late and
    /// discarded; repeated sequences are counted as duplicates and discarded.
    public func insert(_ packet: AudioPacket, arrivalTime: TimeInterval) {
        lock.withLock { (state: inout State) in
            if packet.flags.contains(.discontinuity) {
                self.resetBuffer(&state)
            }
            state.counters.received += 1
            state.insertCount += 1

            let mediaTime = Double(packet.sampleTime) / AudioFormat.sampleRate
            self.updateJitter(&state, arrivalTime: arrivalTime, mediaTime: mediaTime)

            state.anchorSequence = packet.sequence
            state.anchorMediaTime = mediaTime
            self.updateCushionEstimate(&state, arrivalTime: arrivalTime)

            let sequence = packet.sequence
            if state.buffered[sequence] != nil {
                state.counters.duplicates += 1
                return
            }
            if let expected = state.nextExpected, sequenceIsAfter(expected, sequence) {
                state.counters.late += 1
                return
            }
            // Only accepted packets feed the delay distribution: duplicates
            // and late packets carry inflated delays that would bias the
            // percentile target upwards and keep it there.
            state.histogram.record(arrivalTime: arrivalTime, mediaTime: mediaTime)
            self.updateTarget(&state, arrivalTime: arrivalTime)

            state.buffered[sequence] = packet

            if state.buffered.count > config.overflowFrames {
                let excess = state.buffered.count - state.target
                let oldest = state.buffered.keys.sorted { sequenceIsAfter($1, $0) }
                for dropSequence in oldest.prefix(excess) {
                    state.buffered.removeValue(forKey: dropSequence)
                }
                state.counters.overflowDropped += excess
            }

            if state.phase == .playing, state.target > state.exitTarget {
                if state.cushionEstimate >= self.requiredCushion(forTarget: state.target) {
                    // The current cushion already satisfies the risen target.
                    state.exitTarget = state.target
                    state.pendingRiseInsert = nil
                } else {
                    if state.pendingRiseInsert == nil {
                        state.pendingRiseInsert = state.insertCount
                    }
                    if state.insertCount - state.pendingRiseInsert! >= rebuildDebounceInserts {
                        // The risen target demands a deeper cushion than this
                        // playing run started with: pause playback and rebuild.
                        state.phase = .buffering
                        state.counters.rebuffers += 1
                        state.exitTarget = 0
                        state.pendingRiseInsert = nil
                        state.consecutiveEmptyPops = 0
                        self.resetTrimWindow(&state)
                    }
                }
            } else {
                state.pendingRiseInsert = nil
            }
        }
    }

    /// Returns the next playout slot: the next buffered frame in order, a
    /// loss to conceal, or `.buffering` while prebuffering. Must be called
    /// exactly once per `frameDuration` by the playout clock.
    public func pop() -> JitterBufferOutput {
        lock.withLock { (state: inout State) in
            // Leave buffering once the depth reaches the target or the
            // cushion is already deep enough; playback then (re)starts from
            // the lowest buffered sequence.
            if state.phase == .buffering {
                let deepEnough = state.buffered.count >= state.target
                let cushioned = !state.buffered.isEmpty
                    && state.cushionEstimate >= self.requiredCushion(forTarget: state.target)
                guard deepEnough || cushioned else {
                    if state.hasPlayedOnce {
                        state.counters.bufferingPops += 1
                    }
                    return .buffering
                }
                state.phase = .playing
                state.hasPlayedOnce = true
                state.exitTarget = state.target
                state.consecutiveEmptyPops = 0
                self.resetTrimWindow(&state)
                // Playback (re)starts from the lowest buffered sequence;
                // while rebuffering the head is kept, and nothing below it
                // can be buffered, so this only moves it up over a gap.
                state.nextExpected = self.lowestSequence(state.buffered)
            }

            guard var expected = state.nextExpected else { return .buffering }
            state.playoutSeconds += config.frameDuration
            if self.shouldTrim(&state, expected: expected) {
                // Skip the oldest frame: the next one is buffered too, so the
                // stream stays contiguous apart from this 10 ms.
                state.buffered.removeValue(forKey: expected)
                state.counters.trimmed += 1
                expected = expected &+ 1
                state.nextExpected = expected
            }

            if let packet = state.buffered.removeValue(forKey: expected) {
                state.consecutiveEmptyPops = 0
                state.counters.played += 1
                state.nextExpected = expected &+ 1
                return .packet(packet)
            }
            if !state.buffered.isEmpty {
                // Expected frame missing, later frames present: report the
                // loss and advance.
                state.counters.lost += 1
                state.consecutiveEmptyPops = 0
                state.nextExpected = expected &+ 1
                return .lost(sequence: expected)
            }

            // Completely empty while playing: underrun. Report the expected
            // frame as lost and keep timing. A sustained stall returns the
            // buffer to prebuffering.
            state.counters.underruns += 1
            state.counters.lost += 1
            state.nextExpected = expected &+ 1
            state.consecutiveEmptyPops += 1
            if state.consecutiveEmptyPops >= config.maxTargetFrames {
                state.phase = .buffering
                state.counters.rebuffers += 1
                state.consecutiveEmptyPops = 0
                state.pendingRiseInsert = nil
                self.resetTrimWindow(&state)
            }
            return .lost(sequence: expected)
        }
    }

    /// Clears buffered audio and returns to prebuffering, e.g. on a stream
    /// discontinuity or reconnect. Session counters are kept; the jitter
    /// estimator and the delay histogram restart because inter-arrival
    /// history across a reset is meaningless.
    public func reset() {
        lock.withLock { (state: inout State) in
            self.resetBuffer(&state)
        }
    }

    /// Swaps the configuration (e.g. a latency-mode change) and resets the
    /// buffered audio so the new target range takes effect immediately;
    /// session counters are kept, the adaptive target restarts at the new
    /// minimum.
    public func applyConfig(_ newConfig: JitterBufferConfig) {
        lock.withLock { (state: inout State) in
            self.config = newConfig
            state.target = newConfig.minTargetFrames
            state.lastTargetDecreaseAt = 0
            self.resetBuffer(&state)
        }
    }

    /// Current session statistics and buffer state.
    public var stats: JitterBufferStats {
        lock.withLock { (state: inout State) in
            var stats = state.counters
            stats.depthFrames = state.buffered.count
            stats.targetFrames = state.target
            stats.jitterSeconds = state.jitter
            if let percentiles = state.histogram.percentiles(now: state.lastArrival ?? 0) {
                stats.delayP50Seconds = percentiles.p50
                stats.delayP95Seconds = percentiles.p95
                stats.delayP99Seconds = percentiles.p99
                stats.delayMaxSeconds = percentiles.max
            }
            return stats
        }
    }

    // MARK: - Internals

    /// Latency trim decision for this pop (playing phase): tracks the peak
    /// depth over the trim window and, once a window ends with the peak above
    /// `target + slack`, arms a trim that fires on the first pop where the
    /// expected frame and its successor are both buffered. The peak — not
    /// the instantaneous depth — is compared because bursty delivery makes
    /// the depth swing below the target between bursts; only a surplus that
    /// persists even at the burst peaks is pure added latency.
    private func shouldTrim(_ state: inout State, expected: UInt32) -> Bool {
        guard let slack = config.latencyTrimSlackFrames else { return false }
        state.trimWindowMaxDepth = max(state.trimWindowMaxDepth, state.buffered.count)
        state.trimWindowPops += 1
        if TimeInterval(state.trimWindowPops) * config.frameDuration
            >= config.latencyTrimWindowSeconds - 1e-9
        {
            if state.trimWindowMaxDepth > state.target + slack {
                state.trimPending = true
            }
            state.trimWindowPops = 0
            state.trimWindowMaxDepth = 0
        }
        guard state.trimPending,
            state.buffered.count > state.target,
            state.buffered[expected] != nil,
            state.buffered[expected &+ 1] != nil
        else { return false }
        state.trimPending = false
        return true
    }

    private func resetTrimWindow(_ state: inout State) {
        state.trimWindowPops = 0
        state.trimWindowMaxDepth = 0
        state.trimPending = false
    }

    /// Cushion a buffering exit needs for `target`: with `target - 1` frames
    /// of spacing plus the newest packet's network delay, no on-time packet
    /// can arrive after its playout slot.
    private func requiredCushion(forTarget target: Int) -> TimeInterval {
        TimeInterval(max(target - 1, 0)) * config.frameDuration
    }

    /// RFC 3550 section 6.4.1 interarrival jitter: the smoothed mean absolute
    /// deviation of the arrival spacing from the media (RTP) timestamp
    /// spacing, with the standard 1/16 smoothing factor.
    private func updateJitter(
        _ state: inout State,
        arrivalTime: TimeInterval,
        mediaTime: TimeInterval
    ) {
        if let lastArrival = state.lastArrival, let lastMediaTime = state.lastMediaTime {
            let deviation = abs((arrivalTime - lastArrival) - (mediaTime - lastMediaTime))
            state.jitter += (deviation - state.jitter) / 16
        }
        state.lastArrival = arrivalTime
        state.lastMediaTime = mediaTime
    }

    /// Recomputes the target depth. Rises immediately on either estimator.
    /// Falls at most one frame per two seconds of playout; with
    /// `.delayPercentile` additionally only after the estimate has stayed
    /// below the current target for `targetFallHoldSeconds`, so one quiet
    /// second does not undo the cushion that a burst demanded.
    private func updateTarget(_ state: inout State, arrivalTime: TimeInterval) {
        guard let computed = computedTarget(&state, arrivalTime: arrivalTime) else { return }
        if computed > state.target {
            state.target = computed
            state.lowEstimateSince = nil
            return
        }
        guard computed < state.target else {
            state.lowEstimateSince = nil
            return
        }
        switch config.targetEstimator {
        case .rfc3550:
            if state.playoutSeconds - state.lastTargetDecreaseAt >= 2.0 {
                state.target = max(computed, state.target - 1)
                state.lastTargetDecreaseAt = state.playoutSeconds
            }
        case .delayPercentile:
            if state.lowEstimateSince == nil {
                state.lowEstimateSince = state.playoutSeconds
            }
            let estimateHeldLow =
                state.playoutSeconds - state.lowEstimateSince! >= config.targetFallHoldSeconds
            let rateLimitSatisfied =
                state.playoutSeconds - state.lastTargetDecreaseAt >= 2.0
            if estimateHeldLow && rateLimitSatisfied {
                state.target = max(computed, state.target - 1)
                state.lastTargetDecreaseAt = state.playoutSeconds
            }
        }
    }

    /// The target the current network observations call for, clamped to the
    /// configured range. Nil until the delay histogram has samples (the
    /// target then stays at the minimum).
    private func computedTarget(_ state: inout State, arrivalTime: TimeInterval) -> Int? {
        switch config.targetEstimator {
        case .rfc3550:
            let scaled = config.jitterMultiplier * state.jitter / config.frameDuration
            return min(
                max(Int(ceil(scaled)) + 1, config.minTargetFrames),
                config.maxTargetFrames
            )
        case .delayPercentile:
            guard let percentiles = state.histogram.percentiles(now: arrivalTime) else {
                return nil
            }
            // The epsilon keeps ceil() honest at exact frame boundaries
            // ((0.08 + 0.01) / 0.01 evaluates to 9.000000000000002).
            let scaled = (percentiles.p99 + config.safetyMargin) / config.frameDuration - 1e-9
            return min(
                max(Int(ceil(scaled)), config.minTargetFrames),
                config.maxTargetFrames
            )
        }
    }

    /// Refreshes the cushion estimate after an insert. While playing, the
    /// reference is the next expected sequence (how far playout lags the
    /// newest arrival); while rebuffering, it is the sequence playback will
    /// restart from, so the estimate is a safe lower bound for the cushion
    /// the restart will have.
    ///
    /// The estimate is anchored at the running minimum of
    /// `arrival - mediaTime` — the fastest path observed since the reset —
    /// rather than at whichever packet happened to arrive first: a first
    /// packet delivered at the tail of a power-save burst carries an
    /// above-minimum delay, and anchoring there would bias the cushion low.
    private func updateCushionEstimate(_ state: inout State, arrivalTime: TimeInterval) {
        guard let anchorSequence = state.anchorSequence else { return }
        let currentOffset = arrivalTime - state.anchorMediaTime
        if state.minOffsetSeen == nil || currentOffset < state.minOffsetSeen! {
            state.minOffsetSeen = currentOffset
        }
        func mediaTime(of sequence: UInt32) -> TimeInterval {
            let offset = Int64(Int32(bitPattern: sequence &- anchorSequence))
            return state.anchorMediaTime + TimeInterval(offset) * config.frameDuration
        }
        let reference: UInt32?
        if state.phase == .playing {
            reference = state.nextExpected
        } else {
            reference = lowestSequence(state.buffered)
        }
        guard let reference else { return }
        let minOffset = state.minOffsetSeen ?? currentOffset
        state.cushionEstimate = arrivalTime - mediaTime(of: reference) - minOffset
    }

    /// Lowest buffered sequence, wrap-around aware. Linear scan; the depth is
    /// bounded by `overflowFrames`, so this stays cheap.
    private func lowestSequence(_ buffered: [UInt32: AudioPacket]) -> UInt32? {
        var lowest: UInt32?
        for sequence in buffered.keys {
            if let current = lowest, sequenceIsAfter(current, sequence) {
                lowest = sequence
            } else if lowest == nil {
                lowest = sequence
            }
        }
        return lowest
    }

    private func resetBuffer(_ state: inout State) {
        state.buffered.removeAll(keepingCapacity: true)
        state.nextExpected = nil
        state.phase = .buffering
        state.exitTarget = 0
        state.consecutiveEmptyPops = 0
        state.jitter = 0
        state.lastArrival = nil
        state.lastMediaTime = nil
        state.anchorSequence = nil
        state.anchorMediaTime = 0
        state.cushionEstimate = 0
        state.minOffsetSeen = nil
        state.histogram = DelayHistogram(window: config.delayWindowSeconds)
        state.lowEstimateSince = nil
        state.pendingRiseInsert = nil
        resetTrimWindow(&state)
    }
}
