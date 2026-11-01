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

/// Music-like test signal: three partials with slow amplitude modulation and
/// a little noise, so Opus PLC cannot simply continue a steady tone.
private func music(frames: Int) -> [Float] {
    var signal = [Float](repeating: 0, count: frames * slotSamples)
    var random = LCG(state: 0x5EED)
    for n in 0..<(frames * AudioFormat.samplesPerFrame) {
        let t = Double(n) / AudioFormat.sampleRate
        let envelope = 0.6 + 0.4 * sin(2 * Double.pi * 3 * t)
        let tone = 0.22 * sin(2 * Double.pi * 330 * t) + 0.15 * sin(2 * Double.pi * 495 * t + 1)
            + 0.08 * sin(2 * Double.pi * 1320 * t * (1 + 0.01 * sin(2 * Double.pi * 0.7 * t)))
        let left = Float(envelope * tone + random.uniform(-0.02, 0.02))
        signal[2 * n] = left
        signal[2 * n + 1] = left * 0.9
    }
    return signal
}

private struct Sent {
    let bytes: Data
    let sendTime: TimeInterval
    let profile: StreamProfile
}

/// Encodes `frames` 5 ms frames, switching profile (and so the encoding:
/// 5 ms LAN pick vs 20 ms Internet rung with low-rate copies) as
/// `profile(frame)` says, the way the sender does: the encoder reads the
/// encoding per frame, the packer flushes before a profile switch.
private func send(
    _ signal: [Float], frames: Int, lan: StreamQuality = .opus192, internet: InternetQuality = .standard,
    profile: (Int) -> StreamProfile
) -> [Sent] {
    let encoder = StreamFrameEncoder()
    var packer = RedundancyPacker()
    var sent: [Sent] = []
    signal.withUnsafeBufferPointer { samples in
        for frame in 0..<frames {
            let now = Double(frame) * AudioFormat.frameDuration
            let wanted = profile(frame)
            encoder.encode(
                samples.baseAddress! + frame * slotSamples, gain: 1,
                encoding: wanted.encoding(lan: lan, internet: internet),
                flags: frame == 0 ? [.discontinuity] : [], sequence: UInt32(frame),
                sampleTime: UInt64(frame * AudioFormat.samplesPerFrame)
            ) { packet in
                for bytes in packer.setProfile(wanted) + packer.pack(packet) {
                    sent.append(Sent(bytes: bytes, sendTime: now, profile: wanted))
                }
            }
        }
    }
    return sent
}

/// The same datagrams without their redundant entries (what plain Opus PLC
/// would have to cover).
private func strippingCopies(_ data: Data) -> Data? {
    guard var datagram = try? AudioDatagram.decode(data) else { return nil }
    datagram.entries.removeAll { Int($0.offset) >= datagram.primaryCount }
    return datagram.entries.isEmpty ? nil : datagram.encoded()
}

private struct Result {
    var output: [Float]
    var jitter: JitterBufferStats
    var reader: ConcealmentStats
    var warmJitter: JitterBufferStats
    var warmReader: ConcealmentStats
    var retunes: Int
    var maxTargetMs: Int
    var stream: PlayoutStream?
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
        retunes: retunes, maxTargetMs: maxTarget * AudioFormat.frameDurationMs, stream: reader.stream)
}

/// Crackle threshold for a 1 kHz test tone played (partly) from 24 kbit/s
/// copies: the low-rate encoding reproduces the tone up to ~2 dB louder
/// (peak ≈ 0.61 instead of 0.5), so its own slope is steeper; a click is a
/// step beyond 1.25 × the slope of a sine at the output's actual peak.
private func toneStepLimit(_ output: [Float]) -> Float {
    let peak = output.reduce(Float(0)) { max($0, abs($1)) }
    return sineMaxStep(frequency: 1000, amplitude: Double(max(peak, 0.5))) * 1.25
}

/// Error energy of `output` against `reference` over `range` (interleaved
/// sample indices), relative to the reference energy.
private func relativeError(_ output: [Float], _ reference: [Float], _ range: Range<Int>) -> Double {
    var error = 0.0
    var energy = 0.0
    for i in range {
        let d = Double(output[i] - reference[i])
        error += d * d
        energy += Double(reference[i]) * Double(reference[i])
    }
    return error / max(energy, 1e-12)
}

private struct LCG {
    var state: UInt64
    mutating func uniform(_ low: Double, _ high: Double) -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return low + Double(state >> 11) * 0x1.0p-53 * (high - low)
    }
}

struct WANPlayoutTests {
    @Test("LAN ↔ WAN switch mid-stream (5 ms Opus 192 ↔ 20 ms Opus 96 + copies): no click, nothing lost")
    func profileSwitchIsSmooth() {
        let frames = 3600
        let signal = sine(frames: frames + 50)
        // Switch points off the 20 ms grid too (1202): the encoder starts
        // its groups wherever the switch lands.
        let schedule: (Int) -> StreamProfile = { ($0 >= 1202 && $0 < 2401) ? .wan : .lan }
        let sent = send(signal, frames: frames, profile: schedule)
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
        let sent = send(signal, frames: frames, profile: schedule)
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

    @Test("Cellular replay: 30–80 ms jitter, 150–400 ms bursts every ~20 s, 2 % loss (WAN, 20 ms Opus 96 + 2 × 24 k copies)")
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
        let sent = send(signal, frames: frames, internet: .standard, profile: { _ in .wan })
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
        let lowRate = jitter.lowRateRecovered - result.warmJitter.lowRateRecovered
        let tail = Array(result.output[(warmUpTicks * slotSamples)...])
        let step = maxStep(tail)
        let limit = toneStepLimit(tail)
        let wireBytes = sent.reduce(0) { $0 + $1.bytes.count + StreamDataRate.overheadPerDatagram(.tailscaleDirect) }
        print(
            "cellular replay[balanced, WAN Standard] \(Int(seconds)) s, \(bursts.count) bursts (\(warmBursts) after warm-up), "
                + "2% loss (\(dropped) of \(sent.count) datagrams dropped), after \(Int(warmUpSeconds)) s warm-up: "
                + "underruns=\(underruns), concealed=\(concealed) slots (\(concealed * AudioFormat.frameDurationMs) ms), "
                + "lost=\(lost) slots, recovered=\(recovered) slots (low-rate \(lowRate)), "
                + "target=\(jitter.targetFrames * AudioFormat.frameDurationMs) ms "
                + "(max \(result.maxTargetMs) ms), trimmed=\(jitter.trimmed - result.warmJitter.trimmed), "
                + "maxStep=\(String(format: "%.4f", step)) (limit \(String(format: "%.4f", limit))), "
                + "data=\(String(format: "%.0f", Double(wireBytes) / seconds * 3600 / 1_000_000)) MB/h")
        #expect(reader.decodeErrors == 0)
        // Each frame rides in three datagrams: independent 2 % loss
        // (0.02³ per frame) leaves next to nothing to conceal; a lost 20 ms
        // frame is 4 slots.
        #expect(lost <= 8)
        #expect(recovered > 100)
        #expect(lowRate == recovered)
        // Bursts longer than every burst seen in the window can still
        // underrun once each; the rest are covered by the adaptive target.
        #expect(underruns <= warmBursts)
        #expect(concealed <= warmBursts * AudioFormat.frames(milliseconds: 250))
        #expect(step <= limit)
        #expect(jitter.targetFrames * AudioFormat.frameDurationMs >= 140)
        #expect(result.maxTargetMs <= 600)
        #expect(Double(wireBytes) / seconds * 3600 / 1_000_000 < 90)
    }

    @Test("Low-rate copies recover single losses and 2-loss runs; the primary ↔ copy splice stays below the crackle threshold")
    func lowRateCopiesRecoverLosses() {
        let frames = 2400  // 12 s
        let signal = sine(frames: frames + 50)
        let sent = send(signal, frames: frames, profile: { _ in .wan })
        // Lose single datagrams and 2-datagram runs, alternating every ~0.5 s.
        var arrivals: [(Data, TimeInterval)] = []
        var droppedRuns = (single: 0, double: 0)
        var index = 0
        while index < sent.count {
            if index >= 30, index % 25 == 0 {
                let run = (index / 25) % 2 == 0 ? 1 : 2
                if run == 1 { droppedRuns.single += 1 } else { droppedRuns.double += 1 }
                index += run
                continue
            }
            arrivals.append((sent[index].bytes, sent[index].sendTime + 0.030))
            index += 1
        }
        let result = play(arrivals, ticks: frames, mode: .balanced)
        let tail = Array(result.output[(slotSamples * 60)...])
        let step = maxStep(tail)
        let limit = toneStepLimit(tail)
        print(
            "low-rate copies: \(droppedRuns.single) single + \(droppedRuns.double) double losses: "
                + "lost=\(result.jitter.lost) recovered=\(result.jitter.recovered) slots "
                + "(low-rate \(result.jitter.lowRateRecovered)), concealed=\(result.reader.concealedFrames), "
                + "maxStep=\(String(format: "%.4f", step)) (limit at the output's peak \(String(format: "%.4f", limit)); "
                + "0.5-amplitude sine \(String(format: "%.4f", sineMaxStep(frequency: 1000))))")
        #expect(result.jitter.lost == 0)
        #expect(result.reader.concealedFrames == 0)
        #expect(result.reader.decodeErrors == 0)
        #expect(result.jitter.lowRateRecovered == 4 * (droppedRuns.single + 2 * droppedRuns.double))
        #expect(result.jitter.recovered == result.jitter.lowRateRecovered)
        #expect(step <= limit)
        // The copies sit within 2.5 dB of the tone (no level jump).
        #expect(limit <= sineMaxStep(frequency: 1000, amplitude: 0.5 * 1.33) * 1.25)
        // The stream readout shows the primaries, not the copies.
        #expect(result.stream?.displayName == "Opus 96 kbit/s · 20 ms")
    }

    @Test("Low-rate copies beat plain Opus PLC on a lost 20 ms frame (music-like signal)")
    func lowRateCopiesBeatPlc() {
        let frames = 2400
        let signal = music(frames: frames + 50)
        let sent = send(signal, frames: frames, profile: { _ in .wan })
        let delay = 0.030
        let reference = play(sent.map { ($0.bytes, $0.sendTime + delay) }, ticks: frames, mode: .balanced)
        let lostIndices = Set(stride(from: 30, to: sent.count - 3, by: 20))
        let withCopies = sent.enumerated().filter { !lostIndices.contains($0.offset) }
            .map { ($0.element.bytes, $0.element.sendTime + delay) }
        let plcOnly = sent.enumerated().filter { !lostIndices.contains($0.offset) }
            .compactMap { item in strippingCopies(item.element.bytes).map { ($0, item.element.sendTime + delay) } }
        let copies = play(withCopies, ticks: frames, mode: .balanced)
        let plc = play(plcOnly, ticks: frames, mode: .balanced)
        let range = (slotSamples * 100)..<(slotSamples * (frames - 40))
        let copyError = relativeError(copies.output, reference.output, range)
        let plcError = relativeError(plc.output, reference.output, range)
        print(
            "\(lostIndices.count) lost 20 ms frames: error vs lossless with 24 k copies \(String(format: "%.5f", copyError)), "
                + "with Opus PLC only \(String(format: "%.5f", plcError)) "
                + "(PLC slots \(plc.reader.opusPlcFrames), copy slots \(copies.jitter.lowRateRecovered))")
        #expect(copies.jitter.lowRateRecovered == 4 * lostIndices.count)
        #expect(plc.reader.opusPlcFrames >= 4 * lostIndices.count)
        #expect(copyError < plcError)
    }

    @Test("Opus PLC on 20 ms gaps: a 20 ms frame lost for good (3-datagram run) is concealed by PLC and the next frame joins smoothly")
    func plcOnTwentyMillisecondGaps() {
        let frames = 2400
        let signal = sine(frames: frames + 50)
        let sent = send(signal, frames: frames, profile: { _ in .wan })
        // Three consecutive datagrams: the first one's frame and both its
        // copies are gone; the other two are recovered from later copies.
        let runs = [60, 160, 260, 360]
        let dropped = Set(runs.flatMap { [$0, $0 + 1, $0 + 2] })
        let arrivals = sent.enumerated().filter { !dropped.contains($0.offset) }
            .map { ($0.element.bytes, $0.element.sendTime + 0.030) }
        let result = play(arrivals, ticks: frames, mode: .balanced)
        let step = maxStep(Array(result.output[(slotSamples * 60)...]))
        print(
            "PLC on 20 ms gaps: \(runs.count) 3-datagram runs: lost=\(result.jitter.lost) slots, "
                + "recovered=\(result.jitter.recovered), opusPlc=\(result.reader.opusPlcFrames), "
                + "concealments=\(result.reader.concealments), fadeOuts=\(result.reader.fadeOuts), "
                + "maxStep=\(String(format: "%.4f", step))")
        #expect(result.jitter.lost == 4 * runs.count)
        #expect(result.reader.opusPlcFrames == 4 * runs.count)
        #expect(result.reader.concealments == runs.count)
        #expect(result.reader.fadeOuts == 0)  // 20 ms of PLC stays at full level
        #expect(result.reader.decodeErrors == 0)
        #expect(result.jitter.recovered == 4 * 2 * runs.count)
        #expect(step <= sineMaxStep(frequency: 1000) * 1.25)
    }
}

// MARK: - The Internet quality ladder

struct InternetLadderTests {
    @Test("Ladder: datagram sizes and MB/h over Tailscale match the study (101 / 87 / 72 / 65)")
    func ladderSizesAndRates() {
        let expected: [InternetQuality: (bytes: Int, megabytesPerHour: Double)] = [
            .high: (473, 101), .standard: (393, 87), .saver: (313, 72), .floor: (273, 65),
        ]
        for rung in InternetQuality.allCases {
            let estimate = StreamDataRate.estimate(.wan(rung), profile: .wan, path: .tailscaleDirect)
            print(
                "ladder \(rung.displayName) (\(rung.quality.displayName)): datagram \(estimate.largestDatagram) B, "
                    + "\(String(format: "%.0f", estimate.datagramsPerSecond)) datagrams/s, "
                    + "\(String(format: "%.0f", estimate.kilobitsPerSecond)) kbit/s, "
                    + "\(String(format: "%.1f", estimate.megabytesPerHour)) MB/h; menu: \(rung.menuName)")
            #expect(estimate.datagramsPerSecond == 50)
            #expect(estimate.largestDatagram == expected[rung]!.bytes)
            #expect(abs(estimate.megabytesPerHour - expected[rung]!.megabytesPerHour) < 1.5)
            #expect(rung.expectedMegabytesPerHour == Int(estimate.megabytesPerHour.rounded()))
        }
        #expect(InternetQuality.default == .standard)
    }

    @Test("Ladder with the real encoder: CBR 20 ms frames, 24 k copies, every datagram of the measured size")
    func ladderWithRealEncoder() throws {
        let frames = 800
        var random = LCG(state: 0xB0B)
        // Loud noise: CBR must hold the size whatever the content.
        var signal = [Float](repeating: 0, count: (frames + 4) * slotSamples)
        for i in signal.indices { signal[i] = Float(random.uniform(-0.9, 0.9)) }
        for rung in InternetQuality.allCases {
            let sent = send(signal, frames: frames, internet: rung, profile: { _ in .wan })
            let datagrams = try sent.map { try AudioDatagram.decode($0.bytes) }
            let steady = datagrams.dropFirst(3)
            let sizes = Set(steady.map { $0.encoded().count })
            let primary = steady.first!.entries[0]
            let copies = steady.first!.entries.dropFirst()
            print(
                "real encoder \(rung.displayName): \(sent.count) datagrams for \(frames * 5) ms, sizes \(sizes.sorted()), "
                    + "primary \(primary.payload.count) B, copies \(copies.map(\.payload.count)) B")
            #expect(sent.count == frames / 4)
            #expect(sizes.count == 1)
            #expect(primary.frameSlots == 4 && !primary.lowRate)
            #expect(primary.payload.count == rung.quality.opusBitrate! / 8 / 50)
            #expect(copies.map(\.offset) == [4, 8])
            #expect(copies.allSatisfy { $0.lowRate && $0.frameSlots == 4 && $0.payload.count == 60 })
            let estimate = StreamDataRate.estimate(.wan(rung), profile: .wan, path: .tailscaleDirect)
            #expect(sizes.first == estimate.largestDatagram)
        }
    }

    @Test("Encoding per profile: LAN keeps the pick at 5 ms; WAN encodes the rung at 20 ms with 24 k copies, never PCM")
    func encodingPerProfile() {
        #expect(StreamProfile.lan.encoding(lan: .pcm, internet: .saver) == .lan(.pcm))
        #expect(StreamProfile.lan.encoding(lan: .opus96, internet: .saver).frameSlots == 1)
        let wan = StreamProfile.wan.encoding(lan: .pcm, internet: .saver)
        #expect(wan.quality == .opus64 && wan.frameSlots == 4 && wan.copyBitrate == 24_000)
        #expect(StreamProfile.wan.effectiveQuality(lan: .opus192, internet: .high) == .opus128)
        #expect(StreamProfile.wan.effectiveQuality(lan: .opus192, internet: .floor) == .opus48)
        #expect(StreamProfile.lan.qualityNote(lan: .pcm, internet: .standard) == nil)
        #expect(
            StreamProfile.wan.qualityNote(lan: .pcm, internet: .standard)
                == "Over the Internet: Standard — Opus 96 kbit/s, ≈ 87 MB/h")
        #expect(StreamQuality.lanChoices == [.opus192, .opus128, .opus96, .pcm])
        #expect(StreamEncoding.wan(.standard).displayName == "Opus 96 kbit/s · 20 ms")
        #expect(InternetQuality.saver.menuName == "Saver — Opus 64 kbit/s · ≈ 72 MB/h")
    }

    @Test("Control v5: setInternetQuality round trip, gated to v5; status carries the Internet quality")
    func controlInternetQuality() throws {
        let message = ControlMessage.setInternetQuality(.saver)
        #expect(message.requiredVersion == ControlProtocol.internetQualityVersion)
        #expect(
            String(decoding: message.payload(), as: UTF8.self)
                == #"{"internetQuality":"saver","type":"setInternetQuality","v":5}"#)
        #expect(try ControlMessage.decode(payload: message.payload()) == message)
        let old = Data(#"{"v":4,"type":"setInternetQuality","internetQuality":"saver"}"#.utf8)
        #expect(throws: ControlProtocolError.malformed) { try ControlMessage.decode(payload: old) }
        #expect(ControlMessage.setQuality(.opus96).requiredVersion == 1)
        var status = SourceStatus(
            sourceID: "S", name: "MacBook", sourceTag: 7, driverInstalled: true, outputIsOurs: true,
            streamingToYou: true, streamingTo: "iPhone", audioPlaying: true, outputDeviceName: nil,
            volume: 0.5, muted: false, quality: .opus192, usedBy: nil, problem: nil, profile: .wan,
            internetQuality: .floor)
        #expect(try ControlMessage.decode(payload: ControlMessage.status(status).payload()) == .status(status))
        #expect(status.effectiveQuality == .opus48)
        status.profile = .lan
        #expect(status.effectiveQuality == .opus192)
        // A status from an older Mac (no internetQuality) reads as Standard.
        status.profile = .wan
        status.internetQuality = nil
        #expect(status.effectiveQuality == .opus96)
    }

    @Test("Jitter buffer: a 20 ms frame fills four slots; a late primary replaces its low-rate copy's payload")
    func twentyMillisecondSlots() {
        let buffer = JitterBuffer(config: StreamProfile.wan.jitterConfig(.low))
        func frame(_ sequence: UInt32, copy: Bool, byte: UInt8) -> AudioPacket {
            AudioPacket(
                codec: .opus, sequence: sequence, sampleTime: UInt64(sequence) * 240,
                payload: Data(repeating: byte, count: copy ? 60 : 240), isRedundant: copy, frameSlots: 4,
                isLowRateCopy: copy)
        }
        for group in 0..<15 where group != 3 {
            buffer.insert(frame(UInt32(group * 4), copy: false, byte: UInt8(group)), arrivalTime: Double(group) * 0.02)
        }
        // Frame 12 (group 3): its copy arrives first, then the primary.
        buffer.insert(frame(12, copy: true, byte: 0xC0), arrivalTime: 0.9)
        buffer.insert(frame(12, copy: false, byte: 3), arrivalTime: 0.91)
        #expect(buffer.stats.depthFrames == 60)
        var parts: [(UInt32, Int, Int, Int)] = []
        let payload = UnsafeMutableRawBufferPointer.allocate(byteCount: JitterBuffer.maxFramePayloadBytes, alignment: 16)
        let skipped = UnsafeMutableRawBufferPointer.allocate(byteCount: JitterBuffer.maxFramePayloadBytes, alignment: 16)
        defer {
            payload.deallocate()
            skipped.deallocate()
        }
        for _ in 0..<20 {
            if case .frame(let played) = buffer.pop(payload: payload, skippedPayload: skipped) {
                parts.append((played.sequence, played.part, played.frameSlots, played.byteCount))
                if played.sequence == 12 {
                    #expect(payload.load(fromByteOffset: 0, as: UInt8.self) == 3)
                    #expect(!played.recovered && !played.lowRateCopy)
                }
            }
        }
        #expect(parts.map(\.0) == Array(0..<20).map(UInt32.init))
        #expect(parts.map(\.1) == (0..<20).map { $0 % 4 })
        #expect(parts.allSatisfy { $0.2 == 4 })
        #expect(parts.map(\.3) == (0..<20).map { $0 % 4 == 0 ? 240 : 0 })
        #expect(buffer.stats.recovered == 0)
        #expect(buffer.stats.lost == 0)
    }

    @Test("A group cut short by a switch or a discontinuity goes out as 5 ms frames, in sequence order")
    func groupCutShort() {
        let encoder = StreamFrameEncoder()
        let signal = sine(frames: 20)
        var packets: [AudioPacket] = []
        signal.withUnsafeBufferPointer { samples in
            for frame in 0..<14 {
                // WAN for 0...5 (one group + 2 pending), LAN at 6, WAN again
                // from 7, a new run (discontinuity) at 9.
                let encoding: StreamEncoding = (frame == 6) ? .lan(.opus128) : .wan(.standard)
                encoder.encode(
                    samples.baseAddress! + frame * slotSamples, gain: 1, encoding: encoding,
                    flags: frame == 0 || frame == 9 ? [.discontinuity] : [], sequence: UInt32(frame),
                    sampleTime: UInt64(frame * AudioFormat.samplesPerFrame)
                ) { packets.append($0) }
            }
        }
        #expect(encoder.pendingFrames == 1)  // 13 waits for its group
        #expect(packets.map(\.sequence) == [0, 4, 5, 6, 7, 8, 9])
        #expect(packets.map(\.frameSlots) == [4, 1, 1, 1, 1, 1, 4])
        #expect(packets.map { $0.copyPayload != nil } == [true, false, false, false, false, false, true])
        #expect(packets.map(\.flags) == [[.discontinuity], [], [], [], [], [], [.discontinuity]])
        #expect(packets.allSatisfy { $0.codec == .opus })
    }
}
