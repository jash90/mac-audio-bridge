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

/// One packet landing on the receiver: its sequence and arrival time.
private struct Arrival: Comparable {
    let sequence: UInt32
    let time: TimeInterval

    static func < (lhs: Arrival, rhs: Arrival) -> Bool {
        (lhs.time, lhs.sequence) < (rhs.time, rhs.sequence)
    }
}

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

/// Deterministic simulation: the sender emits one frame every 5 ms; every
/// packet gets a uniform random delay in `0..<maxDelay` and is dropped with
/// probability `dropRate`; from `stepAt` on (if set) the delay bound becomes
/// `maxDelayAfterStep`. The playout clock pops every 5 ms from t = 0.
private func simulate(
    seed: UInt64,
    maxDelay: TimeInterval,
    dropRate: Double,
    duration: TimeInterval = 60,
    warmUp: TimeInterval = 2,
    stepAt: TimeInterval? = nil,
    maxDelayAfterStep: TimeInterval? = nil,
    grace: TimeInterval = 1,
    config: JitterBufferConfig = JitterBufferConfig()
) -> SimulationReport {
    let frameDuration = AudioFormat.frameDuration
    let totalFrames = Int((duration / frameDuration).rounded())
    let warmUpFrame = Int((warmUp / frameDuration).rounded())
    let graceFrame = stepAt.map { Int((($0 + grace) / frameDuration).rounded()) } ?? warmUpFrame
    var rng = SplitMix64(seed: seed)

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

    return runStream(
        arrivals: arrivals,
        totalFrames: totalFrames,
        warmUpFrame: warmUpFrame,
        graceFrame: stepAt == nil ? nil : graceFrame,
        config: config,
        droppedAfterWarmUp: droppedAfterWarmUp
    )
}

/// Deterministic Wi-Fi power-save simulation: the sender emits one frame
/// every 5 ms with a 2-8 ms base delay; every 100 ms the AP holds the
/// packets of the last 100 ms window and releases them together after a
/// per-burst hold of 60-120 ms (a packet lands no earlier than its own
/// on-time arrival). 1% of packets is dropped. Runs `.balanced` by default.
private func simulateWiFiBurst(
    seed: UInt64,
    duration: TimeInterval = 60,
    warmUp: TimeInterval = 3,
    mode: JitterLatencyMode = .balanced
) -> SimulationReport {
    let frameDuration = AudioFormat.frameDuration
    let totalFrames = Int((duration / frameDuration).rounded())
    let warmUpFrame = Int((warmUp / frameDuration).rounded())
    let burstFrames = AudioFormat.frames(milliseconds: 100)  // one burst per 100 ms
    var rng = SplitMix64(seed: seed)

    var arrivals: [Arrival] = []
    arrivals.reserveCapacity(totalFrames)
    var droppedAfterWarmUp = 0
    var hold: TimeInterval = 0
    for index in 0..<totalFrames {
        if index % burstFrames == 0 {
            hold = 0.060 + rng.nextUniform(upTo: 0.060)  // 60-120 ms per burst
        }
        let sendTime = TimeInterval(index) * frameDuration
        let base = 0.002 + rng.nextUniform(upTo: 0.006)  // 2-8 ms
        if rng.nextBool(probability: 0.01) {
            if index >= warmUpFrame { droppedAfterWarmUp += 1 }
            continue
        }
        let release = TimeInterval(index - index % burstFrames) * frameDuration + hold
        arrivals.append(Arrival(sequence: UInt32(index), time: max(sendTime + base, release)))
    }
    arrivals.sort()

    return runStream(
        arrivals: arrivals,
        totalFrames: totalFrames,
        warmUpFrame: warmUpFrame,
        graceFrame: nil,
        config: .latency(mode),
        droppedAfterWarmUp: droppedAfterWarmUp
    )
}

/// Drives one jitter buffer over a precomputed arrival schedule: inserts
/// every packet whose arrival time has come, pops one playout slot per 5 ms
/// tick, and samples the statistics the acceptance thresholds need.
private func runStream(
    arrivals: [Arrival],
    totalFrames: Int,
    warmUpFrame: Int,
    graceFrame: Int?,
    config: JitterBufferConfig,
    droppedAfterWarmUp: Int
) -> SimulationReport {
    let frameDuration = AudioFormat.frameDuration
    let payload = Data(
        repeating: 0x5A,
        count: AudioFormat.pcm16FrameBytes
    )
    let buffer = JitterBuffer(config: config)
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
        case .lost, .underrun, .buffering:
            break
        }

        if tick == warmUpFrame - 1 {
            atWarmUp = buffer.stats
        }
        if let graceFrame, tick == graceFrame - 1, graceFrame != warmUpFrame {
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
        atGrace: graceFrame == nil ? atWarmUp : atGrace,
        framesSent: totalFrames,
        warmUpFrame: warmUpFrame,
        graceFrame: graceFrame ?? warmUpFrame,
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
                + "trimmed=\(report.final.trimmed), "
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
                + "waitFrames=\(report.final.waitFrames), underrunFrames=\(report.final.underrunFrames), "
                + "finalTarget=\(report.final.targetFrames), "
                + "finalJitter=\(String(format: "%.4f", report.final.jitterSeconds)) s"
        )

        // The transition needs no rebuild (the cushion grows by waiting) and
        // no silence gap; at most 80 ms of waiting in total.
        #expect(report.final.rebuffers == 0)
        #expect(report.final.bufferingPops == 0)
        #expect(report.final.underrunFrames + report.final.waitFrames <= AudioFormat.frames(milliseconds: 80))
        // One second after the step the new cushion is in place: lates stay
        // within one percent of the frames sent in the measured window.
        #expect(latePercent <= 1.0)
    }

    @Test("After a 0-200 ms transient calms down, target and real depth both return to the floor")
    func transientDecaysTargetAndDepth() {
        // 10 s of 0-200 ms jitter, then 120 s of 0-10 ms jitter, balanced
        // mode (its 45 s max window must expire before the decay starts).
        let report = simulate(
            seed: 0x5EED_C0FF_EE05,
            maxDelay: 0.200,
            dropRate: 0.01,
            duration: 130,
            stepAt: 10,
            maxDelayAfterStep: 0.010,
            config: .latency(.balanced)
        )
        let framesAfterGrace = report.framesSent - report.graceFrame
        let lateAfterGrace = report.final.late - report.atGrace.late
        let latePercent = Double(lateAfterGrace) / Double(framesAfterGrace) * 100

        print(
            "simulation[transient]: maxTarget=\(report.maxTargetAfterWarmUp), "
                + "finalTarget=\(report.final.targetFrames), "
                + "finalDepth=\(report.final.depthFrames), "
                + "trimmed=\(report.final.trimmed), "
                + "late(after grace)=\(lateAfterGrace) (\(String(format: "%.3f", latePercent))%)"
        )

        let floor = JitterBufferConfig.latency(.balanced).minTargetFrames
        #expect(report.maxTargetAfterWarmUp >= AudioFormat.frames(milliseconds: 180))  // the transient did raise it
        #expect(report.final.targetFrames == floor)
        // The latency itself follows: depth within target + trim slack.
        #expect(report.final.depthFrames <= floor + AudioFormat.frames(milliseconds: 20))
        #expect(latePercent <= 0.5)
    }

    @Test("Wi-Fi power-save bursts (100 ms batches, 60-120 ms holds) survive in balanced mode")
    func wiFiBurstDeliverySurvives() {
        let report = simulateWiFiBurst(seed: 0x5EED_C0FF_EE04)
        let frames = report.framesSent - report.warmUpFrame
        let latePercent = Double(report.final.late - report.atWarmUp.late) / Double(frames) * 100
        let underruns = report.final.underruns - report.atWarmUp.underruns
        let lostPercent = Double(report.final.lost - report.atWarmUp.lost) / Double(frames) * 100

        print(
            "simulation[burst]: late=\(report.final.late - report.atWarmUp.late) "
                + "(\(String(format: "%.3f", latePercent))%), "
                + "underruns=\(underruns), "
                + "maxTarget=\(report.maxTargetAfterWarmUp), "
                + "lost=\(report.final.lost - report.atWarmUp.lost) "
                + "(\(String(format: "%.2f", lostPercent))%), "
                + "simulatedDrop=\(String(format: "%.2f", report.dropPercentAfterWarmUp))%, "
                + "rebuffers(after warm-up)=\(report.final.rebuffers - report.atWarmUp.rebuffers), "
                + "bufferingPops(after warm-up)=\(report.final.bufferingPops - report.atWarmUp.bufferingPops), "
                + "finalTarget=\(report.final.targetFrames), "
                + "trimmed=\(report.final.trimmed), "
                + "jitter=\(String(format: "%.4f", report.final.jitterSeconds)) s"
        )

        // After the 3 s warm-up: essentially no packet misses its playout
        // slot, the buffer never drains, and the percentile target stays
        // well inside the balanced ceiling.
        #expect(latePercent <= 0.5)
        #expect(underruns <= 2)
        #expect(report.maxTargetAfterWarmUp <= JitterBufferConfig.latency(.balanced).maxTargetFrames)
    }
}
