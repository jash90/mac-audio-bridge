import Testing
import Foundation
@testable import BridgeCore

// MARK: - Deterministic RNG

/// SplitMix64: a small, fast, fully deterministic PRNG. The whole simulation
/// is a pure function of the seed.
private struct SplitMix64 {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform double in `0..<bound`.
    mutating func nextUniform(upTo bound: Double) -> Double {
        Double(next() >> 11) * 0x1.0p-53 * bound
    }

    /// True with probability `p`.
    mutating func nextBool(probability p: Double) -> Bool {
        nextUniform(upTo: 1.0) < p
    }
}

// MARK: - Network simulation

private struct SimulationMetrics {
    var framesSentAfterWarmUp = 0
    var lateAfterWarmUp = 0
    var underrunsAfterWarmUp = 0
    var lostAfterWarmUp = 0
    var maxTargetAfterWarmUp = 0
    var finalTarget = 0
    var finalJitterSeconds = 0.0
    var simulatedDropPercent = 0.0
}

/// Deterministic simulation: the sender emits one frame every 10 ms; every
/// packet gets a uniform random delay in `0..<maxDelay` and is dropped with
/// probability `dropRate`; the playout clock pops every 10 ms from t = 0.
/// Metrics are the deltas accumulated after the `warmUp` prefix.
private func simulate(
    seed: UInt64,
    maxDelay: TimeInterval,
    dropRate: Double,
    duration: TimeInterval = 60,
    warmUp: TimeInterval = 2
) -> SimulationMetrics {
    let frameDuration: TimeInterval = 0.010
    let totalFrames = Int(duration / frameDuration)  // 6000
    let warmUpFrame = Int(warmUp / frameDuration)  // 200
    var rng = SplitMix64(seed: seed)

    struct Arrival: Comparable {
        let sequence: UInt32
        let time: TimeInterval

        static func < (lhs: Arrival, rhs: Arrival) -> Bool {
            (lhs.time, lhs.sequence) < (rhs.time, rhs.sequence)
        }
    }

    var arrivals: [Arrival] = []
    arrivals.reserveCapacity(totalFrames)
    var droppedAfterWarmUp = 0
    for index in 0..<totalFrames {
        let delay = rng.nextUniform(upTo: maxDelay)
        if rng.nextBool(probability: dropRate) {
            if index >= warmUpFrame { droppedAfterWarmUp += 1 }
            continue
        }
        arrivals.append(
            Arrival(sequence: UInt32(index), time: TimeInterval(index) * frameDuration + delay)
        )
    }
    arrivals.sort()

    let payload = Data(
        repeating: 0x5A,
        count: AudioFormat.samplesPerFrame * AudioFormat.channelCount * 2  // PCM16 stereo
    )
    let buffer = JitterBuffer()
    var nextArrivalIndex = 0
    var warmUpSnapshot = JitterBufferStats()
    var metrics = SimulationMetrics()
    var lastPlayed: UInt32?
    var playedInOrder = true

    for tick in 0..<totalFrames {
        let now = TimeInterval(tick) * frameDuration
        while nextArrivalIndex < arrivals.count, arrivals[nextArrivalIndex].time <= now {
            let arrival = arrivals[nextArrivalIndex]
            nextArrivalIndex += 1
            buffer.insert(
                AudioPacket(
                    codec: .pcm16,
                    sequence: arrival.sequence,
                    sampleTime: UInt64(arrival.sequence) * UInt64(AudioFormat.samplesPerFrame),
                    payload: payload
                ),
                arrivalTime: arrival.time
            )
        }

        switch buffer.pop() {
        case .packet(let packet):
            if let last = lastPlayed, !sequenceIsAfter(packet.sequence, last) {
                playedInOrder = false
            }
            lastPlayed = packet.sequence
        case .lost, .buffering:
            break
        }

        if tick == warmUpFrame - 1 {
            warmUpSnapshot = buffer.stats
        }
        if tick >= warmUpFrame {
            metrics.maxTargetAfterWarmUp = max(
                metrics.maxTargetAfterWarmUp,
                buffer.stats.targetFrames
            )
        }
    }

    let final = buffer.stats
    metrics.framesSentAfterWarmUp = totalFrames - warmUpFrame
    metrics.lateAfterWarmUp = final.late - warmUpSnapshot.late
    metrics.underrunsAfterWarmUp = final.underruns - warmUpSnapshot.underruns
    metrics.lostAfterWarmUp = final.lost - warmUpSnapshot.lost
    metrics.finalTarget = final.targetFrames
    metrics.finalJitterSeconds = final.jitterSeconds
    metrics.simulatedDropPercent =
        Double(droppedAfterWarmUp) / Double(metrics.framesSentAfterWarmUp) * 100

    // Global invariant regardless of the network: every played frame is
    // strictly newer than the previous one.
    #expect(playedInOrder)

    return metrics
}

// MARK: - Tests

struct JitterBufferSimulationTests {
    @Test("60 s of 0-60 ms jitter and 5% loss meets the acceptance numbers")
    func heavyJitterMeetsAcceptance() {
        let metrics = simulate(seed: 0x5EED_C0FF_EE01, maxDelay: 0.060, dropRate: 0.05)
        let latePercent = Double(metrics.lateAfterWarmUp) / Double(metrics.framesSentAfterWarmUp) * 100
        let lostPercent = Double(metrics.lostAfterWarmUp) / Double(metrics.framesSentAfterWarmUp) * 100

        print(
            "simulation[heavy]: late=\(metrics.lateAfterWarmUp) (\(String(format: "%.3f", latePercent))%), "
                + "underruns=\(metrics.underrunsAfterWarmUp), "
                + "maxTarget=\(metrics.maxTargetAfterWarmUp), "
                + "lost=\(metrics.lostAfterWarmUp) (\(String(format: "%.2f", lostPercent))%), "
                + "simulatedDrop=\(String(format: "%.2f", metrics.simulatedDropPercent))%, "
                + "finalTarget=\(metrics.finalTarget), "
                + "jitter=\(String(format: "%.4f", metrics.finalJitterSeconds)) s"
        )

        #expect(latePercent <= 0.5)
        #expect(metrics.underrunsAfterWarmUp == 0)
        #expect(metrics.maxTargetAfterWarmUp <= JitterBufferConfig().maxTargetFrames)
        #expect(abs(lostPercent - metrics.simulatedDropPercent) <= 1.0)
    }

    @Test("0-10 ms jitter settles at the minimum target")
    func lightJitterSettlesAtMinimumTarget() {
        let metrics = simulate(seed: 0x5EED_C0FF_EE02, maxDelay: 0.010, dropRate: 0.05)
        let minTarget = JitterBufferConfig().minTargetFrames

        print(
            "simulation[light]: finalTarget=\(metrics.finalTarget), "
                + "maxTarget=\(metrics.maxTargetAfterWarmUp), "
                + "underruns=\(metrics.underrunsAfterWarmUp), "
                + "late=\(metrics.lateAfterWarmUp)"
        )

        #expect(metrics.finalTarget == minTarget)
        #expect(metrics.maxTargetAfterWarmUp == minTarget)
        #expect(metrics.underrunsAfterWarmUp == 0)
    }
}
