import Testing
import Foundation
@testable import BridgeCore

struct JitterBufferTests {
    // MARK: - Helpers

    /// Builds a packet for `sequence` whose position in the sender's stream is
    /// `streamFrame`. Passing `streamFrame == sequence` models an in-order
    /// sender; wrap-around tests use a continuous frame counter while the
    /// sequence wraps.
    private func packet(
        sequence: UInt32,
        streamFrame: UInt64,
        flags: AudioPacketFlags = []
    ) -> AudioPacket {
        AudioPacket(
            codec: .pcm16,
            flags: flags,
            sequence: sequence,
            sampleTime: streamFrame * UInt64(AudioFormat.samplesPerFrame),
            payload: Data([0x5A])
        )
    }

    /// Inserts `sequence` assuming it is frame `streamFrame` of the stream,
    /// arriving exactly on time. Keeps the jitter estimate at zero so the
    /// adaptive target stays at `minTargetFrames` and the tests are
    /// deterministic.
    private func insert(
        _ buffer: JitterBuffer,
        sequence: UInt32,
        streamFrame: UInt64,
        flags: AudioPacketFlags = []
    ) {
        buffer.insert(
            packet(sequence: sequence, streamFrame: streamFrame, flags: flags),
            arrivalTime: TimeInterval(streamFrame) * 0.010
        )
    }

    /// Inserts whole frames of an in-order sender: the sequence doubles as
    /// the stream frame index, arrivals are perfectly spaced, so the jitter
    /// estimate stays at zero. Gaps model dropped packets.
    private func insert(_ buffer: JitterBuffer, sequences: UInt32..., flags: AudioPacketFlags = []) {
        for sequence in sequences {
            insert(buffer, sequence: sequence, streamFrame: UInt64(sequence), flags: flags)
        }
    }

    private func packets(_ sequences: [UInt32]) -> [JitterBufferOutput] {
        sequences.map { sequence in
            .packet(packet(sequence: sequence, streamFrame: UInt64(sequence)))
        }
    }

    // MARK: - Buffering and playback

    @Test("Latency presets are valid: min ≤ max < overflow, overflow = max + 6")
    func latencyPresetsAreValid() {
        let presets: [JitterLatencyMode: (min: Int, max: Int)] = [
            .low: (3, 12),
            .balanced: (5, 25),
            .safe: (10, 40),
        ]
        for (mode, bounds) in presets {
            let config = JitterBufferConfig.latency(mode)
            #expect(config.minTargetFrames == bounds.min)
            #expect(config.maxTargetFrames == bounds.max)
            #expect(config.overflowFrames == config.maxTargetFrames + 6)
            #expect(config.minTargetFrames <= config.maxTargetFrames)
            #expect(config.maxTargetFrames < config.overflowFrames)
            #expect(config.targetEstimator == .delayPercentile)
        }
    }

    @Test("Stays in buffering until the depth reaches the target")
    func staysBufferingUntilDepthReachesTarget() {
        let buffer = JitterBuffer()
        insert(buffer, sequences: 0, 1, 2)
        #expect(buffer.pop() == .buffering)
        #expect(buffer.pop() == .buffering)
        #expect(buffer.stats.depthFrames == 3)
        // Initial prebuffering is not a mid-stream silence gap.
        #expect(buffer.stats.bufferingPops == 0)

        insert(buffer, sequence: 3, streamFrame: 3)
        // Playback starts from the lowest buffered sequence.
        #expect(buffer.pop() == .packet(packet(sequence: 0, streamFrame: 0)))
    }

    @Test("Plays buffered frames in order")
    func playsInOrder() {
        let buffer = JitterBuffer()
        insert(buffer, sequences: 0, 1, 2, 3, 4, 5)
        var outputs: [JitterBufferOutput] = []
        for _ in 0..<6 { outputs.append(buffer.pop()) }
        #expect(outputs == packets([0, 1, 2, 3, 4, 5]))

        let stats = buffer.stats
        #expect(stats.lost == 0)
        #expect(stats.late == 0)
        #expect(stats.depthFrames == 0)
        #expect(stats.received == 6)
    }

    @Test("Reordered packets within the window play in order")
    func reorderWithinWindowPlaysInOrder() {
        let buffer = JitterBuffer()
        // Frames arrive out of order: 0, 2, 1, 3; each frame's stream time
        // still matches its sequence.
        buffer.insert(packet(sequence: 0, streamFrame: 0), arrivalTime: 0.000)
        buffer.insert(packet(sequence: 2, streamFrame: 2), arrivalTime: 0.010)
        buffer.insert(packet(sequence: 1, streamFrame: 1), arrivalTime: 0.020)
        buffer.insert(packet(sequence: 3, streamFrame: 3), arrivalTime: 0.030)

        var outputs: [JitterBufferOutput] = []
        for _ in 0..<4 { outputs.append(buffer.pop()) }
        #expect(outputs == packets([0, 1, 2, 3]))
        #expect(buffer.stats.late == 0)
    }

    // MARK: - Duplicates, late packets, loss

    @Test("Duplicate sequences are counted and discarded")
    func duplicatesAreDiscarded() {
        let buffer = JitterBuffer()
        insert(buffer, sequences: 0, 1, 2, 3)
        insert(buffer, sequence: 1, streamFrame: 4)

        var outputs: [JitterBufferOutput] = []
        for _ in 0..<4 { outputs.append(buffer.pop()) }
        #expect(outputs == packets([0, 1, 2, 3]))
        #expect(buffer.stats.duplicates == 1)
        #expect(buffer.stats.depthFrames == 0)
    }

    @Test("Packets older than the next expected sequence are late")
    func latePacketsAreDiscarded() {
        let buffer = JitterBuffer()
        insert(buffer, sequences: 0, 1, 2, 3, 4)
        #expect(buffer.pop() == .packet(packet(sequence: 0, streamFrame: 0)))

        // Sequence 0 was already played.
        buffer.insert(packet(sequence: 0, streamFrame: 0), arrivalTime: 0.05)
        #expect(buffer.stats.late == 1)
        #expect(buffer.stats.depthFrames == 4)

        var outputs: [JitterBufferOutput] = []
        for _ in 0..<4 { outputs.append(buffer.pop()) }
        #expect(outputs == packets([1, 2, 3, 4]))
    }

    @Test("A missing frame is reported lost and playback advances")
    func missingFrameIsReportedLost() {
        let buffer = JitterBuffer()
        insert(buffer, sequences: 0, 1, 3, 4)

        var outputs: [JitterBufferOutput] = []
        for _ in 0..<4 { outputs.append(buffer.pop()) }
        #expect(outputs == [
            .packet(packet(sequence: 0, streamFrame: 0)),
            .packet(packet(sequence: 1, streamFrame: 1)),
            .lost(sequence: 2),
            .packet(packet(sequence: 3, streamFrame: 3)),
        ])
        #expect(buffer.stats.lost == 1)

        #expect(buffer.pop() == .packet(packet(sequence: 4, streamFrame: 4)))
        #expect(buffer.stats.lost == 1)
    }

    // MARK: - Wrap-around

    @Test("Plays in order across the UInt32 sequence wrap-around")
    func wrapAroundPlayback() {
        let buffer = JitterBuffer()
        // The sequence wraps while the sender's stream frame counter
        // continues: (max-2, max-1, max, 0) are stream frames 0-3.
        buffer.insert(packet(sequence: .max - 2, streamFrame: 0), arrivalTime: 0.000)
        buffer.insert(packet(sequence: .max - 1, streamFrame: 1), arrivalTime: 0.010)
        buffer.insert(packet(sequence: .max, streamFrame: 2), arrivalTime: 0.020)
        buffer.insert(packet(sequence: 0, streamFrame: 3), arrivalTime: 0.030)

        var outputs: [JitterBufferOutput] = []
        for _ in 0..<4 { outputs.append(buffer.pop()) }
        #expect(outputs == [
            .packet(packet(sequence: .max - 2, streamFrame: 0)),
            .packet(packet(sequence: .max - 1, streamFrame: 1)),
            .packet(packet(sequence: .max, streamFrame: 2)),
            .packet(packet(sequence: 0, streamFrame: 3)),
        ])

        insert(buffer, sequence: 1, streamFrame: 4)
        #expect(buffer.pop() == .packet(packet(sequence: 1, streamFrame: 4)))
    }

    @Test("Reports loss across the wrap-around")
    func wrapAroundLoss() {
        let buffer = JitterBuffer()
        buffer.insert(packet(sequence: .max - 2, streamFrame: 0), arrivalTime: 0.000)
        buffer.insert(packet(sequence: .max - 1, streamFrame: 1), arrivalTime: 0.010)
        buffer.insert(packet(sequence: 0, streamFrame: 2), arrivalTime: 0.020)
        buffer.insert(packet(sequence: 1, streamFrame: 3), arrivalTime: 0.030)

        var outputs: [JitterBufferOutput] = []
        for _ in 0..<4 { outputs.append(buffer.pop()) }
        #expect(outputs == [
            .packet(packet(sequence: .max - 2, streamFrame: 0)),
            .packet(packet(sequence: .max - 1, streamFrame: 1)),
            .lost(sequence: .max),
            .packet(packet(sequence: 0, streamFrame: 2)),
        ])
        #expect(buffer.stats.lost == 1)
        #expect(buffer.stats.late == 0)
    }

    // MARK: - Discontinuity, overflow, underrun

    @Test("Discontinuity flag resets the buffer, then prebuffers again")
    func discontinuityResetsAndRebuffers() {
        let buffer = JitterBuffer()
        insert(buffer, sequences: 0, 1, 2, 3, 4)
        #expect(buffer.pop() == .packet(packet(sequence: 0, streamFrame: 0)))
        #expect(buffer.pop() == .packet(packet(sequence: 1, streamFrame: 1)))

        insert(buffer, sequence: 100, streamFrame: 100, flags: [.discontinuity])
        #expect(buffer.stats.depthFrames == 1)
        #expect(buffer.pop() == .buffering)

        insert(buffer, sequences: 101, 102, 103)
        var outputs: [JitterBufferOutput] = []
        for _ in 0..<4 { outputs.append(buffer.pop()) }
        // The discontinuity packet keeps its flag; the stream plays on.
        #expect(outputs == [
            .packet(packet(sequence: 100, streamFrame: 100, flags: [.discontinuity])),
            .packet(packet(sequence: 101, streamFrame: 101)),
            .packet(packet(sequence: 102, streamFrame: 102)),
            .packet(packet(sequence: 103, streamFrame: 103)),
        ])

        let stats = buffer.stats
        #expect(stats.lost == 0)
        #expect(stats.late == 0)
        #expect(stats.duplicates == 0)
        #expect(stats.received == 9)
        // A discontinuity reset is caller-driven prebuffering, not a
        // rebuffer; the silence it causes still counts as a mid-stream gap.
        #expect(stats.rebuffers == 0)
        #expect(stats.bufferingPops == 1)
    }

    @Test("Depth above overflowFrames drops the oldest frames down to target")
    func overflowResyncsToTarget() {
        let buffer = JitterBuffer()
        insert(buffer, sequences: 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15)
        #expect(buffer.stats.overflowDropped == 0)

        insert(buffer, sequence: 16, streamFrame: 16)

        let stats = buffer.stats
        #expect(stats.overflowDropped == 13)
        #expect(stats.depthFrames == 4)

        var outputs: [JitterBufferOutput] = []
        for _ in 0..<4 { outputs.append(buffer.pop()) }
        #expect(outputs == packets([13, 14, 15, 16]))
    }

    @Test("Underruns keep timing, then return the buffer to buffering")
    func underrunReturnsToBuffering() {
        let buffer = JitterBuffer()
        insert(buffer, sequences: 0, 1, 2, 3)
        for _ in 0..<4 { _ = buffer.pop() }

        // Buffer is empty; eight consecutive empty pops (maxTargetFrames)
        // keep reporting the expected sequence as lost.
        for expected in 4..<12 {
            #expect(buffer.pop() == .lost(sequence: UInt32(expected)))
        }
        let stats = buffer.stats
        #expect(stats.underruns == 8)
        // The sustained stall itself was the rebuffer; the empty pops report
        // losses, not silence gaps.
        #expect(stats.rebuffers == 1)
        #expect(stats.bufferingPops == 0)

        // The sustained stall returned the buffer to prebuffering.
        #expect(buffer.pop() == .buffering)
        #expect(buffer.stats.bufferingPops == 1)

        insert(buffer, sequences: 20, 21, 22, 23)
        #expect(buffer.pop() == .packet(packet(sequence: 20, streamFrame: 20)))
    }

    // MARK: - Delay-percentile target estimator

    @Test("Delay-percentile target rises on a held burst and falls slowly")
    func delayPercentileTargetRisesAndFallsSlowly() {
        var config = JitterBufferConfig()
        config.minTargetFrames = 3
        config.maxTargetFrames = 12
        config.delayWindowSeconds = 1  // small window so it turns over quickly
        let buffer = JitterBuffer(config: config)

        // 2 s of on-time frames: zero relative delay, target stays at the
        // minimum. Pops lag inserts by 10 frames.
        for frame in 0..<200 {
            insert(buffer, sequence: UInt32(frame), streamFrame: UInt64(frame))
            if frame >= 10 { _ = buffer.pop() }
        }
        #expect(buffer.stats.targetFrames == 3)

        // A burst: frames 200-207 are held and land together 80 ms after
        // frame 200's send time (offsets 80 ms down to 10 ms). While the
        // burst is still landing, p99 equals the max (80 ms) → target 9;
        // the fully-landed window would compute 8, but the target never
        // chases a lower estimate down.
        for frame in 200..<208 {
            buffer.insert(
                packet(sequence: UInt32(frame), streamFrame: UInt64(frame)),
                arrivalTime: 2.0 + 0.080
            )
        }
        #expect(buffer.stats.targetFrames == 9)

        // 4 s of clean traffic, by which point the burst samples have left
        // the 1 s window: the estimate is low again, but the 5 s hold and
        // the one-frame-per-2 s rate limit keep the target at 9.
        for frame in 260..<660 {
            insert(buffer, sequence: UInt32(frame), streamFrame: UInt64(frame))
            _ = buffer.pop()
        }
        #expect(buffer.stats.targetFrames == 9)

        // After the hold elapses the target steps down at most one frame per
        // 2 s: 8 more seconds of clean traffic cannot reach the floor (that
        // would need ~10 s of falls alone).
        for frame in 660..<1460 {
            insert(buffer, sequence: UInt32(frame), streamFrame: UInt64(frame))
            _ = buffer.pop()
        }
        let settled = buffer.stats.targetFrames
        #expect(settled >= 3)
        #expect(settled <= 6)
    }

    @Test("Cushion anchors at the fastest observed path, not the first packet")
    func cushionAnchorsAtFastestPath() {
        var config = JitterBufferConfig()
        config.minTargetFrames = 3
        config.maxTargetFrames = 12
        let buffer = JitterBuffer(config: config)

        // Fresh packets 4 and 5 arrive first (fast path, offset ~1 ms); the
        // delayed batch (frames 0-3, offsets 110-83 ms) lands after them,
        // then frame 6 arrives on the fast path again.
        buffer.insert(packet(sequence: 4, streamFrame: 4), arrivalTime: 0.041)
        buffer.insert(packet(sequence: 5, streamFrame: 5), arrivalTime: 0.051)
        buffer.insert(packet(sequence: 0, streamFrame: 0), arrivalTime: 0.110)
        buffer.insert(packet(sequence: 1, streamFrame: 1), arrivalTime: 0.111)
        buffer.insert(packet(sequence: 2, streamFrame: 2), arrivalTime: 0.112)
        buffer.insert(packet(sequence: 3, streamFrame: 3), arrivalTime: 0.113)
        buffer.insert(packet(sequence: 6, streamFrame: 6), arrivalTime: 0.115)

        // The burst pushes the p99 to ~109 ms → target 12; the cushion is
        // anchored at the fast path (1 ms), so at frame 6's insert it is
        // 114 ms ≥ (12 - 1) × 10 ms and playback may start from the oldest
        // buffered frame — at depth 7 < 12, i.e. via the cushion exit, which
        // an anchor at the first observed packet (11 ms higher) would miss.
        #expect(buffer.stats.targetFrames == 12)
        #expect(buffer.pop() == .packet(packet(sequence: 0, streamFrame: 0)))
    }

    @Test("applyConfig resets buffered audio and applies the new range immediately")
    func applyConfigResetsAndApplies() {
        let buffer = JitterBuffer(config: .latency(.balanced))
        insert(buffer, sequences: 0, 1, 2, 3, 4, 5, 6)
        #expect(buffer.stats.depthFrames == 7)
        #expect(buffer.stats.targetFrames == 5)

        buffer.applyConfig(.latency(.low))

        let stats = buffer.stats
        #expect(stats.depthFrames == 0)
        #expect(stats.targetFrames == 3)
        #expect(buffer.pop() == .buffering)
    }
}
