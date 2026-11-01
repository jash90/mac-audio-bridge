import Foundation
import Testing
@testable import BridgeCore

// MARK: - Harness: StreamFrameEncoder → RedundancyPacker → wire → JitterBuffer → PCMFrameReader

private let slotSamples = AudioFormat.samplesPerFrame * AudioFormat.channelCount

/// Deterministic interleaved stereo test signal: a sine (both channels)
/// plus uniform white noise of peak `noise`.
private func testSignal(
    frames: Int, frequency: Double = 1000, amplitude: Double = 0.5, noise: Double = 0, seed: UInt64 = 7
) -> [Float] {
    var state = seed
    var signal = [Float](repeating: 0, count: frames * slotSamples)
    for n in 0..<(frames * AudioFormat.samplesPerFrame) {
        let sine = amplitude * sin(2 * Double.pi * frequency * Double(n) / AudioFormat.sampleRate)
        for channel in 0..<2 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let white = (Double(state >> 11) * 0x1.0p-53 * 2 - 1) * noise
            signal[2 * n + channel] = Float(sine + white)
        }
    }
    return signal
}

private struct SentDatagram {
    let frame: Int
    let bytes: Data
    let sendTime: TimeInterval
}

/// Encodes every frame of `signal` in `quality(frame)` with the production
/// encoder and packer.
private func send(
    _ signal: [Float], quality: (Int) -> StreamQuality
) -> (datagrams: [SentDatagram], packets: [AudioPacket]) {
    let encoder = StreamFrameEncoder()
    var packer = RedundancyPacker()
    var datagrams: [SentDatagram] = []
    var packets: [AudioPacket] = []
    let frames = signal.count / slotSamples
    signal.withUnsafeBufferPointer { samples in
        for frame in 0..<frames {
            let packet = encoder.encode(
                samples.baseAddress! + frame * slotSamples, gain: 1, quality: quality(frame),
                flags: frame == 0 ? [.discontinuity] : [], sequence: UInt32(frame),
                sampleTime: UInt64(frame * AudioFormat.samplesPerFrame))
            packets.append(packet)
            for bytes in packer.pack(packet) {
                datagrams.append(
                    SentDatagram(frame: frame, bytes: bytes, sendTime: Double(frame) * AudioFormat.frameDuration))
            }
        }
    }
    return (datagrams, packets)
}

private struct Playback {
    var output: [Float]
    var jitter: JitterBufferStats
    var reader: ConcealmentStats
    var stream: PlayoutStream?
}

/// Delivers `arrivals` into a jitter buffer and renders one slot per 5 ms
/// tick through a `PCMFrameReader`.
private func play(
    _ arrivals: [(Data, TimeInterval)], ticks: Int, config: JitterBufferConfig = .latency(.balanced)
) -> Playback {
    let buffer = JitterBuffer(config: config)
    let reader = PCMFrameReader(source: { payload, skipped in
        buffer.pop(payload: payload, skippedPayload: skipped)
    })
    let sorted = arrivals.sorted { $0.1 < $1.1 }
    var next = 0
    var output = [Float](repeating: 0, count: ticks * slotSamples)
    output.withUnsafeMutableBufferPointer { out in
        for tick in 0..<ticks {
            let now = Double(tick) * AudioFormat.frameDuration
            while next < sorted.count, sorted[next].1 <= now {
                if let datagram = try? AudioDatagram.decode(sorted[next].0) {
                    for packet in datagram.packets() {
                        buffer.insert(packet, arrivalTime: sorted[next].1)
                    }
                }
                next += 1
            }
            reader.read(into: out.baseAddress! + tick * slotSamples, sampleCount: slotSamples)
        }
    }
    return Playback(output: output, jitter: buffer.stats, reader: reader.stats, stream: reader.stream)
}

/// A clean network: every datagram arrives 2–4 ms after it was sent.
private func cleanArrivals(_ datagrams: [SentDatagram], dropping lost: Set<Int> = []) -> [(Data, TimeInterval)] {
    var state: UInt64 = 0x5EED
    return datagrams.compactMap { datagram in
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        guard !lost.contains(datagram.frame) else { return nil }
        let jitter = Double(state >> 11) * 0x1.0p-53 * 0.002
        return (datagram.bytes, datagram.sendTime + 0.002 + jitter)
    }
}

/// Signal-to-noise ratio of `decoded` against `input`, compensating the
/// codec delay of `delay` samples per channel and skipping `skip` frames.
private func snr(_ input: [Float], _ decoded: [Float], delay: Int, skipSamples: Int) -> Double {
    var signal = 0.0
    var error = 0.0
    let frames = input.count / 2
    for n in skipSamples..<(frames - delay) {
        for channel in 0..<2 {
            let reference = Double(input[2 * n + channel])
            let value = Double(decoded[2 * (n + delay) + channel])
            signal += reference * reference
            error += (reference - value) * (reference - value)
        }
    }
    return 10 * log10(signal / max(error, 1e-30))
}

private func percentile(_ values: [Double], _ q: Double) -> Double {
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))]
}

// MARK: - Codec

struct OpusCodecTests {
    @Test(
        "Opus round trip of a 1 kHz sine + noise: CBR frame size, exact length, SNR",
        arguments: [(192_000, 32.0), (128_000, 28.0)])
    func roundTrip(bitrate: Int, minimumSNR: Double) throws {
        let frames = 1000
        let input = testSignal(frames: frames, noise: 0.01)
        let encoder = try OpusEncoderBox(bitrate: bitrate)
        let decoder = try OpusDecoderBox()
        var decoded = [Float](repeating: .nan, count: input.count)
        var sizes = Set<Int>()
        var decodedFrames = 0
        input.withUnsafeBufferPointer { samples in
            decoded.withUnsafeMutableBufferPointer { out in
                for frame in 0..<frames {
                    let packet = try! encoder.encode(samples.baseAddress! + frame * slotSamples)
                    sizes.insert(packet.count)
                    decodedFrames += decoder.decode(
                        UnsafeRawPointer(packet.baseAddress!), count: packet.count,
                        into: out.baseAddress! + frame * slotSamples)
                }
            }
        }
        let ratio = snr(input, decoded, delay: encoder.lookaheadSamples, skipSamples: 50 * AudioFormat.samplesPerFrame)
        print("opus \(bitrate / 1000) kbit/s: frame \(sizes.sorted()) B, lookahead \(encoder.lookaheadSamples), SNR \(String(format: "%.1f", ratio)) dB")
        #expect(sizes == [bitrate / 8 * AudioFormat.frameDurationMs / 1000])
        #expect(decodedFrames == frames * AudioFormat.samplesPerFrame)
        #expect(!decoded.contains { $0.isNaN })
        #expect(encoder.lookaheadSamples == 120)
        #expect(ratio >= minimumSNR)
    }

    @Test("Encode and decode cost per 5 ms frame (complexity 10)")
    func codecCost() throws {
        let frames = 2000
        let input = testSignal(frames: frames, noise: 0.3)
        let encoder = try OpusEncoderBox(bitrate: 192_000)
        let decoder = try OpusDecoderBox()
        var encodeMicros: [Double] = []
        var decodeMicros: [Double] = []
        var plcMicros: [Double] = []
        var out = [Float](repeating: 0, count: slotSamples)
        input.withUnsafeBufferPointer { samples in
            out.withUnsafeMutableBufferPointer { out in
                for frame in 0..<frames {
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    let packet = try! encoder.encode(samples.baseAddress! + frame * slotSamples)
                    let t1 = DispatchTime.now().uptimeNanoseconds
                    _ = decoder.decode(UnsafeRawPointer(packet.baseAddress!), count: packet.count, into: out.baseAddress!)
                    let t2 = DispatchTime.now().uptimeNanoseconds
                    encodeMicros.append(Double(t1 - t0) / 1000)
                    decodeMicros.append(Double(t2 - t1) / 1000)
                    if frame.isMultiple(of: 10) {
                        let t3 = DispatchTime.now().uptimeNanoseconds
                        _ = decoder.conceal(into: out.baseAddress!)
                        plcMicros.append(Double(DispatchTime.now().uptimeNanoseconds - t3) / 1000)
                    }
                }
            }
        }
        let encodeP50 = percentile(encodeMicros, 0.5)
        let encodeP99 = percentile(encodeMicros, 0.99)
        let decodeP50 = percentile(decodeMicros, 0.5)
        let decodeP99 = percentile(decodeMicros, 0.99)
        print(
            "opus cost per 5 ms frame: encode p50 \(Int(encodeP50)) µs p99 \(Int(encodeP99)) µs, "
                + "decode p50 \(Int(decodeP50)) µs p99 \(Int(decodeP99)) µs, PLC p50 \(Int(percentile(plcMicros, 0.5))) µs")
        // Generous bounds (a loaded test machine): a tenth / a twentieth of
        // the 5 ms frame budget.
        #expect(encodeP50 < 500)
        #expect(decodeP50 < 250)
    }

    @Test("Stream quality names and the receiver's codec readout")
    func qualityNames() {
        #expect(StreamQuality.default == .opus192)
        #expect(
            StreamQuality.allCases.map(\.displayName) == [
                "Opus 192 kbit/s", "Opus 128 kbit/s", "Opus 96 kbit/s", "Opus 64 kbit/s", "Opus 48 kbit/s",
                "PCM (uncompressed)",
            ])
        #expect(StreamQuality.receiverDescription(codec: .opus, payloadBytes: 240, frameSlots: 4) == "Opus 96 kbit/s · 20 ms")
        #expect(StreamQuality.receiverDescription(codec: .opus, payloadBytes: 120, frameSlots: 4) == "Opus 48 kbit/s · 20 ms")
        #expect(StreamQuality.receiverDescription(codec: .opus, payloadBytes: 120) == "Opus 192 kbit/s")
        #expect(StreamQuality.receiverDescription(codec: .opus, payloadBytes: 80) == "Opus 128 kbit/s")
        #expect(StreamQuality.receiverDescription(codec: .pcm16, payloadBytes: 960) == "PCM (uncompressed)")
        #expect(StreamQuality(rawValue: "opus128") == .opus128)
    }
}

// MARK: - Wire

struct OpusWireTests {
    @Test(
        "10 s of loud noise: every Opus datagram carries current + 4 previous frames in ≤ 1200 B",
        arguments: [192_000, 128_000])
    func datagramSizeIsBounded(bitrate: Int) throws {
        let quality: StreamQuality = bitrate == 192_000 ? .opus192 : .opus128
        let frames = 2000  // 10 s
        let signal = testSignal(frames: frames, amplitude: 0.3, noise: 0.69)
        let (datagrams, _) = send(signal, quality: { _ in quality })
        let sizes = datagrams.map(\.bytes.count)
        let frameBytes = bitrate / 8 * AudioFormat.frameDurationMs / 1000
        let steady = AudioDatagram.encodedSize(
            payloadSizes: Array(repeating: frameBytes, count: AudioRedundancy.opusOffsets.count + 1))
        print("opus \(bitrate / 1000) kbit/s datagrams: max \(sizes.max()!) B, steady \(steady) B, N = \(AudioRedundancy.opusOffsets.count)")
        #expect(datagrams.count == frames)  // one datagram per frame
        #expect(sizes.max()! <= AudioFormat.maxDatagramBytes)
        #expect(sizes.dropFirst(AudioRedundancy.opusOffsets.count).allSatisfy { $0 == steady })
        let last = try AudioDatagram.decode(datagrams.last!.bytes)
        #expect(last.codec == .opus)
        #expect(last.entries.map(\.offset) == [0, 1, 2, 3, 4])
    }

    @Test("A codec switch never mixes codecs in a datagram and still repeats the frames before it")
    func packerAcrossCodecSwitch() throws {
        var packer = RedundancyPacker()
        var byFrame: [Int: [AudioDatagram]] = [:]
        for frame in 0..<20 {
            let opus = frame >= 10
            let packet = AudioPacket(
                codec: opus ? .opus : .pcm16, sequence: UInt32(frame),
                sampleTime: UInt64(frame * AudioFormat.samplesPerFrame),
                payload: Data(repeating: UInt8(frame), count: opus ? 120 : 960))
            byFrame[frame] = try packer.pack(packet).map { try AudioDatagram.decode($0) }
        }
        // Every PCM frame 7...9 still gets its delayed copy (offset 3) in a
        // PCM datagram sent with Opus primaries 10...12.
        for frame in 10...12 {
            let datagrams = byFrame[frame]!
            #expect(datagrams[0].codec == .opus)
            #expect(datagrams[0].entries.map(\.offset) == Array(0...(frame - 10)).map(UInt8.init))
            #expect(datagrams.count == 2)
            #expect(datagrams[1].codec == .pcm16)
            #expect(datagrams[1].entries.map(\.offset) == [3])
            #expect(datagrams[1].packets()[0].payload == Data(repeating: UInt8(frame - 3), count: 960))
        }
        #expect(byFrame[13]!.count == 1)
        #expect(byFrame[14]!.first!.entries.map(\.offset) == [0, 1, 2, 3, 4])
    }
}

// MARK: - Playout

struct OpusPlayoutTests {
    @Test("Loss runs of 1...4 datagrams are fully recovered: bit-identical output, no Opus PLC")
    func shortLossRunsAreRecovered() {
        let frames = 600
        let signal = testSignal(frames: frames + 100, noise: 0.05)
        let (datagrams, _) = send(signal, quality: { _ in .opus192 })
        let lost: Set<Int> = [100, 200, 201, 300, 301, 302, 400, 401, 402, 403]
        let reference = play(cleanArrivals(datagrams), ticks: frames)
        let lossy = play(cleanArrivals(datagrams, dropping: lost), ticks: frames)
        #expect(lossy.jitter.recovered == lost.count)
        #expect(lossy.jitter.lost == 0)
        #expect(lossy.reader.opusPlcFrames == 0)
        #expect(lossy.reader.concealedFrames == 0)
        #expect(lossy.reader.decodeErrors == 0)
        #expect(lossy.output == reference.output)
        #expect(lossy.stream == PlayoutStream(codec: .opus, payloadBytes: 120))
    }

    @Test("Longer runs: the unrecoverable frames get Opus PLC, a short gap without fading, no click")
    func longerLossRunsUseOpusPLC() {
        let frames = 1000
        let signal = testSignal(frames: frames + 100)
        let (datagrams, _) = send(signal, quality: { _ in .opus192 })
        // Runs of 5 and 8: frames 0..<(run − 4) of each are in no surviving
        // datagram (1 + 4 frames); the rest come from the copies.
        let lost = Set(200..<205).union(500..<508)
        let reference = play(cleanArrivals(datagrams), ticks: frames)
        let lossy = play(cleanArrivals(datagrams, dropping: lost), ticks: frames)
        let referenceStep = maxStep(Array(reference.output[(slotSamples * 20)...]))
        let step = maxStep(Array(lossy.output[(slotSamples * 20)...]))
        print(
            "opus loss runs 5 + 8: lost=\(lossy.jitter.lost) recovered=\(lossy.jitter.recovered) "
                + "plc=\(lossy.reader.opusPlcFrames) waits=\(lossy.jitter.waitFrames + lossy.jitter.underrunFrames) "
                + "fadeOuts=\(lossy.reader.fadeOuts) "
                + "maxStep=\(String(format: "%.4f", step)) clean=\(String(format: "%.4f", referenceStep))")
        #expect(lossy.jitter.lost == 5)
        #expect(lossy.jitter.recovered == lost.count - 5)
        // Every concealed slot is Opus PLC: the 5 lost frames plus the slots
        // the buffer waited while the 8-datagram run left it empty.
        #expect(lossy.reader.opusPlcFrames == lossy.reader.concealedFrames)
        #expect(lossy.reader.opusPlcFrames == 5 + lossy.jitter.waitFrames + lossy.jitter.underrunFrames)
        #expect(lossy.reader.fadeOuts == 0)
        #expect(lossy.reader.decodeErrors == 0)
        #expect(step <= max(referenceStep, sineMaxStep(frequency: 1000)) * 1.25)
        // The concealed slot (the first that differs from the clean run)
        // stays near full level: no fade, no dropout.
        let first = lossy.output.indices.first { abs(lossy.output[$0] - reference.output[$0]) > 1e-6 }!
        let slot = (first / slotSamples * slotSamples)..<(first / slotSamples * slotSamples + slotSamples)
        #expect(rms(lossy.output[slot]) > 0.5 * rms(reference.output[slot]))
    }

    @Test("A long outage fades the Opus PLC to silence and fades back in without a click")
    func longOutageFadesOut() {
        let frames = 1000
        let signal = testSignal(frames: frames + 100)
        let (datagrams, _) = send(signal, quality: { _ in .opus192 })
        let lost = Set(400..<420)  // 100 ms: 16 frames unrecoverable
        let reference = play(cleanArrivals(datagrams), ticks: frames)
        let lossy = play(cleanArrivals(datagrams, dropping: lost), ticks: frames)
        let step = maxStep(Array(lossy.output[(slotSamples * 20)...]))
        let referenceStep = maxStep(Array(reference.output[(slotSamples * 20)...]))
        print(
            "opus 100 ms outage: lost=\(lossy.jitter.lost) plc=\(lossy.reader.opusPlcFrames) "
                + "fadeOuts=\(lossy.reader.fadeOuts) fadeIns=\(lossy.reader.fadeIns) maxStep=\(String(format: "%.4f", step))")
        #expect(lossy.jitter.lost == 16)
        #expect(lossy.reader.fadeOuts == 1)
        #expect(lossy.reader.fadeIns == 1)
        // 20 ms hold + 40 ms fade = 12 slots of PLC, then silence.
        #expect(lossy.reader.opusPlcFrames == 12)
        #expect(step <= max(referenceStep, sineMaxStep(frequency: 1000)) * 1.25)
    }

    @Test("Field replay with Opus 192: bursty, lossy Wi-Fi plays gap-free, every loss recovered")
    func fieldReplay() {
        // The M2.8 field evidence: 100–180 ms Wi-Fi bursts roughly every 8 s,
        // 1 % independent datagram loss, 2–8 ms base delay; 120 s.
        let seconds = 120.0
        let frames = Int(seconds / AudioFormat.frameDuration)
        let warmUpTicks = Int(20.0 / AudioFormat.frameDuration)
        var state: UInt64 = 0xC0FF_EE28
        func uniform(_ low: Double, _ high: Double) -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return low + Double(state >> 11) * 0x1.0p-53 * (high - low)
        }
        var bursts: [(start: Double, end: Double)] = []
        var t = uniform(2, 6)
        while t < seconds {
            bursts.append((t, t + uniform(0.100, 0.180)))
            t += uniform(6, 10)
        }
        let (datagrams, _) = send(testSignal(frames: frames + 200), quality: { _ in .opus192 })
        var arrivals: [(Data, TimeInterval)] = []
        var dropped = 0
        for datagram in datagrams {
            let base = uniform(0.002, 0.008)
            if uniform(0, 1) < 0.01 {
                dropped += 1
                continue
            }
            var arrival = datagram.sendTime + base
            if let burst = bursts.first(where: { $0.start <= datagram.sendTime && datagram.sendTime < $0.end }) {
                arrival = max(arrival, burst.end + uniform(0, 0.002))
            }
            arrivals.append((datagram.bytes, arrival))
        }
        // Split the run at the warm-up to read the counters there.
        let buffer = JitterBuffer(config: .latency(.balanced))
        let reader = PCMFrameReader(source: { payload, skipped in
            buffer.pop(payload: payload, skippedPayload: skipped)
        })
        arrivals.sort { $0.1 < $1.1 }
        var next = 0
        var output = [Float](repeating: 0, count: frames * slotSamples)
        var warm = (jitter: JitterBufferStats(), reader: ConcealmentStats())
        output.withUnsafeMutableBufferPointer { out in
            for tick in 0..<frames {
                let now = Double(tick) * AudioFormat.frameDuration
                while next < arrivals.count, arrivals[next].1 <= now {
                    if let datagram = try? AudioDatagram.decode(arrivals[next].0) {
                        for packet in datagram.packets() {
                            buffer.insert(packet, arrivalTime: arrivals[next].1)
                        }
                    }
                    next += 1
                }
                if tick == warmUpTicks {
                    warm = (buffer.stats, reader.stats)
                }
                reader.read(into: out.baseAddress! + tick * slotSamples, sampleCount: slotSamples)
            }
        }
        let jitter = buffer.stats
        let concealment = reader.stats
        let step = maxStep(Array(output[(warmUpTicks * slotSamples)...]))
        print(
            "opus replay[balanced] 120 s, \(bursts.count) bursts + 1% loss (\(dropped) datagrams dropped), after warm-up: "
                + "underruns=\(jitter.underruns - warm.jitter.underruns), lost=\(jitter.lost - warm.jitter.lost), "
                + "recovered=\(jitter.recovered - warm.jitter.recovered), "
                + "concealed=\(concealment.concealedFrames - warm.reader.concealedFrames), "
                + "plc=\(concealment.opusPlcFrames - warm.reader.opusPlcFrames), "
                + "target=\(jitter.targetFrames * AudioFormat.frameDurationMs) ms, maxStep=\(String(format: "%.4f", step))")
        #expect(jitter.underruns - warm.jitter.underruns <= 1)
        // Each frame rides in five datagrams: 1 % loss leaves nothing to conceal.
        #expect(jitter.lost - warm.jitter.lost == 0)
        #expect(jitter.recovered - warm.jitter.recovered > 100)
        #expect(concealment.concealedFrames - warm.reader.concealedFrames <= AudioFormat.frames(milliseconds: 40))
        #expect(concealment.decodeErrors == 0)
        #expect(step <= sineMaxStep(frequency: 1000) * 1.25)
    }

    @Test(
        "Codec switches PCM ↔ Opus and 192 ↔ 128 kbit/s mid-stream stay below the crackle threshold",
        arguments: [1000.0, 440.0, 2500.0])
    func codecSwitchIsSmooth(frequency: Double) {
        let frames = 1700
        let signal = testSignal(frames: frames + 100, frequency: frequency)
        let schedule: (Int) -> StreamQuality = { frame in
            switch frame {
            case ..<400: .pcm
            case ..<800: .opus192
            case ..<1000: .opus128
            case ..<1200: .pcm
            case ..<1400: .opus128
            default: .opus192
            }
        }
        let (datagrams, packets) = send(signal, quality: schedule)
        #expect(packets[399].codec == .pcm16 && packets[400].codec == .opus)
        #expect(packets[799].payload.count == 120 && packets[800].payload.count == 80)
        let result = play(cleanArrivals(datagrams), ticks: frames)
        let step = maxStep(Array(result.output[(slotSamples * 20)...]))
        print(
            "codec switch[\(Int(frequency)) Hz]: maxStep=\(String(format: "%.4f", step)) "
                + "sine=\(String(format: "%.4f", sineMaxStep(frequency: frequency))) "
                + "crossfades=\(result.reader.crossfades) concealed=\(result.reader.concealedFrames)")
        #expect(result.jitter.lost == 0)
        #expect(result.reader.decodeErrors == 0)
        #expect(result.reader.concealedFrames == 0)
        // PCM → Opus, Opus → PCM, PCM → Opus; bitrate changes are seamless.
        #expect(result.reader.crossfades == 3)
        #expect(step <= sineMaxStep(frequency: frequency) * 1.25)
        #expect(result.stream == PlayoutStream(codec: .opus, payloadBytes: 120))
    }
}
