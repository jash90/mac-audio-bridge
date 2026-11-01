import Testing
import Foundation
@testable import BridgeCore

struct JitterBufferTests {
    // MARK: - Helpers

    /// One playout slot (5 ms).
    private static let frame = AudioFormat.frameDuration

    /// The pre-M2.8 frame-count tuning (min 4, max 8, overflow 16, trim
    /// slack 2) that the unit tests below were written against, so their
    /// sequence arithmetic stays readable; only the frame length changed.
    private static var frameCountConfig: JitterBufferConfig {
        var config = JitterBufferConfig()
        config.minTargetFrames = 4
        config.maxTargetFrames = 8
        config.overflowFrames = 16
        config.latencyTrimSlackFrames = 2
        return config
    }

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
            arrivalTime: TimeInterval(streamFrame) * Self.frame
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

    @Test("Latency presets are valid and expressed in milliseconds")
    func latencyPresetsAreValid() {
        let presets: [JitterLatencyMode: (minMs: Int, maxMs: Int, quantile: Double, window: TimeInterval)] = [
            .low: (20, 120, 0.99, 10),
            .balanced: (30, 300, 1.0, 45),
            .safe: (80, 500, 1.0, 90),
        ]
        for (mode, expected) in presets {
            let config = JitterBufferConfig.latency(mode)
            #expect(config.minTargetFrames * AudioFormat.frameDurationMs == expected.minMs)
            #expect(config.maxTargetFrames * AudioFormat.frameDurationMs == expected.maxMs)
            #expect(config.delayQuantile == expected.quantile)
            #expect(config.delayWindowSeconds == expected.window)
            #expect(config.minTargetFrames <= config.maxTargetFrames)
            #expect(config.maxTargetFrames < config.overflowFrames)
            #expect(config.overflowFrames < JitterBuffer.slotCount - 16)
            #expect(config.targetEstimator == .delayPercentile)
            #expect(config.frameDuration == AudioFormat.frameDuration)
        }
        // The default config keeps the pre-M2.8 milliseconds: 40–80 ms
        // target, 160 ms overflow, 20 ms trim slack, 10 ms trimmed per second.
        let defaults = JitterBufferConfig()
        #expect(defaults.minTargetFrames * AudioFormat.frameDurationMs == 40)
        #expect(defaults.maxTargetFrames * AudioFormat.frameDurationMs == 80)
        #expect(defaults.overflowFrames * AudioFormat.frameDurationMs == 160)
        #expect((defaults.latencyTrimSlackFrames ?? 0) * AudioFormat.frameDurationMs == 20)
        #expect(Double(AudioFormat.frameDurationMs) / defaults.latencyTrimWindowSeconds == 10)
    }

    @Test("Stays in buffering until the depth reaches the target")
    func staysBufferingUntilDepthReachesTarget() {
        let buffer = JitterBuffer(config: Self.frameCountConfig)
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
        let buffer = JitterBuffer(config: Self.frameCountConfig)
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
        let buffer = JitterBuffer(config: Self.frameCountConfig)
        // Frames arrive out of order: 0, 2, 1, 3; each frame's stream time
        // still matches its sequence.
        buffer.insert(packet(sequence: 0, streamFrame: 0), arrivalTime: 0 * Self.frame)
        buffer.insert(packet(sequence: 2, streamFrame: 2), arrivalTime: 1 * Self.frame)
        buffer.insert(packet(sequence: 1, streamFrame: 1), arrivalTime: 2 * Self.frame)
        buffer.insert(packet(sequence: 3, streamFrame: 3), arrivalTime: 3 * Self.frame)

        var outputs: [JitterBufferOutput] = []
        for _ in 0..<4 { outputs.append(buffer.pop()) }
        #expect(outputs == packets([0, 1, 2, 3]))
        #expect(buffer.stats.late == 0)
    }

    // MARK: - Duplicates, late packets, loss

    @Test("Duplicate sequences are counted and discarded")
    func duplicatesAreDiscarded() {
        let buffer = JitterBuffer(config: Self.frameCountConfig)
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
        let buffer = JitterBuffer(config: Self.frameCountConfig)
        insert(buffer, sequences: 0, 1, 2, 3, 4)
        #expect(buffer.pop() == .packet(packet(sequence: 0, streamFrame: 0)))

        // Sequence 0 was already played.
        buffer.insert(packet(sequence: 0, streamFrame: 0), arrivalTime: 5 * Self.frame)
        #expect(buffer.stats.late == 1)
        #expect(buffer.stats.depthFrames == 4)

        var outputs: [JitterBufferOutput] = []
        for _ in 0..<4 { outputs.append(buffer.pop()) }
        #expect(outputs == packets([1, 2, 3, 4]))
    }

    @Test("A missing frame is reported lost and playback advances")
    func missingFrameIsReportedLost() {
        let buffer = JitterBuffer(config: Self.frameCountConfig)
        // Frames 5 and 6 are newer than frame 2's loss horizon: 2 is given up.
        insert(buffer, sequences: 0, 1, 3, 4, 5, 6)

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
        let buffer = JitterBuffer(config: Self.frameCountConfig)
        // The sequence wraps while the sender's stream frame counter
        // continues: (max-2, max-1, max, 0) are stream frames 0-3.
        buffer.insert(packet(sequence: .max - 2, streamFrame: 0), arrivalTime: 0 * Self.frame)
        buffer.insert(packet(sequence: .max - 1, streamFrame: 1), arrivalTime: 1 * Self.frame)
        buffer.insert(packet(sequence: .max, streamFrame: 2), arrivalTime: 2 * Self.frame)
        buffer.insert(packet(sequence: 0, streamFrame: 3), arrivalTime: 3 * Self.frame)

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
        let buffer = JitterBuffer(config: Self.frameCountConfig)
        buffer.insert(packet(sequence: .max - 2, streamFrame: 0), arrivalTime: 0 * Self.frame)
        buffer.insert(packet(sequence: .max - 1, streamFrame: 1), arrivalTime: 1 * Self.frame)
        buffer.insert(packet(sequence: 0, streamFrame: 2), arrivalTime: 2 * Self.frame)
        buffer.insert(packet(sequence: 1, streamFrame: 3), arrivalTime: 3 * Self.frame)
        buffer.insert(packet(sequence: 2, streamFrame: 4), arrivalTime: 4 * Self.frame)
        buffer.insert(packet(sequence: 3, streamFrame: 5), arrivalTime: 5 * Self.frame)

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
        let buffer = JitterBuffer(config: Self.frameCountConfig)
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
        let buffer = JitterBuffer(config: Self.frameCountConfig)
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

    @Test("An underrun waits instead of skipping, then grows the cushion to the target")
    func underrunWaitsForLateFrame() {
        let buffer = JitterBuffer(config: Self.frameCountConfig)
        insert(buffer, sequences: 0, 1, 2, 3)
        for _ in 0..<4 { _ = buffer.pop() }

        // Empty: playout waits (conceals) without consuming sequence 4.
        #expect(buffer.pop() == .underrun)
        #expect(buffer.pop() == .underrun)
        // 4 and 5 arrive late: still inside the same dropout, playout keeps
        // concealing until the depth is back at the target (4 frames).
        insert(buffer, sequences: 4, 5)
        #expect(buffer.pop() == .underrun)
        insert(buffer, sequences: 6, 7)
        #expect(buffer.pop() == .packet(packet(sequence: 4, streamFrame: 4)))
        #expect(buffer.pop() == .packet(packet(sequence: 5, streamFrame: 5)))

        let stats = buffer.stats
        #expect(stats.underruns == 1)  // one event …
        #expect(stats.underrunFrames == 2)  // … of two empty slots
        #expect(stats.waitFrames == 1)  // … plus one slot growing the cushion
        #expect(stats.lost == 0)
        #expect(stats.late == 0)
    }

    @Test("A missing frame below the target depth waits; at the target it is lost")
    func missingFrameWaitsBelowTarget() {
        let buffer = JitterBuffer(config: Self.frameCountConfig)
        insert(buffer, sequences: 0, 1, 2, 3)
        _ = buffer.pop()  // 0; depth 3 < target 4
        _ = buffer.pop()  // 1
        insert(buffer, sequences: 4)
        _ = buffer.pop()  // 2
        _ = buffer.pop()  // 3; buffered: 4
        // 4 is there; then 5 is missing with only 6 buffered: wait.
        insert(buffer, sequences: 6)
        #expect(buffer.pop() == .packet(packet(sequence: 4, streamFrame: 4)))
        #expect(buffer.pop() == .underrun)
        // 5 arrives late but before its (delayed) slot: it plays.
        insert(buffer, sequences: 5, 7, 8, 9)
        #expect(buffer.pop() == .packet(packet(sequence: 5, streamFrame: 5)))
        // Now 10 never arrives while the depth is at the target: lost.
        insert(buffer, sequences: 11, 12, 13, 14)
        for expected in 6...9 {
            #expect(buffer.pop() == .packet(packet(sequence: UInt32(expected), streamFrame: UInt64(expected))))
        }
        #expect(buffer.pop() == .lost(sequence: 10))
        #expect(buffer.stats.lost == 1)
    }

    @Test("A sustained stall returns the buffer to buffering")
    func sustainedStallReturnsToBuffering() {
        let buffer = JitterBuffer(config: Self.frameCountConfig)
        insert(buffer, sequences: 0, 1, 2, 3)
        for _ in 0..<4 { _ = buffer.pop() }

        // maxTargetFrames (8) empty pops, then prebuffering.
        for _ in 0..<8 {
            #expect(buffer.pop() == .underrun)
        }
        let stats = buffer.stats
        #expect(stats.underruns == 1)
        #expect(stats.underrunFrames == 8)
        #expect(stats.rebuffers == 1)
        #expect(stats.bufferingPops == 0)

        #expect(buffer.pop() == .buffering)
        #expect(buffer.stats.bufferingPops == 1)

        insert(buffer, sequences: 20, 21, 22, 23)
        #expect(buffer.pop() == .packet(packet(sequence: 20, streamFrame: 20)))
    }

    // MARK: - Redundancy

    private func redundantCopy(_ sequence: UInt32) -> AudioPacket {
        var copy = packet(sequence: sequence, streamFrame: UInt64(sequence))
        copy.isRedundant = true
        return copy
    }

    @Test("A redundant copy fills a lost primary and counts as recovered, not duplicate")
    func redundantCopyRecoversLoss() {
        let buffer = JitterBuffer(config: Self.frameCountConfig)
        // Primary 2 is lost; its copy rides with frame 5 (offset 3).
        insert(buffer, sequences: 0, 1, 3, 4, 5)
        buffer.insert(redundantCopy(2), arrivalTime: 5 * Self.frame)
        // Copies of frames whose primary arrived are ignored quietly.
        buffer.insert(redundantCopy(1), arrivalTime: 4 * Self.frame)

        var outputs: [JitterBufferOutput] = []
        for _ in 0..<6 { outputs.append(buffer.pop()) }
        #expect(outputs == packets([0, 1, 2, 3, 4, 5]))
        let stats = buffer.stats
        #expect(stats.recovered == 1)
        #expect(stats.lost == 0)
        #expect(stats.duplicates == 0)
        #expect(stats.received == 5)
        #expect(stats.redundantReceived == 2)
    }

    @Test("A late primary supersedes its copy; repeated primaries are still duplicates")
    func latePrimarySupersedesCopy() {
        let buffer = JitterBuffer(config: Self.frameCountConfig)
        insert(buffer, sequences: 0, 1)
        buffer.insert(redundantCopy(2), arrivalTime: 2 * Self.frame)
        insert(buffer, sequences: 2, 3)  // the primary arrives after all
        insert(buffer, sequence: 3, streamFrame: 3)  // network duplicate
        for _ in 0..<4 { _ = buffer.pop() }
        let stats = buffer.stats
        #expect(stats.recovered == 0)
        #expect(stats.duplicates == 1)
        #expect(stats.played == 4)
    }

    @Test("A copy arriving after its slot is redundantLate, not late")
    func lateCopyIsCountedSeparately() {
        let buffer = JitterBuffer(config: Self.frameCountConfig)
        insert(buffer, sequences: 0, 1, 2, 3)
        _ = buffer.pop()
        buffer.insert(redundantCopy(0), arrivalTime: 3 * Self.frame)
        #expect(buffer.stats.redundantLate == 1)
        #expect(buffer.stats.late == 0)
    }

    @Test("Frames from before a discontinuity are rejected after the reset")
    func staleFramesAfterDiscontinuityAreRejected() {
        let buffer = JitterBuffer(config: Self.frameCountConfig)
        insert(buffer, sequence: 100, streamFrame: 100, flags: [.discontinuity])
        buffer.insert(redundantCopy(98), arrivalTime: 100 * Self.frame)
        insert(buffer, sequences: 99)
        #expect(buffer.stats.depthFrames == 1)
        #expect(buffer.stats.late == 1)
        #expect(buffer.stats.redundantLate == 1)
    }

    // MARK: - Delay-percentile target estimator

    @Test("Delay-percentile target rises on a held burst and falls slowly")
    func delayPercentileTargetRisesAndFallsSlowly() {
        var config = JitterBufferConfig()
        config.minTargetFrames = 6  // 30 ms
        config.maxTargetFrames = 24  // 120 ms
        config.delayWindowSeconds = 1  // small window so it turns over quickly
        let buffer = JitterBuffer(config: config)
        let perSecond = Int(1 / Self.frame)  // 200

        // 2 s of on-time frames: zero relative delay, target stays at the
        // minimum. Pops lag inserts by 20 frames.
        for frame in 0..<(2 * perSecond) {
            insert(buffer, sequence: UInt32(frame), streamFrame: UInt64(frame))
            if frame >= 20 { _ = buffer.pop() }
        }
        #expect(buffer.stats.targetFrames == 6)

        // A burst: frames 400-415 (80 ms of audio) are held and land together
        // 80 ms after frame 400's send time (delays 80 ms down to 5 ms). The
        // p99 of the window is the 3rd largest (70-75 ms) → at least 16
        // frames, immediately.
        for frame in 400..<416 {
            buffer.insert(
                packet(sequence: UInt32(frame), streamFrame: UInt64(frame)),
                arrivalTime: 2.0 + 0.080
            )
        }
        #expect(buffer.stats.targetFrames >= 16)

        // 4 s of clean traffic: the burst has left the 1 s window, but the
        // 5 s hold keeps the target (it even rose a step while the burst
        // samples were a larger share of the thinning window).
        for frame in 520..<(520 + 4 * perSecond) {
            insert(buffer, sequence: UInt32(frame), streamFrame: UInt64(frame))
            _ = buffer.pop()
        }
        #expect(buffer.stats.targetFrames >= 16)

        // After the hold the target steps down one frame (5 ms) per second:
        // 8 more seconds cannot reach the floor (that needs 12 s of falls).
        for frame in 1320..<(1320 + 8 * perSecond) {
            insert(buffer, sequence: UInt32(frame), streamFrame: UInt64(frame))
            _ = buffer.pop()
        }
        let settled = buffer.stats.targetFrames
        #expect(settled > 6)
        #expect(settled <= 14)
    }

    @Test("Balanced covers the largest delay of the window, not its p99")
    func balancedCoversTheMaximum() {
        let buffer = JitterBuffer(config: .latency(.balanced))
        // 10 s on time, with one 150 ms hold at t = 5 s.
        for frame in 0..<2000 {
            let send = TimeInterval(frame) * Self.frame
            let arrival = (5.0..<5.15).contains(send) ? 5.15 : send
            buffer.insert(packet(sequence: UInt32(frame), streamFrame: UInt64(frame)), arrivalTime: arrival)
        }
        // (150 + 10) / 5 = 32 frames = 160 ms.
        #expect(buffer.stats.targetFrames == 32)
    }

    @Test("An outage is not jitter: it does not pin the target")
    func outageDoesNotPinTarget() {
        let buffer = JitterBuffer(config: .latency(.balanced))
        for frame in 0..<1000 {
            let send = TimeInterval(frame) * Self.frame
            // 3 s outage: frames 200-799 are delivered together at t = 4 s.
            let arrival = (1.0..<4.0).contains(send) ? 4.0 : send
            buffer.insert(packet(sequence: UInt32(frame), streamFrame: UInt64(frame)), arrivalTime: arrival)
        }
        // Only delays up to the 1 s outage threshold are recorded: the
        // target is far from the 300 ms mode ceiling.
        #expect(buffer.stats.targetFrames < JitterBufferConfig.latency(.balanced).maxTargetFrames)
    }

    @Test("Cushion anchors at the fastest observed path, not the first packet")
    func cushionAnchorsAtFastestPath() {
        var config = JitterBufferConfig()
        config.minTargetFrames = 3
        config.maxTargetFrames = 12
        let buffer = JitterBuffer(config: config)

        // Fresh packets 4 and 5 arrive first (fast path, offset ~1 ms); the
        // delayed batch (frames 0-3, offsets 55-41.5 ms) lands after them,
        // then frame 6 arrives on the fast path again.
        buffer.insert(packet(sequence: 4, streamFrame: 4), arrivalTime: 0.0205)
        buffer.insert(packet(sequence: 5, streamFrame: 5), arrivalTime: 0.0255)
        buffer.insert(packet(sequence: 0, streamFrame: 0), arrivalTime: 0.055)
        buffer.insert(packet(sequence: 1, streamFrame: 1), arrivalTime: 0.0555)
        buffer.insert(packet(sequence: 2, streamFrame: 2), arrivalTime: 0.056)
        buffer.insert(packet(sequence: 3, streamFrame: 3), arrivalTime: 0.0565)
        buffer.insert(packet(sequence: 6, streamFrame: 6), arrivalTime: 0.0575)

        // The burst pushes the p99 to ~54.5 ms → target 12; the cushion is
        // anchored at the fast path (0.5 ms), so at frame 6's insert it is
        // 57 ms ≥ (12 - 1) × 5 ms and playback may start from the oldest
        // buffered frame — at depth 7 < 12, i.e. via the cushion exit, which
        // an anchor at the first observed packet would miss.
        #expect(buffer.stats.targetFrames == 12)
        #expect(buffer.pop() == .packet(packet(sequence: 0, streamFrame: 0)))
    }

    // MARK: - Latency trim

    @Test("Surplus depth above target + slack is trimmed one frame per half second")
    func surplusDepthIsTrimmed() {
        var config = JitterBufferConfig()
        config.minTargetFrames = 3
        config.maxTargetFrames = 12
        let buffer = JitterBuffer(config: config)

        // On-time arrivals (target stays at 3) but playout started 15 frames
        // behind — the depth a decayed transient leaves behind. The default
        // slack is 4 frames (20 ms).
        var lastPlayed: UInt32?
        var inOrder = true
        var trimmedAfter5s = 0
        for frame in 0..<2000 {
            insert(buffer, sequence: UInt32(frame), streamFrame: UInt64(frame))
            guard frame >= 15 else { continue }
            if case .packet(let packet) = buffer.pop() {
                if let lastPlayed, !sequenceIsAfter(packet.sequence, lastPlayed) { inOrder = false }
                lastPlayed = packet.sequence
            }
            if frame == 15 + 500 { trimmedAfter5s = buffer.stats.trimmed }  // 2.5 s
        }
        let stats = buffer.stats
        #expect(inOrder)
        #expect(stats.targetFrames == 3)
        // Rate limit: at most one 5 ms frame per 0.5 s of playout (10 ms/s).
        #expect(trimmedAfter5s <= 5)
        // Converged: peak depth within target + slack, nothing lost or late.
        #expect(stats.depthFrames <= 3 + 4)
        #expect(stats.trimmed >= 8)
        #expect(stats.lost == 0)
        #expect(stats.late == 0)
    }

    @Test("Depth within target + slack is never trimmed")
    func depthWithinSlackIsNotTrimmed() {
        var config = JitterBufferConfig()
        config.minTargetFrames = 3
        config.maxTargetFrames = 12
        let buffer = JitterBuffer(config: config)
        for frame in 0..<1000 {
            insert(buffer, sequence: UInt32(frame), streamFrame: UInt64(frame))
            if frame >= 4 { _ = buffer.pop() }
        }
        #expect(buffer.stats.trimmed == 0)
    }

    @Test("applyConfig resets buffered audio and applies the new range immediately")
    func applyConfigResetsAndApplies() {
        let buffer = JitterBuffer(config: .latency(.balanced))
        insert(buffer, sequences: 0, 1, 2, 3, 4, 5, 6)
        #expect(buffer.stats.depthFrames == 7)
        #expect(buffer.stats.targetFrames == 6)

        buffer.applyConfig(.latency(.low))

        let stats = buffer.stats
        #expect(stats.depthFrames == 0)
        #expect(stats.targetFrames == 4)
        #expect(buffer.pop() == .buffering)
    }
}
