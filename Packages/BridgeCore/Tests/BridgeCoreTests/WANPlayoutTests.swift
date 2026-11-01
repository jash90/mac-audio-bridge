import Foundation
import Testing
@testable import BridgeCore

// MARK: - Harness: encoder → packer (per-frame profile) → network → JitterBuffer (retuned per profile) → reader

private let slotSamples = AudioFormat.samplesPerFrame * AudioFormat.channelCount

private func sine(frames: Int, frequency: Double = 1000, amplitude: Double = 0.5) -> [Float] {
    var signal = [Float](repeating: 0, count: frames * slotSamples)
    for n in 0..<(frames * AudioFormat.samplesPerFrame) {
        let value = Float(amplitude * sin(2 * Double.pi * frequency * Double(n) / AudioFormat.sampleRate))
        signal[2 * n] = value
        signal[2 * n + 1] = value
    }
    return signal
}

private struct Sent {
    let bytes: Data
    let sendTime: TimeInterval
    let profile: StreamProfile
}

/// Encodes `frames` frames, switching profile (and so layout and the WAN
/// quality cap) as `profile(frame)` says, the way the sender does: the
/// packer flushes the held frames before the switch.
private func send(
    _ signal: [Float], frames: Int, requested: StreamQuality, profile: (Int) -> StreamProfile
) -> [Sent] {
    let encoder = StreamFrameEncoder()
    var packer = RedundancyPacker()
    var sent: [Sent] = []
    signal.withUnsafeBufferPointer { samples in
        for frame in 0..<frames {
            let now = Double(frame) * AudioFormat.frameDuration
            let wanted = profile(frame)
            for bytes in packer.setProfile(wanted) {
                sent.append(Sent(bytes: bytes, sendTime: now, profile: wanted))
            }
            let packet = encoder.encode(
                samples.baseAddress! + frame * slotSamples, gain: 1,
                quality: wanted.effectiveQuality(requested),
                flags: frame == 0 ? [.discontinuity] : [], sequence: UInt32(frame),
                sampleTime: UInt64(frame * AudioFormat.samplesPerFrame))
            for bytes in packer.pack(packet) {
                sent.append(Sent(bytes: bytes, sendTime: now, profile: wanted))
            }
        }
    }
    return sent
}

private struct Result {
    var output: [Float]
    var jitter: JitterBufferStats
    var reader: ConcealmentStats
    var warmJitter: JitterBufferStats
    var warmReader: ConcealmentStats
    var retunes: Int
    var maxTargetMs: Int
}

/// Plays `arrivals` one slot per 5 ms; the buffer follows each datagram's
/// profile mark (as the phone does).
private func play(
    _ arrivals: [(Data, TimeInterval)], ticks: Int, mode: JitterLatencyMode, warmUpTicks: Int = 0
) -> Result {
    let buffer = JitterBuffer(config: StreamProfile.lan.jitterConfig(mode))
    let reader = PCMFrameReader(source: { payload, skipped in
        buffer.pop(payload: payload, skippedPayload: skipped)
    })
    let sorted = arrivals.sorted { $0.1 < $1.1 }
    var next = 0
    var follower = ProfileFollower()
    var retunes = 0
    var maxTarget = 0
    var warm = (JitterBufferStats(), ConcealmentStats())
    var output = [Float](repeating: 0, count: ticks * slotSamples)
    output.withUnsafeMutableBufferPointer { out in
        for tick in 0..<ticks {
            let now = Double(tick) * AudioFormat.frameDuration
            while next < sorted.count, sorted[next].1 <= now {
                if let datagram = try? AudioDatagram.decode(sorted[next].0) {
                    if let profile = follower.observe(datagram.profile, sequence: datagram.sequence) {
                        buffer.retune(profile.jitterConfig(mode))
                        retunes += 1
                    }
                    for packet in datagram.packets() {
                        buffer.insert(packet, arrivalTime: sorted[next].1)
                    }
                }
                next += 1
            }
            if tick == warmUpTicks {
                warm = (buffer.stats, reader.stats)
            }
            if tick >= warmUpTicks {
                maxTarget = max(maxTarget, buffer.stats.targetFrames)
            }
            reader.read(into: out.baseAddress! + tick * slotSamples, sampleCount: slotSamples)
        }
    }
    return Result(
        output: output, jitter: buffer.stats, reader: reader.stats, warmJitter: warm.0, warmReader: warm.1,
        retunes: retunes, maxTargetMs: maxTarget * AudioFormat.frameDurationMs)
}

private struct LCG {
    var state: UInt64
    mutating func uniform(_ low: Double, _ high: Double) -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return low + Double(state >> 11) * 0x1.0p-53 * (high - low)
    }
}

struct WANPlayoutTests {
    @Test("LAN ↔ WAN switch mid-stream: continuous, no click, no concealment, nothing lost")
    func profileSwitchIsSmooth() {
        let frames = 3600
        let signal = sine(frames: frames + 50)
        let schedule: (Int) -> StreamProfile = { ($0 >= 1200 && $0 < 2400) ? .wan : .lan }
        let sent = send(signal, frames: frames, requested: .opus192, profile: schedule)
        var random = LCG(state: 0xA11CE)
        let arrivals = sent.map { ($0.bytes, $0.sendTime + 0.002 + random.uniform(0, 0.002)) }
        let result = play(arrivals, ticks: frames, mode: .balanced)
        let step = maxStep(Array(result.output[(slotSamples * 20)...]))
        print(
            "LAN↔WAN switch: retunes=\(result.retunes) lost=\(result.jitter.lost) concealed=\(result.reader.concealedFrames) "
                + "trimmed=\(result.jitter.trimmed) crossfades=\(result.reader.crossfades) "
                + "maxStep=\(String(format: "%.4f", step)) sine=\(String(format: "%.4f", sineMaxStep(frequency: 1000)))")
        #expect(result.retunes == 2)
        #expect(result.jitter.lost == 0)
        #expect(result.jitter.overflowDropped == 0)
        #expect(result.reader.decodeErrors == 0)
        #expect(result.reader.concealedFrames == 0)
        #expect(step <= sineMaxStep(frequency: 1000) * 1.25)
    }

    @Test("Path change LAN → tailnet (+40 ms delay, 3 s outage) and back: fades only, below the crackle threshold")
    func failoverSwitchIsSmooth() {
        let frames = 4000
        let signal = sine(frames: frames + 50)
        // 0–6 s LAN; 6–9 s outage (keepalive timeout → failover); 9–14 s
        // tailnet; then LAN again with no outage (the switch back is
        // make-before-break on the sender: Bonjour reappeared).
        let schedule: (Int) -> StreamProfile = { ($0 >= 1800 && $0 < 2800) ? .wan : .lan }
        let sent = send(signal, frames: frames, requested: .opus192, profile: schedule)
        var random = LCG(state: 0xFA11)
        var arrivals: [(Data, TimeInterval)] = []
        for datagram in sent {
            let t = datagram.sendTime
            if t >= 6.0 && t < 9.0 { continue }  // nothing gets through
            let delay = datagram.profile == .wan ? 0.040 + random.uniform(0, 0.015) : 0.002 + random.uniform(0, 0.002)
            arrivals.append((datagram.bytes, t + delay))
        }
        let result = play(arrivals, ticks: frames, mode: .balanced)
        let step = maxStep(Array(result.output[(slotSamples * 20)...]))
        print(
            "failover LAN→WAN→LAN: retunes=\(result.retunes) lost=\(result.jitter.lost) rebuffers=\(result.jitter.rebuffers) "
                + "concealed=\(result.reader.concealedFrames) fadeOuts=\(result.reader.fadeOuts) "
                + "trimmed=\(result.jitter.trimmed) maxStep=\(String(format: "%.4f", step))")
        #expect(result.retunes == 2)
        #expect(result.reader.decodeErrors == 0)
        #expect(step <= sineMaxStep(frequency: 1000) * 1.25)
        #expect(result.reader.fadeOuts >= 1)
    }

    @Test("Cellular replay: 30–80 ms jitter, 150–400 ms bursts every ~20 s, 2 % loss (WAN, Opus 128)")
    func cellularReplay() {
        let seconds = 150.0
        let frames = Int(seconds / AudioFormat.frameDuration)
        let warmUpSeconds = 30.0
        let warmUpTicks = Int(warmUpSeconds / AudioFormat.frameDuration)
        var random = LCG(state: 0xCE11_0001)
        var bursts: [(start: Double, end: Double)] = []
        var t = random.uniform(8, 14)
        while t < seconds {
            bursts.append((t, t + random.uniform(0.150, 0.400)))
            t += random.uniform(16, 24)
        }
        let signal = sine(frames: frames + 50)
        let sent = send(signal, frames: frames, requested: .opus192, profile: { _ in .wan })
        var arrivals: [(Data, TimeInterval)] = []
        var dropped = 0
        // The jitter amplitude itself wanders between 30 and 80 ms (5 s steps).
        var amplitude = 0.030
        var nextAmplitudeChange = 0.0
        for datagram in sent {
            if datagram.sendTime >= nextAmplitudeChange {
                amplitude = random.uniform(0.030, 0.080)
                nextAmplitudeChange += 5
            }
            if random.uniform(0, 1) < 0.02 {
                dropped += 1
                continue
            }
            var arrival = datagram.sendTime + 0.045 + random.uniform(0, amplitude)
            if let burst = bursts.first(where: { $0.start <= datagram.sendTime && datagram.sendTime < $0.end }) {
                arrival = max(arrival, burst.end + 0.045 + random.uniform(0, 0.005))
            }
            arrivals.append((datagram.bytes, arrival))
        }
        let result = play(arrivals, ticks: frames, mode: .balanced, warmUpTicks: warmUpTicks)
        let jitter = result.jitter
        let reader = result.reader
        let warmBursts = bursts.filter { $0.start >= warmUpSeconds }.count
        let underruns = jitter.underruns - result.warmJitter.underruns
        let concealed = reader.concealedFrames - result.warmReader.concealedFrames
        let lost = jitter.lost - result.warmJitter.lost
        let recovered = jitter.recovered - result.warmJitter.recovered
        let step = maxStep(Array(result.output[(warmUpTicks * slotSamples)...]))
        let wireBytes = sent.reduce(0) { $0 + $1.bytes.count + StreamDataRate.overheadPerDatagram(.tailscaleDirect) }
        print(
            "cellular replay[balanced, WAN] \(Int(seconds)) s, \(bursts.count) bursts (\(warmBursts) after warm-up), "
                + "2% loss (\(dropped) of \(sent.count) datagrams dropped), after \(Int(warmUpSeconds)) s warm-up: "
                + "underruns=\(underruns), concealed=\(concealed) frames (\(concealed * AudioFormat.frameDurationMs) ms), "
                + "lost=\(lost), recovered=\(recovered), target=\(jitter.targetFrames * AudioFormat.frameDurationMs) ms "
                + "(max \(result.maxTargetMs) ms), trimmed=\(jitter.trimmed - result.warmJitter.trimmed), "
                + "maxStep=\(String(format: "%.4f", step)), "
                + "data=\(String(format: "%.0f", Double(wireBytes) / seconds * 3600 / 1_000_000)) MB/h")
        #expect(reader.decodeErrors == 0)
        // Each frame rides in three datagrams: independent 2 % loss
        // (0.02³ per frame) leaves next to nothing to conceal.
        #expect(lost <= 2)
        #expect(recovered > 100)
        // Bursts longer than every burst seen in the window can still
        // underrun once each; the rest are covered by the adaptive target.
        #expect(underruns <= warmBursts)
        #expect(concealed <= warmBursts * AudioFormat.frames(milliseconds: 250))
        #expect(step <= sineMaxStep(frequency: 1000) * 1.25)
        #expect(jitter.targetFrames * AudioFormat.frameDurationMs >= 140)
        #expect(result.maxTargetMs <= 600)
    }
}
