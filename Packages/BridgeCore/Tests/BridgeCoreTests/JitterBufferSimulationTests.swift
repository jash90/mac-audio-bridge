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

private struct SimulationReport {
    /// Stats after the final pop.
    let final: JitterBufferStats
    /// Stats snapshot at the end of the warm-up window.
    let atWarmUp: JitterBufferStats
    /// Stats snapshot one second after the jitter step (equal to `atWarmUp`
    /// when the scenario has no step).
    let atGrace: JitterBufferStats
    let framesSent: Int
    /// First frame index inside the post-warm-up measurement window.
    let warmUpFrame: Int
    /// First frame index inside the post-step-grace measurement window.
    let graceFrame: Int
    /// Largest target sampled at any pop in the post-warm-up window.
    let maxTargetAfterWarmUp: Int
    let dropPercentAfterWarmUp: Double
}

/// Deterministic simulation: the sender emits one frame every 10 ms; every
/// packet gets a uniform random delay in `0..<maxDelay` and is dropped with
/// probability `dropRate`; from `stepAt` on (if set) the delay bound becomes
/// `maxDelayAfterStep`. The playout clock pops every 10 ms from t = 0.
private func simulate(
    seed: UInt64,
    maxDelay: TimeInterval,
    dropRate: Double,
    duration: TimeInterval = 60,
    warmUp: TimeInterval = 2,
    stepAt: TimeInterval? = nil,
    maxDelayAfterStep: TimeInterval? = nil,
    grace: TimeInterval = 1
) -> SimulationReport {
    let frameDuration: TimeInterval = 0.010
    let totalFrames = Int(duration / frameDuration)  // 6000
    let warmUpFrame = Int(warmUp / frameDuration)
    let graceFrame = stepAt.map { Int(($0 + grace) / frameDuration) } ?? warmUpFrame
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
        let sendTime = TimeInterval(index) * frameDuration
        let delayBound = sendTime >= (stepAt ?? .infinity) ? (maxDelayAfterStep ?? maxDelay) : maxDelay
        let delay = rng.nextUniform(upTo: delayBound)
        if rng.nextBool(probability: dropRate) {
            if index >= warmUpFrame { droppedAfterWarmUp += 1 }
            continue
        }
        arrivals.append(Arrival(sequence: UInt32(index), time: sendTime + delay))
    }
    arrivals.sort()

    let payload = Data(
        repeating: 0x5A,
        count: AudioFormat.samplesPerFrame * AudioFormat.channelCount * 2  // PCM16 stereo
    )
    let buffer = JitterBuffer()
    var nextArrivalIndex = 0
    var atWarmUp = JitterBufferStats()
    var atGrace = JitterBufferStats()
    var maxTargetAfterWarmUp = 0
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
            atWarmUp = buffer.stats
        }
        if tick == graceFrame - 1, graceFrame != warmUpFrame {
            atGrace = buffer.stats
        }
        if tick >= warmUpFrame {
            maxTargetAfterWarmUp = max(maxTargetAfterWarmUp, buffer.stats.targetFrames)
        }
    }

    // Global invariant regardless of the network: every played frame is
    // strictly newer than the previous one.
    #expect(playedInOrder)

    return SimulationReport(
        final: buffer.stats,
        atWarmUp: atWarmUp,
        atGrace: stepAt == nil ? atWarmUp : atGrace,
        framesSent: totalFrames,
        warmUpFrame: warmUpFrame,
        graceFrame: graceFrame,
        maxTargetAfterWarmUp: maxTargetAfterWarmUp,
        dropPercentAfterWarmUp: Double(droppedAfterWarmUp) / Double(totalFrames - warmUpFrame) * 100
    )
}

// MARK: - Tests

struct JitterBufferSimulationTests {
    @Test("60 s of 0-60 ms jitter and 5% loss meets the acceptance numbers")
    func heavyJitterMeetsAcceptance() {
        let report = simulate(seed: 0x5EED_C0FF_EE01, maxDelay: 0.060, dropRate: 0.05)
        let frames = report.framesSent - report.warmUpFrame
        let latePercent = Double(report.final.late - report.atWarmUp.late) / Double(frames) * 100
        let lostPercent = Double(report.final.lost - report.atWarmUp.lost) / Double(frames) * 100
        let rebuffers = report.final.rebuffers - report.atWarmUp.rebuffers
        let bufferingPops = report.final.bufferingPops - report.atWarmUp.bufferingPops

        print(
            "simulation[heavy]: late=\(report.final.late - report.atWarmUp.late) "
                + "(\(String(format: "%.3f", latePercent))%), "
                + "underruns=\(report.final.underruns - report.atWarmUp.underruns), "
                + "maxTarget=\(report.maxTargetAfterWarmUp), "
                + "lost=\(report.final.lost - report.atWarmUp.lost) "
                + "(\(String(format: "%.2f", lostPercent))%), "
                + "simulatedDrop=\(String(format: "%.2f", report.dropPercentAfterWarmUp))%, "
                + "rebuffers(after warm-up)=\(rebuffers), "
                + "bufferingPops(after warm-up)=\(bufferingPops), "
                + "finalTarget=\(report.final.targetFrames), "
                + "jitter=\(String(format: "%.4f", report.final.jitterSeconds)) s"
        )

        #expect(latePercent <= 0.5)
        #expect(report.final.underruns - report.atWarmUp.underruns == 0)
        #expect(report.maxTargetAfterWarmUp <= JitterBufferConfig().maxTargetFrames)
        #expect(abs(lostPercent - report.dropPercentAfterWarmUp) <= 1.0)
        // Once adapted, the steady state neither rebuffers nor stalls.
        #expect(rebuffers == 0)
        #expect(bufferingPops == 0)
    }

    @Test("0-10 ms jitter settles at the minimum target")
    func lightJitterSettlesAtMinimumTarget() {
        let report = simulate(seed: 0x5EED_C0FF_EE02, maxDelay: 0.010, dropRate: 0.05)
        let minTarget = JitterBufferConfig().minTargetFrames

        print(
            "simulation[light]: finalTarget=\(report.final.targetFrames), "
                + "maxTarget=\(report.maxTargetAfterWarmUp), "
                + "underruns=\(report.final.underruns), "
                + "late=\(report.final.late), "
                + "rebuffers=\(report.final.rebuffers), "
                + "bufferingPops=\(report.final.bufferingPops)"
        )

        #expect(report.final.targetFrames == minTarget)
        #expect(report.maxTargetAfterWarmUp == minTarget)
        #expect(report.final.underruns == 0)
        #expect(report.final.rebuffers == 0)
        #expect(report.final.bufferingPops == 0)
    }

    @Test("Jitter step from 0-10 ms to 0-60 ms rebuilds the cushion cheaply")
    func jitterStepRebuildsCushionCheaply() {
        // 20 s of light jitter, then 40 s of heavy jitter from the step on.
        let report = simulate(
            seed: 0x5EED_C0FF_EE03,
            maxDelay: 0.010,
            dropRate: 0.05,
            stepAt: 20,
            maxDelayAfterStep: 0.060
        )
        let framesAfterGrace = report.framesSent - report.graceFrame
        let lateAfterGrace = report.final.late - report.atGrace.late
        let latePercent = Double(lateAfterGrace) / Double(framesAfterGrace) * 100

        print(
            "simulation[step]: rebuffers=\(report.final.rebuffers), "
                + "bufferingPops=\(report.final.bufferingPops), "
                + "late(after grace)=\(lateAfterGrace) (\(String(format: "%.3f", latePercent))%), "
                + "underruns=\(report.final.underruns), "
                + "finalTarget=\(report.final.targetFrames), "
                + "finalJitter=\(String(format: "%.4f", report.final.jitterSeconds)) s"
        )

        // The whole transition costs at most two rebuilds and 80 ms of gap.
        #expect(report.final.rebuffers <= 2)
        #expect(report.final.bufferingPops <= 8)
        // One second after the step the new cushion is in place: lates stay
        // within one percent of the frames sent in the measured window.
        #expect(latePercent <= 1.0)
    }
}
