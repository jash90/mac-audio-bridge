import Foundation

/// Percentile snapshot of the per-packet relative delay distribution over a
/// sliding window, in seconds.
public struct DelayPercentiles: Sendable, Equatable {
    /// Median relative delay (nearest-rank).
    public var p50: TimeInterval
    /// 95th percentile relative delay (nearest-rank).
    public var p95: TimeInterval
    /// 99th percentile relative delay (nearest-rank).
    public var p99: TimeInterval
    /// Largest relative delay in the window.
    public var max: TimeInterval
    /// Number of samples the snapshot covers.
    public var sampleCount: Int

    public init(p50: TimeInterval, p95: TimeInterval, p99: TimeInterval, max: TimeInterval, sampleCount: Int) {
        self.p50 = p50
        self.p95 = p95
        self.p99 = p99
        self.max = max
        self.sampleCount = sampleCount
    }
}

/// Sliding-window histogram of per-packet relative network delay — the
/// quantity a jitter-buffer target must actually cover.
///
/// Each recorded packet contributes the relative delay
/// `d = arrivalTime - mediaTime - minObserved(arrivalTime - mediaTime)`, where
/// the minimum runs over the samples still inside the window: the fastest
/// path observed anchors the distribution at zero, so `d` is the extra delay
/// a packet suffered compared to the best case, independent of the unrelated
/// clock epochs of the two sides. This is what makes the distribution robust
/// to bursty delivery (Wi-Fi power save), where an RFC 3550 mean-deviation
/// estimate underestimates the tail: bursts show up directly in p99/max.
///
/// Pure value type, no clocks and no locks: the caller owns the threading
/// (inside the jitter buffer's lock, or a network queue) and injects the
/// sample times. Sample times must be non-decreasing in record order (arrival
/// clocks are monotonic); the window prune relies on it. Storage is
/// preallocated at init and recording never allocates; `percentiles` sorts
/// into a preallocated scratch buffer, so steady-state calls do not allocate
/// either.
public struct DelayHistogram: Sendable {
    /// Samples older than this many seconds before `now` stop counting.
    private let window: TimeInterval
    /// Maximum samples kept (ring capacity). Must comfortably exceed
    /// `window × packet rate`, otherwise the ring overwrites samples before
    /// they expire and the effective window shrinks.
    private let capacity: Int
    private var times: [TimeInterval]
    private var offsets: [TimeInterval]
    /// Index of the oldest sample inside the ring.
    private var head = 0
    /// Samples currently stored (alive or not yet pruned).
    private var count = 0
    /// Scratch buffer for percentile computation, reused across calls.
    private var scratch: [TimeInterval] = []

    public init(window: TimeInterval = 10, capacity: Int = 2048) {
        precondition(window > 0, "DelayHistogram window must be positive")
        precondition(capacity > 0, "DelayHistogram capacity must be positive")
        self.window = window
        self.capacity = capacity
        times = [TimeInterval](repeating: 0, count: capacity)
        offsets = [TimeInterval](repeating: 0, count: capacity)
        scratch.reserveCapacity(capacity)
    }

    /// Records one packet: `arrivalTime` is the receive timestamp,
    /// `mediaTime` the packet's position in the sender's media clock
    /// (`sampleTime / sampleRate`).
    public mutating func record(arrivalTime: TimeInterval, mediaTime: TimeInterval) {
        let offset = arrivalTime - mediaTime
        if count == capacity {
            // Ring full: overwrite the oldest sample.
            times[head] = arrivalTime
            offsets[head] = offset
            head = (head + 1) % capacity
        } else {
            let tail = (head + count) % capacity
            times[tail] = arrivalTime
            offsets[tail] = offset
            count += 1
        }
    }

    /// Drops samples that have left the window and returns the nearest-rank
    /// percentiles of the remaining relative delays, or nil when the window
    /// is empty. The prune side effect is the point when the result is
    /// discarded.
    @discardableResult
    public mutating func percentiles(now: TimeInterval) -> DelayPercentiles? {
        prune(now: now)
        guard count > 0 else { return nil }

        var minOffset = offsets[head]
        for index in 0..<count {
            let offset = offsets[(head + index) % capacity]
            if offset < minOffset { minOffset = offset }
        }

        scratch.removeAll(keepingCapacity: true)
        for index in 0..<count {
            scratch.append(offsets[(head + index) % capacity] - minOffset)
        }
        scratch.sort()

        func percentile(_ fraction: Double) -> TimeInterval {
            // Nearest-rank: the ceil(fraction × n)-th smallest value.
            let rank = min(max(Int((fraction * Double(count)).rounded(.up)), 1), count)
            return scratch[rank - 1]
        }

        return DelayPercentiles(
            p50: percentile(0.50),
            p95: percentile(0.95),
            p99: percentile(0.99),
            max: scratch[count - 1],
            sampleCount: count
        )
    }

    /// Forgets every sample (e.g. on a stream discontinuity, where delay
    /// history across the reset is meaningless).
    public mutating func reset() {
        head = 0
        count = 0
    }

    /// Drops samples recorded strictly before `now - window`.
    private mutating func prune(now: TimeInterval) {
        let cutoff = now - window
        while count > 0, times[head] < cutoff {
            head = (head + 1) % capacity
            count -= 1
        }
    }
}
