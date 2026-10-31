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
/// and injects the sample times. Sample times must be non-decreasing in
/// record order (arrival clocks are monotonic); the window prune relies on
/// it. Storage is preallocated at init and nothing allocates afterwards.
///
/// Cost: the offsets are also kept in a sorted array, so `record` and the
/// window prune are a binary search plus one `memmove` (O(n) bytes moved,
/// a few microseconds for a 45 s window at 200 packets/s), and every
/// percentile query is O(1) — no sorting, ever.
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
    /// The stored offsets in ascending order (`count` elements).
    private var sorted: [TimeInterval] = []

    public init(window: TimeInterval = 10, capacity: Int = 2048) {
        precondition(window > 0, "DelayHistogram window must be positive")
        precondition(capacity > 0, "DelayHistogram capacity must be positive")
        self.window = window
        self.capacity = capacity
        times = [TimeInterval](repeating: 0, count: capacity)
        offsets = [TimeInterval](repeating: 0, count: capacity)
        sorted.reserveCapacity(capacity)
    }

    /// Ring capacity that holds `window` seconds at `packetsPerSecond` with
    /// 25 % headroom.
    public static func capacity(window: TimeInterval, packetsPerSecond: Double) -> Int {
        Int((window * packetsPerSecond * 1.25).rounded(.up)) + 64
    }

    /// Records one packet: `arrivalTime` is the receive timestamp,
    /// `mediaTime` the packet's position in the sender's media clock
    /// (`sampleTime / sampleRate`).
    public mutating func record(arrivalTime: TimeInterval, mediaTime: TimeInterval) {
        let offset = arrivalTime - mediaTime
        if count == capacity {
            // Ring full: overwrite the oldest sample.
            removeSorted(offsets[head])
            times[head] = arrivalTime
            offsets[head] = offset
            head = (head + 1) % capacity
        } else {
            let tail = (head + count) % capacity
            times[tail] = arrivalTime
            offsets[tail] = offset
            count += 1
        }
        sorted.insert(offset, at: insertionIndex(offset))
    }

    /// Smallest `arrival - media` offset still stored (the fastest path), or
    /// nil when empty. Does not prune.
    public var minimumOffset: TimeInterval? { sorted.first }

    /// Drops samples that have left the window and returns the nearest-rank
    /// percentiles of the remaining relative delays, or nil when the window
    /// is empty. The prune side effect is the point when the result is
    /// discarded.
    @discardableResult
    public mutating func percentiles(now: TimeInterval) -> DelayPercentiles? {
        prune(now: now)
        guard count > 0 else { return nil }
        return DelayPercentiles(
            p50: rank(0.50),
            p95: rank(0.95),
            p99: rank(0.99),
            max: sorted[count - 1] - sorted[0],
            sampleCount: count
        )
    }

    /// Nearest-rank `fraction` quantile (0...1; 1 = max) of the windowed
    /// relative delays after pruning, or nil when empty. O(1).
    public mutating func quantile(_ fraction: Double, now: TimeInterval) -> TimeInterval? {
        prune(now: now)
        guard count > 0 else { return nil }
        return rank(fraction)
    }

    /// Forgets every sample (e.g. on a stream discontinuity, where delay
    /// history across the reset is meaningless).
    public mutating func reset() {
        head = 0
        count = 0
        sorted.removeAll(keepingCapacity: true)
    }

    // MARK: - Internals

    private func rank(_ fraction: Double) -> TimeInterval {
        // Nearest-rank: the ceil(fraction × n)-th smallest value.
        let index = min(max(Int((fraction * Double(count)).rounded(.up)), 1), count)
        return sorted[index - 1] - sorted[0]
    }

    /// Drops samples recorded strictly before `now - window`.
    private mutating func prune(now: TimeInterval) {
        let cutoff = now - window
        while count > 0, times[head] < cutoff {
            removeSorted(offsets[head])
            head = (head + 1) % capacity
            count -= 1
        }
    }

    /// First index whose value is >= `value` (binary search).
    private func insertionIndex(_ value: TimeInterval) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private mutating func removeSorted(_ value: TimeInterval) {
        let index = insertionIndex(value)
        if index < sorted.count, sorted[index] == value {
            sorted.remove(at: index)
        }
    }
}
