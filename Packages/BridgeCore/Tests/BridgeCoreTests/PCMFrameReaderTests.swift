import Testing
import Foundation
@testable import BridgeCore

// MARK: - Shared helpers

/// Interleaved samples per 5 ms playout slot (240 frames × 2 channels).
let readerSlotSamples = AudioFormat.samplesPerFrame * AudioFormat.channelCount

/// Little-endian Int16 payload bytes for interleaved `samples`.
func pcm16Payload(_ samples: [Int16]) -> Data {
    var data = Data(capacity: samples.count * 2)
    for value in samples {
        let bits = UInt16(bitPattern: value).littleEndian
        data.append(UInt8(bits & 0xFF))
        data.append(UInt8(bits >> 8))
    }
    return data
}

/// Interleaved stereo Int16 sine for slot `slot` (sample-time continuous),
/// both channels equal.
func sineSlot(_ slot: Int, frequency: Double, amplitude: Double = 0.5) -> [Int16] {
    var samples = [Int16](repeating: 0, count: readerSlotSamples)
    for frame in 0..<AudioFormat.samplesPerFrame {
        let n = Double(slot * AudioFormat.samplesPerFrame + frame)
        let value = Int16((amplitude * sin(2 * Double.pi * frequency * n / AudioFormat.sampleRate) * 32767).rounded())
        samples[2 * frame] = value
        samples[2 * frame + 1] = value
    }
    return samples
}

/// Largest sample-to-sample step on either channel of interleaved `output`.
func maxStep(_ output: [Float]) -> Float {
    var worst: Float = 0
    var index = 2
    while index < output.count {
        worst = max(worst, abs(output[index] - output[index - 2]))
        index += 1
    }
    return worst
}

/// Largest step of the pure sine itself (amplitude × 2 sin(π f / fs)).
func sineMaxStep(frequency: Double, amplitude: Double = 0.5) -> Float {
    Float(amplitude * 2 * sin(Double.pi * frequency / AudioFormat.sampleRate))
}

/// Scripted playout slots for a reader under test.
enum ScriptedSlot {
    case frame(UInt32, [Int16], skipped: [Int16]? = nil)
    case lost
    case underrun
    case buffering
}

/// Serves scripted slots like the jitter buffer's realtime pop, then
/// `.buffering` forever. Single-threaded tests only.
final class ScriptedSource: @unchecked Sendable {
    private var slots: [ScriptedSlot]
    private var index = 0

    init(_ slots: [ScriptedSlot]) {
        self.slots = slots
    }

    var consumed: Int { index }

    func next(_ payload: UnsafeMutableRawBufferPointer, _ skipped: UnsafeMutableRawBufferPointer) -> PlayoutSlot {
        guard index < slots.count else { return .buffering }
        defer { index += 1 }
        switch slots[index] {
        case .frame(let sequence, let samples, let skippedSamples):
            let bytes = pcm16Payload(samples)
            bytes.copyBytes(to: payload)
            var skippedCount = 0
            if let skippedSamples {
                let skippedBytes = pcm16Payload(skippedSamples)
                skippedBytes.copyBytes(to: skipped)
                skippedCount = skippedBytes.count
            }
            return .frame(
                PlayoutFrame(
                    sequence: sequence,
                    sampleTime: UInt64(sequence) * UInt64(AudioFormat.samplesPerFrame),
                    codec: .pcm16, flags: [], byteCount: bytes.count,
                    skippedByteCount: skippedCount, recovered: false))
        case .lost:
            return .lost(sequence: 0)
        case .underrun:
            return .underrun
        case .buffering:
            return .buffering
        }
    }
}

func makeReader(_ source: ScriptedSource) -> PCMFrameReader {
    PCMFrameReader(source: { payload, skipped in source.next(payload, skipped) })
}

/// Reads `slots` whole slots from `reader` in render quanta of `quantum`
/// interleaved samples.
func render(_ reader: PCMFrameReader, slots: Int, quantum: Int = 2 * 256) -> [Float] {
    let total = slots * readerSlotSamples
    var output = [Float](repeating: .nan, count: total)
    output.withUnsafeMutableBufferPointer { buffer in
        var offset = 0
        while offset < total {
            let chunk = min(quantum, total - offset)
            reader.read(into: buffer.baseAddress! + offset, sampleCount: chunk)
            offset += chunk
        }
    }
    return output
}

func floats(_ samples: [Int16]) -> [Float] {
    samples.map { Float($0) / 32768 }
}

func rms(_ values: ArraySlice<Float>) -> Float {
    guard !values.isEmpty else { return 0 }
    return sqrt(values.reduce(0) { $0 + $1 * $1 } / Float(values.count))
}

// MARK: - Tests

struct PCMFrameReaderTests {
    private func slot(_ output: [Float], _ index: Int) -> ArraySlice<Float> {
        output[(index * readerSlotSamples)..<((index + 1) * readerSlotSamples)]
    }

    @Test(
        "Contiguous frames play bit-exact after the initial fade-in, for any render quantum",
        arguments: [2 * 64, 2 * 256, 2 * 341, 2 * 1024]
    )
    func contiguousFramesAreExact(quantum: Int) {
        let frames = (0..<12).map { sineSlot($0, frequency: 1000) }
        let reader = makeReader(ScriptedSource(frames.enumerated().map { .frame(UInt32($0.offset), $0.element) }))
        let output = render(reader, slots: 12, quantum: quantum)
        for index in 1..<12 {
            #expect(Array(slot(output, index)) == floats(frames[index]))
        }
        // The first slot fades in from silence instead of starting at full level.
        #expect(abs(output[0]) < 0.001)
        #expect(maxStep(output) <= sineMaxStep(frequency: 1000) * 1.05)
    }

    @Test("Partial reads expose the unplayed remainder of the frame")
    func partialReadsExposeRemainder() {
        let reader = makeReader(ScriptedSource([.frame(0, sineSlot(0, frequency: 1000))]))
        var buffer = [Float](repeating: 0, count: readerSlotSamples / 4)
        buffer.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, sampleCount: $0.count) }
        #expect(abs(reader.partiallyPlayedFrames - 0.75) < 1e-9)
    }

    @Test("A single lost slot is concealed at full level, continuously")
    func singleLossIsConcealedAtFullLevel() {
        var script: [ScriptedSlot] = (0..<10).map { .frame(UInt32($0), sineSlot($0, frequency: 1000)) }
        script.append(.lost)
        script += (11..<20).map { .frame(UInt32($0), sineSlot($0, frequency: 1000)) }
        let reader = makeReader(ScriptedSource(script))
        let output = render(reader, slots: 20)
        let sineRMS = Float(0.5 / 2.0.squareRoot())
        #expect(rms(slot(output, 10)) > 0.9 * sineRMS)
        #expect(maxStep(Array(output[readerSlotSamples...])) <= sineMaxStep(frequency: 1000) * 1.2)
        let stats = reader.stats
        #expect(stats.concealedFrames == 1)
        #expect(stats.concealments == 1)
        #expect(stats.fadeIns == 1)
        #expect(stats.fadeOuts == 0)
    }

    @Test("A long underrun fades out to exact silence and fades back in without a step")
    func longUnderrunFadesOutAndIn() {
        var script: [ScriptedSlot] = (0..<20).map { .frame(UInt32($0), sineSlot($0, frequency: 440)) }
        script += Array(repeating: .underrun, count: 40)  // 200 ms
        script += (20..<40).map { .frame(UInt32($0), sineSlot($0, frequency: 440)) }
        let reader = makeReader(ScriptedSource(script))
        let output = render(reader, slots: 80)
        // 50 ms of concealment (hold + decay) = 10 slots, then true silence.
        for index in 31..<60 {
            #expect(slot(output, index).allSatisfy { $0 == 0 })
        }
        // Concealment is audible right after the gap starts (no hard hole).
        #expect(rms(slot(output, 20)) > 0.25)
        #expect(maxStep(Array(output[readerSlotSamples...])) <= sineMaxStep(frequency: 440) * 1.3)
        let stats = reader.stats
        #expect(stats.fadeOuts == 1)
        #expect(stats.fadeIns == 1)
        #expect(stats.concealedFrames == 40)
    }

    @Test("Buffering before the first frame is silence and nothing is counted")
    func initialBufferingIsSilence() {
        let reader = makeReader(ScriptedSource([.buffering, .buffering, .frame(0, sineSlot(0, frequency: 1000))]))
        let output = render(reader, slots: 3)
        #expect(output[0..<(2 * readerSlotSamples)].allSatisfy { $0 == 0 })
        #expect(reader.stats == ConcealmentStats())
    }

    @Test("A trimmed frame is crossfaded into its successor across the slot")
    func trimIsCrossfaded() {
        // 440 Hz: the skipped frame and its successor are out of phase, so a
        // hard splice would click.
        var script: [ScriptedSlot] = (0..<10).map { .frame(UInt32($0), sineSlot($0, frequency: 440)) }
        script.append(.frame(11, sineSlot(11, frequency: 440), skipped: sineSlot(10, frequency: 440)))
        script += (12..<20).map { .frame(UInt32($0), sineSlot($0, frequency: 440)) }
        let reader = makeReader(ScriptedSource(script))
        let output = render(reader, slots: 19)
        // Starts exactly like the skipped frame, ends exactly like frame 11.
        let crossfaded = Array(slot(output, 10))
        let skipped = floats(sineSlot(10, frequency: 440))
        let next = floats(sineSlot(11, frequency: 440))
        #expect(abs(crossfaded[0] - skipped[0]) < 1e-3)
        #expect(abs(crossfaded[readerSlotSamples - 1] - next[readerSlotSamples - 1]) < 1e-3)
        #expect(Array(slot(output, 11)) == floats(sineSlot(12, frequency: 440)))
        #expect(maxStep(Array(output[readerSlotSamples...])) <= sineMaxStep(frequency: 440) * 1.2)
        #expect(reader.stats.crossfades == 1)
    }

    @Test("A jump without the skipped frame (overflow resync) is crossfaded too")
    func jumpIsCrossfaded() {
        var script: [ScriptedSlot] = (0..<10).map { .frame(UInt32($0), sineSlot($0, frequency: 440)) }
        script += (17..<27).map { .frame(UInt32($0), sineSlot($0, frequency: 440)) }
        let reader = makeReader(ScriptedSource(script))
        let output = render(reader, slots: 20)
        #expect(maxStep(Array(output[readerSlotSamples...])) <= sineMaxStep(frequency: 440) * 1.3)
        #expect(reader.stats.crossfades == 1)
    }

    @Test("Reset returns to silence: the next frame fades in")
    func resetFadesInAgain() {
        let source = ScriptedSource((0..<4).map { .frame(UInt32($0), sineSlot($0, frequency: 1000)) })
        let reader = makeReader(source)
        _ = render(reader, slots: 2)
        reader.reset()
        let output = render(reader, slots: 2)
        #expect(abs(output[0]) < 0.001)
        #expect(Array(slot(output, 1)) == floats(sineSlot(3, frequency: 1000)))
    }
}
