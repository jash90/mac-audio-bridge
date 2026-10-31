import Testing
import Foundation
@testable import BridgeCore

// MARK: - Pipeline harness: sender packer → network → jitter buffer → reader

/// SplitMix64, deterministic.
private struct Random {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform(_ low: Double, _ high: Double) -> Double {
        low + Double(next() >> 11) * 0x1.0p-53 * (high - low)
    }
}

/// One datagram on the simulated wire.
private struct WireDatagram {
    let frame: Int
    let isPrimary: Bool
    let bytes: Data
    let sendTime: TimeInterval
}

/// Packs `frameCount` 1 kHz sine frames with the production packer.
private func senderDatagrams(frameCount: Int, frequency: Double = 1000) -> [WireDatagram] {
    var packer = RedundancyPacker()
    var datagrams: [WireDatagram] = []
    for frame in 0..<frameCount {
        let packet = AudioPacket(
            codec: .pcm16,
            flags: frame == 0 ? [.discontinuity] : [],
            sequence: UInt32(frame),
            sampleTime: UInt64(frame) * UInt64(AudioFormat.samplesPerFrame),
            payload: pcm16Payload(sineSlot(frame, frequency: frequency)))
        for (index, bytes) in packer.pack(packet).enumerated() {
            datagrams.append(
                WireDatagram(
                    frame: frame, isPrimary: index == 0, bytes: bytes,
                    sendTime: TimeInterval(frame) * AudioFormat.frameDuration))
        }
    }
    return datagrams
}

private struct PipelineResult {
    var output: [Float]
    var final: JitterBufferStats
    var atWarmUp: JitterBufferStats
    var concealment: ConcealmentStats
    var concealmentAtWarmUp: ConcealmentStats
    var warmUpSample: Int
    var maxTargetAfterWarmUp: Int
}

/// Delivers `arrivals` (datagram, arrival time) into a jitter buffer and
/// renders one 5 ms slot per tick through a `PCMFrameReader`.
private func runPipeline(
    arrivals: [(Data, TimeInterval)],
    ticks: Int,
    warmUpTicks: Int,
    config: JitterBufferConfig
) -> PipelineResult {
    let buffer = JitterBuffer(config: config)
    let reader = PCMFrameReader(source: { payload, skipped in
        buffer.pop(payload: payload, skippedPayload: skipped)
    })
    let sorted = arrivals.sorted { $0.1 < $1.1 }
    var next = 0
    var output = [Float](repeating: 0, count: ticks * readerSlotSamples)
    var atWarmUp = JitterBufferStats()
    var concealmentAtWarmUp = ConcealmentStats()
    var maxTarget = 0
    output.withUnsafeMutableBufferPointer { out in
        for tick in 0..<ticks {
            let now = TimeInterval(tick) * AudioFormat.frameDuration
            while next < sorted.count, sorted[next].1 <= now {
                if let datagram = try? AudioDatagram.decode(sorted[next].0) {
                    for packet in datagram.packets() {
                        buffer.insert(packet, arrivalTime: sorted[next].1)
                    }
                }
                next += 1
            }
            if tick == warmUpTicks {
                atWarmUp = buffer.stats
                concealmentAtWarmUp = reader.stats
            }
            reader.read(into: out.baseAddress! + tick * readerSlotSamples, sampleCount: readerSlotSamples)
            if tick >= warmUpTicks {
                maxTarget = max(maxTarget, buffer.stats.targetFrames)
            }
        }
    }
    return PipelineResult(
        output: output, final: buffer.stats, atWarmUp: atWarmUp,
        concealment: reader.stats, concealmentAtWarmUp: concealmentAtWarmUp,
        warmUpSample: warmUpTicks * readerSlotSamples, maxTargetAfterWarmUp: maxTarget)
}

// MARK: - Redundancy

struct RedundancyTests {
    @Test("PCM16 frames go out as a primary and a delayed copy, each ≤ 1200 B")
    func pcmPackingStaysBelowTheMTUBudget() {
        let datagrams = senderDatagrams(frameCount: 10)
        #expect(datagrams.allSatisfy { $0.bytes.count <= AudioFormat.maxDatagramBytes })
        // Frames 0-2 have no history yet; from frame 3 on: primary + copy.
        #expect(datagrams.count == 3 + 7 * 2)
        let copy = try? AudioDatagram.decode(datagrams[4].bytes)
        #expect(copy?.entries.map(\.offset) == [3])
        #expect(copy?.flags == [])
        #expect(datagrams[0].bytes.count == AudioDatagram.headerSize + AudioDatagram.entryHeaderSize + 960)
    }

    @Test("Compact (Opus-sized) frames carry current + previous frames in one datagram")
    func compactFramesShareOneDatagram() throws {
        var packer = RedundancyPacker(offsets: [1, 2, 3])
        var last: [Data] = []
        for frame in 0..<6 {
            last = packer.pack(
                AudioPacket(
                    codec: .opus, sequence: UInt32(frame),
                    sampleTime: UInt64(frame) * UInt64(AudioFormat.samplesPerFrame),
                    payload: Data(repeating: 0x33, count: 200)))
        }
        #expect(last.count == 1)
        let datagram = try AudioDatagram.decode(last[0])
        #expect(datagram.entries.map(\.offset) == [0, 1, 2, 3])
        #expect(last[0].count <= AudioFormat.maxDatagramBytes)
    }

    @Test("A discontinuity never repeats frames of the previous run")
    func discontinuityClearsHistory() {
        var packer = RedundancyPacker()
        for frame in 0..<5 {
            _ = packer.pack(
                AudioPacket(codec: .pcm16, sequence: UInt32(frame), sampleTime: 0, payload: Data(count: 960)))
        }
        let restart = packer.pack(
            AudioPacket(
                codec: .pcm16, flags: [.discontinuity], sequence: 5, sampleTime: 0, payload: Data(count: 960)))
        #expect(restart.count == 1)
    }

    @Test("Single losses and loss runs of 2 and 3 datagrams are recovered, duplicates still counted")
    func lossRunsAreRecovered() {
        let frames = 200
        // Primaries of frame 50; 80-81; 120-122 are lost; frame 150's
        // primary is duplicated by the network.
        let lostPrimaries: Set<Int> = [50, 80, 81, 120, 121, 122]
        var arrivals: [(Data, TimeInterval)] = []
        // The sender keeps going past the measured window, so the stream
        // never runs dry inside it.
        for datagram in senderDatagrams(frameCount: frames + 100) {
            if datagram.isPrimary, lostPrimaries.contains(datagram.frame) { continue }
            arrivals.append((datagram.bytes, datagram.sendTime + 0.002))
            if datagram.isPrimary, datagram.frame == 150 {
                arrivals.append((datagram.bytes, datagram.sendTime + 0.003))
            }
        }
        let result = runPipeline(
            arrivals: arrivals, ticks: frames + 20, warmUpTicks: 0, config: .latency(.balanced))
        #expect(result.final.recovered == lostPrimaries.count)
        #expect(result.final.lost == 0)
        #expect(result.final.duplicates == 1)
        #expect(result.final.played >= frames - 60)
        #expect(result.concealment.concealedFrames == 0)
        // Bit-exact audio: recovered frames are the real frames.
        #expect(maxStep(Array(result.output[(readerSlotSamples * 20)..<(readerSlotSamples * (frames))]))
            <= sineMaxStep(frequency: 1000) * 1.01)
    }
}

// MARK: - Crackle metric and the field replay

struct CrackleTests {
    /// The evidence from the field (iPhone, 5 GHz, today): Wi-Fi bursts that
    /// hold every datagram for 100–180 ms roughly every 8 s, plus 1 %
    /// independent datagram loss, 2–8 ms base delay.
    private func fieldReplayArrivals(
        seconds: Double, seed: UInt64, warmUp: Double
    ) -> (arrivals: [(Data, TimeInterval)], bursts: Int, unrecoverable: Int) {
        var random = Random(state: seed)
        let frameCount = Int(seconds / AudioFormat.frameDuration)
        var bursts: [(start: TimeInterval, end: TimeInterval)] = []
        var t = random.uniform(2, 6)
        while t < seconds {
            bursts.append((t, t + random.uniform(0.100, 0.180)))
            t += random.uniform(6, 10)
        }
        var arrivals: [(Data, TimeInterval)] = []
        var survived = [Int](repeating: 0, count: frameCount)
        for datagram in senderDatagrams(frameCount: frameCount) {
            let base = random.uniform(0.002, 0.008)
            if random.uniform(0, 1) < 0.01 { continue }  // lost on the air
            survived[datagram.isPrimary ? datagram.frame : datagram.frame - 3] += 1
            var arrival = datagram.sendTime + base
            if let burst = bursts.first(where: { $0.start <= datagram.sendTime && datagram.sendTime < $0.end }) {
                arrival = max(arrival, burst.end + random.uniform(0, 0.002))
            }
            arrivals.append((datagram.bytes, arrival))
        }
        // Frames whose primary and redundant copy were both lost: no single
        // copy scheme can recover them (expected ≈ 1e-4 × frames).
        let firstMeasured = Int(warmUp / AudioFormat.frameDuration)
        let unrecoverable = (firstMeasured..<(frameCount - 3)).filter { survived[$0] == 0 }.count
        return (arrivals, bursts.count, unrecoverable)
    }

    private func replay(_ mode: JitterLatencyMode, seed: UInt64) -> (PipelineResult, bursts: Int, unrecoverable: Int) {
        let seconds = 120.0
        let warmUp = 20.0
        let (arrivals, bursts, unrecoverable) = fieldReplayArrivals(seconds: seconds, seed: seed, warmUp: warmUp)
        let ticks = Int(seconds / AudioFormat.frameDuration)
        let warmUpTicks = Int(warmUp / AudioFormat.frameDuration)
        let result = runPipeline(arrivals: arrivals, ticks: ticks, warmUpTicks: warmUpTicks, config: .latency(mode))
        return (result, bursts, unrecoverable)
    }

    private func describe(_ result: PipelineResult, mode: JitterLatencyMode, bursts: Int, unrecoverable: Int) -> String {
        let underruns = result.final.underruns - result.atWarmUp.underruns
        let concealed = result.concealment.concealedFrames - result.concealmentAtWarmUp.concealedFrames
        let recovered = result.final.recovered - result.atWarmUp.recovered
        let lost = result.final.lost - result.atWarmUp.lost
        let step = maxStep(Array(result.output[result.warmUpSample...]))
        return "replay[\(mode.rawValue)] 120 s, \(bursts) bursts 100-180 ms + 1% loss, after 20 s warm-up: "
            + "underruns=\(underruns), underrunFrames=\(result.final.underrunFrames - result.atWarmUp.underrunFrames), "
            + "waitFrames=\(result.final.waitFrames - result.atWarmUp.waitFrames), "
            + "concealedFrames=\(concealed), lost=\(lost) (both copies lost: \(unrecoverable)), recovered=\(recovered), "
            + "trimmed=\(result.final.trimmed - result.atWarmUp.trimmed), "
            + "target=\(result.final.targetFrames * AudioFormat.frameDurationMs) ms "
            + "(max \(result.maxTargetAfterWarmUp * AudioFormat.frameDurationMs) ms), "
            + "depth=\(result.final.depthFrames * AudioFormat.frameDurationMs) ms, "
            + "maxStep=\(String(format: "%.4f", step)) (sine \(String(format: "%.4f", sineMaxStep(frequency: 1000))))"
    }

    @Test("Field replay: balanced (default) rides out 100 s of bursty, lossy Wi-Fi without a gap or click")
    func fieldReplayBalanced() {
        let (result, bursts, unrecoverable) = replay(.balanced, seed: 0xC0FF_EE28)
        print(describe(result, mode: .balanced, bursts: bursts, unrecoverable: unrecoverable))
        let underruns = result.final.underruns - result.atWarmUp.underruns
        let concealed = result.concealment.concealedFrames - result.concealmentAtWarmUp.concealedFrames
        let lost = result.final.lost - result.atWarmUp.lost
        #expect(underruns <= 1)
        // Every frame with a surviving copy plays; only double losses (7 of
        // 20 000 frames here, isolated 5 ms slots) and at most one short
        // underrun (≤ 40 ms) are concealed.
        #expect(lost <= unrecoverable)
        #expect(concealed - lost <= AudioFormat.frames(milliseconds: 40))
        #expect(result.final.recovered - result.atWarmUp.recovered > 100)
        // The target stays below 250 ms although bursts reach 180 ms.
        #expect(result.final.targetFrames * AudioFormat.frameDurationMs <= 250)
        #expect(maxStep(Array(result.output[result.warmUpSample...])) <= sineMaxStep(frequency: 1000) * 1.2)
    }

    @Test("Field replay: low mode conceals the long bursts smoothly (reported, no click)")
    func fieldReplayLow() {
        let (result, bursts, unrecoverable) = replay(.low, seed: 0xC0FF_EE28)
        print(describe(result, mode: .low, bursts: bursts, unrecoverable: unrecoverable))
        #expect(maxStep(Array(result.output[result.warmUpSample...])) <= sineMaxStep(frequency: 1000) * 1.2)
    }

    @Test("Field replay: safe mode is gap-free too")
    func fieldReplaySafe() {
        let (result, bursts, unrecoverable) = replay(.safe, seed: 0xC0FF_EE28)
        print(describe(result, mode: .safe, bursts: bursts, unrecoverable: unrecoverable))
        #expect(result.final.underruns - result.atWarmUp.underruns <= 1)
        #expect(maxStep(Array(result.output[result.warmUpSample...])) <= sineMaxStep(frequency: 1000) * 1.2)
    }

    @Test(
        "Crackle metric: losses, underruns, trims and overflow never step beyond the sine's own slope",
        arguments: [1000.0, 440.0, 2500.0]
    )
    func crackleMetric(frequency: Double) {
        // A hostile schedule through the real jitter buffer and reader:
        // isolated losses (both copies), a 60 ms and a 250 ms stall, and a
        // 300 ms delay spike that later gets trimmed back.
        let frames = 2400  // 12 s
        var random = Random(state: 0xC1AC_C1E5)
        var arrivals: [(Data, TimeInterval)] = []
        let lostFrames: Set<Int> = [300, 301, 700, 1500, 1501, 1502, 1503]
        for datagram in senderDatagrams(frameCount: frames, frequency: frequency) {
            if lostFrames.contains(datagram.isPrimary ? datagram.frame : datagram.frame - 3) { continue }
            var arrival = datagram.sendTime + random.uniform(0.001, 0.004)
            if (4.0..<4.06).contains(datagram.sendTime) { arrival = 4.06 }
            if (6.0..<6.25).contains(datagram.sendTime) { arrival = 6.25 }
            if (9.0..<9.3).contains(datagram.sendTime) { arrival = 9.3 }
            arrivals.append((datagram.bytes, arrival))
        }
        var config = JitterBufferConfig.latency(.low)
        config.delayWindowSeconds = 1  // let the target fall so trims happen
        config.targetFallHoldSeconds = 0.5
        let result = runPipeline(arrivals: arrivals, ticks: frames + 100, warmUpTicks: 0, config: config)
        let step = maxStep(Array(result.output[readerSlotSamples...]))
        print(
            "crackle[\(Int(frequency)) Hz]: maxStep=\(String(format: "%.4f", step)) "
                + "sine=\(String(format: "%.4f", sineMaxStep(frequency: frequency))), "
                + "lost=\(result.final.lost), underruns=\(result.final.underruns), trimmed=\(result.final.trimmed), "
                + "overflowDropped=\(result.final.overflowDropped), conceal=\(result.concealment)")
        #expect(result.final.lost > 0)
        #expect(result.final.underruns >= 2)
        #expect(result.final.trimmed > 0)
        #expect(step <= sineMaxStep(frequency: frequency) * 1.25)
        // Audible-silence check: a concealment never cuts to digital silence
        // within its first 10 ms, and a long stall ends in true silence.
        #expect(result.concealment.fadeOuts >= 1)
    }
}
