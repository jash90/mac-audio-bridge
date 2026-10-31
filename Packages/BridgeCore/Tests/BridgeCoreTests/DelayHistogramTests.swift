import Testing
import Foundation
@testable import BridgeCore

struct DelayHistogramTests {
    private func approxEquals(_ a: TimeInterval, _ b: TimeInterval, tolerance: TimeInterval = 1e-9) -> Bool {
        abs(a - b) <= tolerance
    }

    @Test("Nearest-rank percentiles over the windowed relative delays")
    func percentilesUseNearestRank() {
        var histogram = DelayHistogram(window: 10, capacity: 256)
        // Frame i arrives at t = 0.1·i with offset 0.001·i, so the relative
        // delay of sample i is 0.001·i (the minimum anchors at sample 0).
        for i in 0..<100 {
            let arrival = Double(i) * 0.100
            histogram.record(arrivalTime: arrival, mediaTime: arrival - 0.001 * Double(i))
        }

        let snapshot = histogram.percentiles(now: 9.9)

        #expect(snapshot?.sampleCount == 100)
        #expect(approxEquals(snapshot?.p50 ?? -1, 0.049))
        #expect(approxEquals(snapshot?.p95 ?? -1, 0.094))
        #expect(approxEquals(snapshot?.p99 ?? -1, 0.098))
        #expect(approxEquals(snapshot?.max ?? -1, 0.099))
    }

    @Test("A single sample is every percentile")
    func singleSample() {
        var histogram = DelayHistogram(window: 10, capacity: 8)
        histogram.record(arrivalTime: 1.0, mediaTime: 0.95)

        let snapshot = histogram.percentiles(now: 1.0)

        #expect(snapshot?.sampleCount == 1)
        #expect(approxEquals(snapshot?.p50 ?? -1, 0))
        #expect(approxEquals(snapshot?.p99 ?? -1, 0))
        #expect(approxEquals(snapshot?.max ?? -1, 0))
    }

    @Test("Samples expire from the window and the minimum re-anchors")
    func windowExpiryReanchorsMinimum() {
        var histogram = DelayHistogram(window: 1, capacity: 64)
        // A slow sample (offset 50 ms) followed by a fast one (offset 5 ms).
        histogram.record(arrivalTime: 0.0, mediaTime: -0.050)
        histogram.record(arrivalTime: 0.5, mediaTime: 0.495)

        let before = histogram.percentiles(now: 0.6)
        #expect(before?.sampleCount == 2)
        #expect(approxEquals(before?.max ?? -1, 0.045))

        // The slow sample leaves the window; only the fast one remains and
        // the minimum re-anchors to it, so the relative delay collapses to 0
        // instead of keeping the expired minimum as the zero point.
        let after = histogram.percentiles(now: 1.5)
        #expect(after?.sampleCount == 1)
        #expect(approxEquals(after?.p50 ?? -1, 0))
        #expect(approxEquals(after?.max ?? -1, 0))

        // Everything expired: no snapshot.
        #expect(histogram.percentiles(now: 5.0) == nil)
    }

    @Test("Recording past capacity overwrites the oldest sample")
    func ringOverwritesOldest() {
        var histogram = DelayHistogram(window: 100, capacity: 4)
        for i in 0..<6 {
            let arrival = Double(i) * 0.1
            histogram.record(arrivalTime: arrival, mediaTime: arrival - 0.001 * Double(i))
        }

        // Samples 0 and 1 were overwritten; offsets {0.002, 0.003, 0.004,
        // 0.005} anchor at their minimum, so the relative delays are
        // {0, 0.001, 0.002, 0.003}.
        let snapshot = histogram.percentiles(now: 1.0)

        #expect(snapshot?.sampleCount == 4)
        #expect(approxEquals(snapshot?.max ?? -1, 0.003))
        #expect(approxEquals(snapshot?.p50 ?? -1, 0.001))
    }

    @Test("reset forgets every sample")
    func resetClearsWindow() {
        var histogram = DelayHistogram(window: 10, capacity: 16)
        histogram.record(arrivalTime: 0.0, mediaTime: -0.05)
        histogram.percentiles(now: 0.0)
        histogram.reset()

        #expect(histogram.percentiles(now: 0.5) == nil)

        // And records normally afterwards.
        histogram.record(arrivalTime: 1.0, mediaTime: 1.0)
        #expect(histogram.percentiles(now: 1.0)?.sampleCount == 1)
    }

    @Test("Anchors at the fastest path even when it arrives late in record order")
    func minimumAnchorsAtFastestPath() {
        var histogram = DelayHistogram(window: 10, capacity: 64)
        // Burst: packets held 110-83 ms land first, then a fast one (offset
        // 55 ms) — the minimum must anchor at the fast path, not at the
        // first-recorded packet, so the relative delays are the offsets
        // {110, 101, 92, 55} ms minus 55 ms.
        histogram.record(arrivalTime: 0.110, mediaTime: 0.000)
        histogram.record(arrivalTime: 0.111, mediaTime: 0.010)
        histogram.record(arrivalTime: 0.112, mediaTime: 0.020)
        histogram.record(arrivalTime: 0.115, mediaTime: 0.060)

        let snapshot = histogram.percentiles(now: 0.115)

        #expect(snapshot?.sampleCount == 4)
        #expect(approxEquals(snapshot?.max ?? -1, 0.055))
        // Nearest-rank median of {0, 0.037, 0.046, 0.055} is rank 2 = 0.037.
        #expect(approxEquals(snapshot?.p50 ?? -1, 0.037))
    }
}
