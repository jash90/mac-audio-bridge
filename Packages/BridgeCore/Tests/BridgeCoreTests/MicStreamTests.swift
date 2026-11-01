import Foundation
import Testing
@testable import BridgeCore

private struct SplitMix {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform(_ low: Double = 0, _ high: Double = 1) -> Double {
        low + Double(next() >> 11) * 0x1.0p-53 * (high - low)
    }
}

private func micFrame(sequence: UInt32, codec: AudioCodec = .opus, bytes: Int = 50, flags: AudioPacketFlags = [])
    -> AudioPacket
{
    AudioPacket(
        codec: codec, flags: flags, sequence: sequence,
        sampleTime: UInt64(sequence) * UInt64(MicFormat.samplesPerFrame),
        payload: Data((0..<bytes).map { UInt8(truncatingIfNeeded: Int(sequence) &+ $0) }))
}

struct MicDatagramTests {
    @Test("LAN Opus: every datagram carries the frame and its three predecessors, ≤ 1200 B")
    func lanRoundTrip() throws {
        var packer = MicPacker()
        var seen: [UInt32: Int] = [:]
        for sequence in UInt32(0)..<20 {
            let datagrams = packer.pack(
                micFrame(sequence: sequence, flags: sequence == 0 ? .discontinuity : []), muted: sequence == 7)
            #expect(datagrams.count == 1)
            let data = try #require(datagrams.first)
            #expect(data.count <= AudioFormat.maxDatagramBytes)
            #expect(MicDatagram.isMicDatagram(data))
            let decoded = try MicDatagram.decode(data)
            #expect(decoded.encoded() == data)
            #expect(decoded.flags.contains(.muted) == (sequence == 7))
            let packets = decoded.packets()
            #expect(packets.count == min(Int(sequence) + 1, 4))
            #expect(packets[0].sequence == sequence && !packets[0].isRedundant)
            #expect(packets[0].flags.contains(.discontinuity) == (sequence == 0))
            for packet in packets {
                #expect(packet.payload == micFrame(sequence: packet.sequence).payload)
                #expect(packet.sampleTime == UInt64(packet.sequence) * 480)
                seen[packet.sequence, default: 0] += 1
            }
            if sequence >= 3 { #expect(data.count == 24 + 4 * (3 + 50)) }
        }
        #expect(seen[10] == 4)
    }

    @Test("WAN Opus: two frames per datagram plus the four before them")
    func wanRoundTrip() throws {
        var packer = MicPacker()
        packer.profile = .wan
        var datagrams: [Data] = []
        for sequence in UInt32(0)..<12 {
            datagrams += packer.pack(micFrame(sequence: sequence, bytes: 40))
        }
        #expect(datagrams.count == 6)
        let last = try MicDatagram.decode(datagrams[5])
        #expect(last.profile == .wan && last.primaryCount == 2)
        let packets = last.packets()
        #expect(packets.filter { !$0.isRedundant }.map(\.sequence) == [10, 11])
        #expect(Set(packets.filter(\.isRedundant).map(\.sequence)) == [6, 7, 8, 9])
        #expect(datagrams[5].count == 24 + 6 * 43)
        #expect(datagrams.allSatisfy { $0.count <= AudioFormat.maxDatagramBytes })
    }

    @Test("PCM16 fallback: one 960 B frame per datagram, no copies")
    func pcmRoundTrip() throws {
        var packer = MicPacker()
        for sequence in UInt32(0)..<5 {
            let data = try #require(packer.pack(micFrame(sequence: sequence, codec: .pcm16, bytes: 960)).first)
            #expect(data.count == 24 + 3 + 960)
            let packets = try MicDatagram.decode(data).packets()
            #expect(packets.count == 1 && packets[0].codec == .pcm16)
        }
    }

    @Test("Mic datagrams and playback datagrams never parse as each other")
    func streamsAreDistinct() throws {
        var packer = MicPacker()
        let mic = try #require(packer.pack(micFrame(sequence: 1)).first)
        #expect(throws: AudioPacketError.unsupportedVersion(5)) { try AudioDatagram.decode(mic) }
        #expect(ReceiverKeepalive.decode(mic) == nil)
        let playback = AudioPacket(codec: .opus, sequence: 1, sampleTime: 240, payload: Data(count: 120)).encoded()
        #expect(!MicDatagram.isMicDatagram(playback))
        #expect(throws: AudioPacketError.unsupportedVersion(4)) { try MicDatagram.decode(playback) }
        #expect(!MicDatagram.isMicDatagram(ReceiverKeepalive.encode([])))
        var truncated = mic
        truncated.removeLast()
        #expect(throws: AudioPacketError.malformedEntries) { try MicDatagram.decode(truncated) }
    }
}

struct MicControlTests {
    @Test("micStart / micStop / micState round trip as version 4")
    func roundTrips() throws {
        let messages: [ControlMessage] = [
            .micStart, .micStop,
            .micState(MicState(armed: true, sending: false, muted: false)),
            .micState(MicState(armed: false, sending: false, muted: true, problem: "Microphone access is off")),
        ]
        for message in messages {
            #expect(message.requiredVersion == ControlProtocol.micVersion)
            var decoder = ControlFrameDecoder()
            let payloads = try decoder.append(message.frame())
            #expect(try ControlMessage.decode(payload: payloads[0]) == message)
            let probe = try JSONSerialization.jsonObject(with: message.payload()) as? [String: Any]
            #expect(probe?["v"] as? Int == 4)
        }
        #expect(String(decoding: ControlMessage.micStart.payload(), as: UTF8.self) == #"{"type":"micStart","v":4}"#)
    }

    @Test("Version gating: v4 is the mic version; a mic message under an older envelope is malformed")
    func versionGating() {
        #expect(ControlProtocol.version == 4)
        #expect(ControlProtocol.micVersion == 4)
        #expect(ControlProtocol.mediaVersion == 2)
        for text in [#"{"v":3,"type":"micStart"}"#, #"{"v":3,"type":"micState","mic":{"armed":true,"sending":true,"muted":false}}"#, #"{"v":4,"type":"micState"}"#] {
            #expect(throws: ControlProtocolError.malformed) { try ControlMessage.decode(payload: Data(text.utf8)) }
        }
        #expect(throws: ControlProtocolError.versionMismatch(5)) {
            try ControlMessage.decode(payload: Data(#"{"v":5,"type":"micStart"}"#.utf8))
        }
        // Older messages keep their envelope versions.
        #expect(ControlMessage.connect.requiredVersion == 1)
        #expect(ControlMessage.media(.togglePlayPause).requiredVersion == 2)
    }
}

struct MicDemandTests {
    @Test("Start when an app opens the mic, stop only after a 2 s grace")
    func grace() {
        var demand = MicDemand()
        #expect(demand.update(inUse: false, now: 0) == nil)
        #expect(demand.update(inUse: true, now: 1) == .start)
        #expect(demand.update(inUse: true, now: 1.5) == nil)
        #expect(demand.update(inUse: false, now: 2) == nil)
        #expect(demand.tick(now: 3.9) == nil)
        // Reopened within the grace (device picker change): no restart.
        #expect(demand.update(inUse: true, now: 3.95) == nil)
        #expect(demand.update(inUse: false, now: 5) == nil)
        #expect(demand.tick(now: 6.99) == nil)
        #expect(demand.tick(now: 7) == .stop)
        #expect(!demand.active)
        #expect(demand.tick(now: 9) == nil)
        #expect(demand.update(inUse: true, now: 10) == .start)
    }
}

struct VoiceOpusTests {
    @Test("10 ms mono voice frames: fixed size at CBR, decode back to a matching signal")
    func roundTrip() throws {
        let encoder = try VoiceOpusEncoder(bitrate: 40_000)
        let decoder = try VoiceOpusDecoder()
        var pcm = [Float](repeating: 0, count: 480)
        var out = [Float](repeating: 0, count: 480)
        var energyIn: Float = 0
        var energyOut: Float = 0
        for frame in 0..<100 {
            for i in 0..<480 {
                let t = Double(frame * 480 + i) / 48_000
                pcm[i] = Float(0.3 * sin(2 * .pi * 300 * t) + 0.15 * sin(2 * .pi * 1100 * t))
            }
            let packet = try pcm.withUnsafeBufferPointer { try encoder.encode($0.baseAddress!) }
            #expect(packet.count == 50)
            let bytes = Array(packet)
            let decoded = bytes.withUnsafeBytes { raw in
                out.withUnsafeMutableBufferPointer { decoder.decode(raw.baseAddress!, count: raw.count, into: $0.baseAddress!) }
            }
            #expect(decoded == 480)
            if frame >= 10 {
                energyIn += pcm.reduce(0) { $0 + $1 * $1 }
                energyOut += out.reduce(0) { $0 + $1 * $1 }
            }
        }
        #expect(energyOut > energyIn * 0.5 && energyOut < energyIn * 1.5)
        let concealed = out.withUnsafeMutableBufferPointer { decoder.conceal(into: $0.baseAddress!) }
        #expect(concealed == 480)
        try encoder.setBitrate(32_000)
        let small = try pcm.withUnsafeBufferPointer { try encoder.encode($0.baseAddress!) }
        #expect(small.count == 40)
    }
}

struct LinearResamplerTests {
    @Test("44.1 kHz → 48 kHz keeps the rate and the waveform continuous across blocks")
    func resample() {
        var resampler = LinearResampler(inputRate: 44_100)
        var output: [Float] = []
        var block = [Float](repeating: 0, count: 441)
        var scratch = [Float](repeating: 0, count: resampler.maxOutput(forInput: 441))
        var index = 0
        for _ in 0..<100 {  // 1 s
            for i in 0..<441 {
                block[i] = Float(0.5 * sin(2 * .pi * 440 * Double(index) / 44_100))
                index += 1
            }
            let written = block.withUnsafeBufferPointer { input in
                scratch.withUnsafeMutableBufferPointer {
                    resampler.process(input.baseAddress!, inputCount: 441, into: $0.baseAddress!, outputCapacity: $0.count)
                }
            }
            output += scratch[0..<written]
        }
        #expect(abs(output.count - 48_000) <= 1)
        var worst: Float = 0
        for i in 1..<output.count { worst = max(worst, abs(output[i] - output[i - 1])) }
        #expect(worst <= sineMaxStep(frequency: 440) * 1.05)
        // Against the ideal sine at 48 kHz (linear interpolation error is tiny at 440 Hz).
        var error: Float = 0
        for i in 0..<output.count {
            error = max(error, abs(output[i] - Float(0.5 * sin(2 * .pi * 440 * Double(i) / 48_000))))
        }
        #expect(error < 0.01)
        var passthrough = LinearResampler(inputRate: 48_000)
        #expect(passthrough.isPassthrough)
        let n = block.withUnsafeBufferPointer { input in
            scratch.withUnsafeMutableBufferPointer {
                passthrough.process(input.baseAddress!, inputCount: 441, into: $0.baseAddress!, outputCapacity: $0.count)
            }
        }
        #expect(n == 441 && Array(scratch[0..<441]) == block)
    }
}

// MARK: - Pipeline simulation (phone capture → wire → Mac jitter buffer → reader)

private struct MicPipelineResult {
    var jitter = JitterBufferStats()
    var reader = MicReaderStats()
    /// Largest sample-to-sample step after warm-up.
    var maxStep: Float = 0
    var minDepth = Int.max
    var maxDepth = 0
    var maxTarget = 0
    var meanFillFrames: Double = 0
    var meanDelay: Double = 0
    var underrunsAfterWarmUp = 0
    var concealedAfterWarmUp = 0
}

/// Runs the whole mic path for `seconds` of Mac time. The phone's clock
/// runs `ppm` fast (frames are produced at 100 × (1 + ppm·10⁻⁶) per Mac
/// second); `delay` gives each datagram's one-way delay, nil = lost.
private func runMicPipeline(
    seconds: Double, ppm: Double, codec: AudioCodec, profile: StreamProfile, frequency: Double = 440,
    warmUp: Double = 3, seed: UInt64, delay: (inout SplitMix, Double) -> Double?
) throws -> MicPipelineResult {
    let jitterBuffer = JitterBuffer(config: .mic(profile))
    let reader = MicFrameReader(
        source: { jitterBuffer.pop(payload: $0, skippedPayload: $1) },
        depthProbe: { jitterBuffer.playoutDepth() })
    let encoder = codec == .opus ? try VoiceOpusEncoder(bitrate: MicFormat.bitrate(for: profile)) : nil
    var packer = MicPacker()
    packer.profile = profile
    var random = SplitMix(state: seed)
    var pending: [(arrival: Double, data: Data)] = []
    var pcm = [Float](repeating: 0, count: 480)
    let framePeriod = MicFormat.frameDuration / (1 + ppm * 1e-6)
    var nextFrame: UInt32 = 0
    var phoneSample = 0
    let chunk = 512
    var out = [Float](repeating: 0, count: chunk)
    var result = MicPipelineResult()
    var previous: Float = 0
    var macSamples = 0
    var fillSum = 0.0
    var fillCount = 0
    var delaySum = 0.0
    var delayCount = 0
    var warmUpStats: (underruns: Int, concealed: Int)?
    let totalSamples = Int(seconds * MicFormat.sampleRate)

    while macSamples < totalSamples {
        let now = Double(macSamples) / MicFormat.sampleRate
        // Phone: every frame completed by `now` is encoded and sent.
        while Double(nextFrame + 1) * framePeriod <= now {
            let sendTime = Double(nextFrame + 1) * framePeriod
            for i in 0..<480 {
                pcm[i] = Float(0.5 * sin(2 * .pi * frequency * Double(phoneSample + i) / 48_000))
            }
            phoneSample += 480
            let payload: Data
            if let encoder {
                payload = Data(try pcm.withUnsafeBufferPointer { try encoder.encode($0.baseAddress!) })
            } else {
                payload = pcm.withUnsafeBufferPointer { samples in
                    var data = Data(count: 960)
                    data.withUnsafeMutableBytes { raw in
                        for i in 0..<480 {
                            let value = Int16(max(-32767, min(32767, (samples[i] * 32767).rounded())))
                            raw.storeBytes(of: value.littleEndian, toByteOffset: i * 2, as: Int16.self)
                        }
                    }
                    return data
                }
            }
            let frame = AudioPacket(
                codec: codec, flags: nextFrame == 0 ? .discontinuity : [], sequence: nextFrame,
                sampleTime: UInt64(nextFrame) * 480, payload: payload)
            for datagram in packer.pack(frame) {
                #expect(datagram.count <= AudioFormat.maxDatagramBytes)
                if let oneWay = delay(&random, sendTime) {
                    pending.append((sendTime + oneWay, datagram))
                    delaySum += oneWay
                    delayCount += 1
                }
            }
            nextFrame += 1
        }
        // Network → Mac: deliver what has arrived (any order).
        var index = 0
        while index < pending.count {
            if pending[index].arrival <= now {
                let datagram = try MicDatagram.decode(pending[index].data)
                for packet in datagram.packets() {
                    jitterBuffer.insert(packet, arrivalTime: pending[index].arrival)
                }
                pending.swapAt(index, pending.count - 1)
                pending.removeLast()
            } else {
                index += 1
            }
        }
        // Feeder IO cycle.
        out.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, sampleCount: chunk) }
        macSamples += chunk
        if now >= warmUp {
            if warmUpStats == nil {
                let stats = jitterBuffer.stats
                warmUpStats = (stats.underruns, reader.stats.concealedFrames)
            }
            out.withUnsafeBufferPointer { samples in
                var worst = result.maxStep
                var last = previous
                for i in 0..<chunk {
                    let step = abs(samples[i] - last)
                    if step > worst { worst = step }
                    last = samples[i]
                }
                result.maxStep = worst
                previous = last
            }
            let (depth, target) = jitterBuffer.playoutDepth()
            result.minDepth = min(result.minDepth, depth)
            result.maxDepth = max(result.maxDepth, depth)
            result.maxTarget = max(result.maxTarget, target)
            fillSum += Double(depth)
            fillCount += 1
        } else {
            previous = out[chunk - 1]
        }
    }
    result.jitter = jitterBuffer.stats
    result.reader = reader.stats
    result.meanFillFrames = fillCount > 0 ? fillSum / Double(fillCount) : 0
    result.meanDelay = delayCount > 0 ? delaySum / Double(delayCount) : 0
    result.underrunsAfterWarmUp = result.jitter.underruns - (warmUpStats?.underruns ?? 0)
    result.concealedAfterWarmUp = result.reader.concealedFrames - (warmUpStats?.concealed ?? 0)
    return result
}

private func describe(_ result: MicPipelineResult, label: String) -> String {
    let latencyMs = (result.meanFillFrames + 0.5) * 10 + result.meanDelay * 1000
    return "\(label): target≤\(result.maxTarget * 10) ms, depth \(result.minDepth)…\(result.maxDepth) frames, "
        + "latency≈\(Int(latencyMs.rounded())) ms (buffer + network), underruns=\(result.underrunsAfterWarmUp), "
        + "lost=\(result.jitter.lost), recovered=\(result.jitter.recovered), concealed=\(result.concealedAfterWarmUp), "
        + "dropped=\(result.reader.samplesDropped), inserted=\(result.reader.samplesInserted), "
        + "maxStep=\(String(format: "%.4f", result.maxStep))"
}

struct MicJitterTests {
    @Test("LAN jitter (1–9 ms, 1 % spikes of +25 ms, 1 % loss): small target, no dropouts")
    func lan() throws {
        let result = try runMicPipeline(seconds: 60, ppm: 30, codec: .opus, profile: .lan, seed: 0x51C1_0001) {
            random, _ in
            if random.uniform() < 0.01 { return nil }
            var delay = 0.001 + random.uniform(0, 0.008)
            if random.uniform() < 0.01 { delay += 0.025 }
            return delay
        }
        print(describe(result, label: "mic LAN"))
        #expect(result.maxTarget <= 6)  // ≤ 60 ms
        #expect(result.underrunsAfterWarmUp == 0)
        #expect(result.jitter.lost == 0)  // the copies recover isolated losses
        #expect(result.jitter.recovered > 0)
        #expect(result.jitter.overflowDropped == 0)
    }

    @Test("Cellular-like jitter (40 ms + long tail, 2 % loss, 150 ms stalls): WAN profile rides it out")
    func cellular() throws {
        var stallUntil = 0.0
        let result = try runMicPipeline(seconds: 60, ppm: -50, codec: .opus, profile: .wan, seed: 0x51C1_0002) {
            random, sendTime in
            if random.uniform() < 0.02 { return nil }
            if sendTime >= stallUntil, random.uniform() < 0.004 {  // ~ every 5 s
                stallUntil = sendTime + 0.15
            }
            var delay = 0.040 + min(0.150, -0.015 * log(max(random.uniform(), 1e-9)))
            if sendTime < stallUntil { delay += stallUntil - sendTime }
            return delay
        }
        print(describe(result, label: "mic cellular"))
        #expect(result.maxTarget <= 30)  // ≤ 300 ms
        #expect(result.underrunsAfterWarmUp <= 6)  // ≤ 6 per minute
        #expect(Double(result.jitter.lost) / Double(max(result.jitter.played, 1)) < 0.005)
        #expect(result.jitter.overflowDropped == 0)
    }

    @Test(
        "Clock drift ±200 ppm for 30 min: fill stays bounded, no dropouts, no discontinuity",
        arguments: [200.0, -200.0])
    func drift(ppm: Double) throws {
        let result = try runMicPipeline(
            seconds: 1800, ppm: ppm, codec: .pcm16, profile: .lan, seed: 0x51C1_0003
        ) { random, _ in
            0.002 + random.uniform(0, 0.003)
        }
        print(describe(result, label: "mic drift \(Int(ppm)) ppm"))
        // 200 ppm of 30 min at 48 kHz = 17 280 samples to absorb.
        let expected = abs(ppm) * 1e-6 * 48_000 * 1800
        let corrections = Double(ppm > 0 ? result.reader.samplesDropped : result.reader.samplesInserted)
        #expect(corrections > expected * 0.9 && corrections < expected * 1.1)
        #expect(result.underrunsAfterWarmUp == 0)
        #expect(result.concealedAfterWarmUp == 0)
        #expect(result.jitter.overflowDropped == 0)
        #expect(result.maxDepth - result.minDepth <= 4)
        #expect(result.maxDepth <= result.maxTarget + 3)
        #expect(result.maxStep <= sineMaxStep(frequency: 440) * 1.25)
    }
}

struct MicFrameReaderTests {
    @Test("Start fades in, fadeOut fades to silence, reset starts over silent")
    func fades() throws {
        let jitterBuffer = JitterBuffer(config: .mic(.lan))
        let reader = MicFrameReader(
            source: { jitterBuffer.pop(payload: $0, skippedPayload: $1) },
            depthProbe: { jitterBuffer.playoutDepth() })
        func frame(_ sequence: UInt32) -> AudioPacket {
            var data = Data(count: 960)
            data.withUnsafeMutableBytes { raw in
                for i in 0..<480 {
                    let v = Int16(0.5 * 32767 * sin(2 * .pi * 440 * Double(Int(sequence) * 480 + i) / 48_000))
                    raw.storeBytes(of: v.littleEndian, toByteOffset: i * 2, as: Int16.self)
                }
            }
            return AudioPacket(
                codec: .pcm16, flags: sequence == 0 ? .discontinuity : [], sequence: sequence,
                sampleTime: UInt64(sequence) * 480, payload: data)
        }
        var out = [Float](repeating: 0, count: 480)
        var all: [Float] = []
        for sequence in UInt32(0)..<60 {
            jitterBuffer.insert(frame(sequence), arrivalTime: Double(sequence) * 0.01)
            out.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, sampleCount: 480) }
            all += out
        }
        var worst: Float = 0
        for i in 1..<all.count { worst = max(worst, abs(all[i] - all[i - 1])) }
        #expect(worst <= sineMaxStep(frequency: 440) * 1.25)
        #expect(all.suffix(480).contains { abs($0) > 0.3 })
        reader.fadeOut = true
        out.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, sampleCount: 480) }
        #expect(out.suffix(200).allSatisfy { $0 == 0 })
        var fadeStep: Float = 0
        for i in 1..<480 { fadeStep = max(fadeStep, abs(out[i] - out[i - 1])) }
        #expect(fadeStep <= sineMaxStep(frequency: 440) * 1.25)
        reader.fadeOut = false
        reader.requestReset()
        jitterBuffer.reset()
        out.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, sampleCount: 480) }
        #expect(out.allSatisfy { $0 == 0 })
    }
}
