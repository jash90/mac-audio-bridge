import Testing
import Foundation
@testable import BridgeCore

struct PCMFrameReaderTests {
    // MARK: - Helpers

    /// Interleaved samples per playout frame (480 frames × 2 channels).
    private static let samplesPerFrame =
        AudioFormat.samplesPerFrame * AudioFormat.channelCount

    /// Serves preset outputs one per call, then `.buffering` forever (like a
    /// live jitter buffer). `@unchecked Sendable` so it can back the
    /// `@Sendable` reader source; tests are single-threaded.
    private final class OutputSequence: @unchecked Sendable {
        private var outputs: [JitterBufferOutput]
        private var index = 0

        init(_ outputs: [JitterBufferOutput]) {
            self.outputs = outputs
        }

        var consumed: Int { index }

        func next() -> JitterBufferOutput {
            guard index < outputs.count else { return .buffering }
            defer { index += 1 }
            return outputs[index]
        }
    }

    /// Interleaved little-endian Int16 payload bytes for `samples`.
    private func payload(_ samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for value in samples {
            let littleEndianValue = UInt16(bitPattern: value).littleEndian
            withUnsafeBytes(of: littleEndianValue) { bytes in
                data.append(contentsOf: bytes)
            }
        }
        return data
    }

    /// A PCM16 packet whose payload decodes to `samples`.
    private func packet(sequence: UInt32, samples: [Int16]) -> AudioPacket {
        AudioPacket(
            codec: .pcm16,
            sequence: sequence,
            sampleTime: UInt64(sequence) * UInt64(AudioFormat.samplesPerFrame),
            payload: payload(samples))
    }

    /// Distinct, deterministic samples for frame `frameIndex`.
    private func ramp(_ frameIndex: Int) -> [Int16] {
        (0..<Self.samplesPerFrame).map { i in Int16(frameIndex * 100 + i) }
    }

    /// What the reader must produce for `samples` (Int16 LE → Float).
    private func floats(from samples: [Int16]) -> [Float] {
        samples.map { Float($0) / 32768 }
    }

    /// Reads exactly `sampleCount` samples from `reader`.
    private func read(_ reader: PCMFrameReader, sampleCount: Int) -> [Float] {
        var out = [Float](repeating: 0, count: sampleCount)
        out.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress.map { reader.read(into: $0, sampleCount: sampleCount) }
        }
        return out
    }

    // MARK: - Arbitrary-size reads and continuity

    @Test(
        "Reads of any size are sample-exact across frame boundaries",
        arguments: [1, 256, 480, 1000]
    )
    func readsOfAnySizeAreSampleExact(readFrames: Int) {
        let packets = (0..<5).map { packet(sequence: UInt32($0), samples: ramp($0)) }
        let expected = packets.flatMap { floats(from: ramp(Int($0.sequence))) }
        let sequence = OutputSequence(packets.map { .packet($0) })
        let reader = PCMFrameReader(source: sequence.next)

        var got: [Float] = []
        while got.count < expected.count {
            got.append(contentsOf: read(reader, sampleCount: readFrames * 2))
        }

        #expect(Array(got.prefix(expected.count)) == expected)
        // Exactly one source pop per playout frame consumed.
        #expect(sequence.consumed == packets.count)
    }

    @Test("Partial reads expose the unplayed remainder of the frame")
    func partialReadReportsPendingFrames() {
        let reader = PCMFrameReader(
            source: OutputSequence([.packet(packet(sequence: 0, samples: ramp(0)))]).next)
        _ = read(reader, sampleCount: Self.samplesPerFrame / 2)

        #expect(reader.partiallyPlayedFrames == 0.5)

        _ = read(reader, sampleCount: Self.samplesPerFrame / 2)
        #expect(reader.partiallyPlayedFrames == 0)
    }

    // MARK: - Loss concealment

    @Test("A lost frame replays the last good frame with a linear fade")
    func lossReplaysLastGoodFrameWithFade() {
        let good = ramp(0)
        let sequence = OutputSequence([
            .packet(packet(sequence: 0, samples: good)),
            .lost(sequence: 1),
        ])
        let reader = PCMFrameReader(source: sequence.next)

        _ = read(reader, sampleCount: Self.samplesPerFrame)
        // Read the concealed frame in two halves to prove the fade continues
        // across read boundaries.
        let firstHalf = read(reader, sampleCount: Self.samplesPerFrame / 2)
        let secondHalf = read(reader, sampleCount: Self.samplesPerFrame / 2)
        let concealed = firstHalf + secondHalf

        let expected = floats(from: good).enumerated().map { index, value in
            value * (1 - Float(index) / Float(Self.samplesPerFrame))
        }
        #expect(concealed == expected)
    }

    @Test("A second consecutive loss is silence")
    func secondConsecutiveLossIsSilence() {
        let sequence = OutputSequence([
            .packet(packet(sequence: 0, samples: ramp(0))),
            .lost(sequence: 1),
            .lost(sequence: 2),
            .packet(packet(sequence: 3, samples: ramp(3))),
        ])
        let reader = PCMFrameReader(source: sequence.next)

        _ = read(reader, sampleCount: Self.samplesPerFrame)  // good frame
        _ = read(reader, sampleCount: Self.samplesPerFrame)  // faded replay
        let silence = read(reader, sampleCount: Self.samplesPerFrame)
        #expect(silence == Array(repeating: Float(0), count: Self.samplesPerFrame))

        let resumed = read(reader, sampleCount: Self.samplesPerFrame)
        #expect(resumed == floats(from: ramp(3)))
    }

    @Test("A loss with no last good frame is silence")
    func lossWithoutHistoryIsSilence() {
        let reader = PCMFrameReader(
            source: OutputSequence([.lost(sequence: 0)]).next)
        let out = read(reader, sampleCount: Self.samplesPerFrame)
        #expect(out == Array(repeating: Float(0), count: Self.samplesPerFrame))
    }

    @Test("Buffering outputs silence and does not arm concealment")
    func bufferingOutputsSilence() {
        let sequence = OutputSequence([
            .buffering,
            .lost(sequence: 0),
            .packet(packet(sequence: 1, samples: ramp(1))),
        ])
        let reader = PCMFrameReader(source: sequence.next)

        let silence = read(reader, sampleCount: Self.samplesPerFrame)
        #expect(silence == Array(repeating: Float(0), count: Self.samplesPerFrame))

        // No last good frame existed before the loss: still silence.
        let lost = read(reader, sampleCount: Self.samplesPerFrame)
        #expect(lost == Array(repeating: Float(0), count: Self.samplesPerFrame))

        let resumed = read(reader, sampleCount: Self.samplesPerFrame)
        #expect(resumed == floats(from: ramp(1)))
    }

    @Test("A skipped frame is spliced with a short ramp from the last output sample")
    func skippedFrameIsSpliced() {
        let first = ramp(0)
        let third = ramp(20)
        let sequence = OutputSequence([
            .packet(packet(sequence: 0, samples: first)),
            .packet(packet(sequence: 2, samples: third)),  // frame 1 trimmed
        ])
        let reader = PCMFrameReader(source: sequence.next)
        _ = read(reader, sampleCount: Self.samplesPerFrame)
        let spliced = read(reader, sampleCount: Self.samplesPerFrame)

        let decoded = floats(from: third)
        let lastLeft = Float(first[Self.samplesPerFrame - 2]) / 32768
        let rampSamples = PCMFrameReader.spliceRampFrames * 2
        // The first sample starts next to the previous output, then the ramp
        // converges monotonically onto the decoded audio.
        #expect(abs(spliced[0] - lastLeft) < abs(decoded[0] - lastLeft))
        #expect(Array(spliced[rampSamples...]) == Array(decoded[rampSamples...]))
    }

    @Test("Contiguous packets are not altered by the splice ramp")
    func contiguousPacketsAreUntouched() {
        let sequence = OutputSequence([
            .packet(packet(sequence: 7, samples: ramp(0))),
            .packet(packet(sequence: 8, samples: ramp(30))),
        ])
        let reader = PCMFrameReader(source: sequence.next)
        _ = read(reader, sampleCount: Self.samplesPerFrame)
        #expect(read(reader, sampleCount: Self.samplesPerFrame) == floats(from: ramp(30)))
    }

    @Test("Reset clears the concealment history")
    func resetClearsHistory() {
        let sequence = OutputSequence([
            .packet(packet(sequence: 0, samples: ramp(0))),
            .lost(sequence: 1),
        ])
        let reader = PCMFrameReader(source: sequence.next)

        _ = read(reader, sampleCount: Self.samplesPerFrame)
        reader.reset()

        let out = read(reader, sampleCount: Self.samplesPerFrame)
        #expect(out == Array(repeating: Float(0), count: Self.samplesPerFrame))
    }
}
