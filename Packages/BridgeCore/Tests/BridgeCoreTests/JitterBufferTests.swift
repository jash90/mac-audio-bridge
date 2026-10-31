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

    @Test("Stays in buffering until the depth reaches the target")
    func staysBufferingUntilDepthReachesTarget() {
        let buffer = JitterBuffer()
        insert(buffer, sequences: 0, 1, 2)
        #expect(buffer.pop() == .buffering)
        #expect(buffer.pop() == .buffering)
        #expect(buffer.stats.depthFrames == 3)

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

        // The sustained stall returned the buffer to prebuffering.
        #expect(buffer.pop() == .buffering)

        insert(buffer, sequences: 20, 21, 22, 23)
        #expect(buffer.pop() == .packet(packet(sequence: 20, streamFrame: 20)))
    }
}
