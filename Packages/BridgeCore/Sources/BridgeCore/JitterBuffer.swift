import Foundation
import os

/// Tuning parameters for the adaptive jitter buffer.
public struct JitterBufferConfig: Sendable {
    /// Nominal duration of one audio frame (10 ms at 48 kHz).
    public var frameDuration: TimeInterval = 0.010
    /// Lower clamp for the adaptive target depth (40 ms).
    public var minTargetFrames = 4
    /// Upper clamp for the adaptive target depth (80 ms).
    public var maxTargetFrames = 8
    /// Target = ceil(multiplier * jitter / frameDuration) + 1, clamped.
    public var jitterMultiplier = 3.0
    /// Depth above this resyncs the buffer by dropping the oldest frames
    /// down to the target.
    public var overflowFrames = 16

    public init() {}
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
    /// Frames reported missing at playout time.
    public var lost = 0
    /// Packets discarded because their playout slot had already passed.
    public var late = 0
    /// Repeated sequence numbers discarded.
    public var duplicates = 0
    /// Oldest frames dropped to recover from depth overflow.
    public var overflowDropped = 0
    /// Playout slots that found the buffer completely empty.
    public var underruns = 0
    /// Frames currently buffered.
    public var depthFrames = 0
    /// Current adaptive target depth in frames.
    public var targetFrames = 0
    /// Current RFC 3550 interarrival jitter estimate, in seconds.
    public var jitterSeconds: Double = 0
}

/// Payload-agnostic adaptive jitter buffer for `AudioPacket`s. Decoding and
/// packet-loss concealment happen in the caller; this type only reorders,
/// times and accounts for frames.
///
/// Threading: `insert` is called from the network queue, `pop()` from the
/// audio thread; all state lives behind a single short unfair lock. `pop()`
/// does not allocate beyond handing back the buffered packet.
///
/// Adaptivity: the target depth follows an RFC 3550 interarrival jitter
/// estimate (`ceil(jitterMultiplier * jitter / frameDuration) + 1`, clamped
/// to `[minTargetFrames, maxTargetFrames]`). The target rises immediately;
/// when it rises above the cushion the current playing run started with and
/// the buffer is shallower than the new target, the buffer briefly returns to
/// `.buffering` to rebuild the deeper cushion. The target falls at most one
/// frame per two seconds of playout, to avoid oscillation.
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
        var counters = JitterBufferStats()

        init(minTargetFrames: Int) {
            target = minTargetFrames
        }
    }

    private let config: JitterBufferConfig
    private let lock: OSAllocatedUnfairLock<State>

    public init(config: JitterBufferConfig = .init()) {
        self.config = config
        lock = OSAllocatedUnfairLock(initialState: State(minTargetFrames: config.minTargetFrames))
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

            let mediaTime = Double(packet.sampleTime) / AudioFormat.sampleRate
            self.updateJitter(&state, arrivalTime: arrivalTime, mediaTime: mediaTime)
            self.updateTarget(&state)

            let sequence = packet.sequence
            if state.buffered[sequence] != nil {
                state.counters.duplicates += 1
                return
            }
            if let expected = state.nextExpected, sequenceIsAfter(expected, sequence) {
                state.counters.late += 1
                return
            }
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
                if state.buffered.count < state.target {
                    // The adapted target now demands a deeper cushion than
                    // the one this playing run started with: pause playback
                    // and rebuild it.
                    state.phase = .buffering
                    state.exitTarget = 0
                } else {
                    // Already deep enough for the new target.
                    state.exitTarget = state.target
                }
            }
        }
    }

    /// Returns the next playout slot: the next buffered frame in order, a
    /// loss to conceal, or `.buffering` while prebuffering. Must be called
    /// exactly once per `frameDuration` by the playout clock.
    public func pop() -> JitterBufferOutput {
        lock.withLock { (state: inout State) in
            // Leave buffering once the depth reaches the target; playback
            // then starts from the lowest buffered sequence.
            if state.phase == .buffering {
                guard state.buffered.count >= state.target else { return .buffering }
                state.phase = .playing
                state.exitTarget = state.target
                state.consecutiveEmptyPops = 0
                state.nextExpected = self.lowestSequence(state.buffered)
            }

            guard let expected = state.nextExpected else { return .buffering }
            state.playoutSeconds += config.frameDuration

            if let packet = state.buffered.removeValue(forKey: expected) {
                state.consecutiveEmptyPops = 0
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
                state.consecutiveEmptyPops = 0
            }
            return .lost(sequence: expected)
        }
    }

    /// Clears buffered audio and returns to prebuffering, e.g. on a stream
    /// discontinuity or reconnect. Session counters are kept; the jitter
    /// estimator restarts because inter-arrival history across a reset is
    /// meaningless.
    public func reset() {
        lock.withLock { (state: inout State) in
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
            return stats
        }
    }

    // MARK: - Internals

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

    /// Recomputes the target depth: rises immediately, falls at most one
    /// frame per two seconds of playout.
    private func updateTarget(_ state: inout State) {
        let scaled = config.jitterMultiplier * state.jitter / config.frameDuration
        let computed = min(
            max(Int(ceil(scaled)) + 1, config.minTargetFrames),
            config.maxTargetFrames
        )
        if computed > state.target {
            state.target = computed
        } else if computed < state.target,
            state.playoutSeconds - state.lastTargetDecreaseAt >= 2.0
        {
            state.target = max(computed, state.target - 1)
            state.lastTargetDecreaseAt = state.playoutSeconds
        }
    }

    /// Lowest buffered sequence, wrap-around aware. Linear scan; the depth is
    /// bounded by `overflowFrames`, so this stays cheap on the pop path.
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
    }
}
