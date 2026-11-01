import AVFoundation
import BridgeCore
import Foundation
import os
import Synchronization

/// Realtime state of the capture sink node ("Talk through iPhone"): takes
/// the input node's buffers (any channel count, any rate), keeps the first
/// channel, converts it to 48 kHz mono (`LinearResampler`, a copy at
/// 48 kHz) and writes it into a lock-free ring that the send queue drains.
///
/// Realtime: `capture` touches only preallocated memory and atomics — no
/// allocation, no locks, no logging, no Swift concurrency. `configure` runs
/// on the main actor while the engine is stopped (no render in flight).
final class MicCaptureContext: @unchecked Sendable {
    /// 0.5 s of 48 kHz mono.
    let ring = SPSCRingBuffer(capacity: 24_000)
    let callbacks = Atomic<Int>(0)
    private static let scratchSamples = 8_192
    private let mono: UnsafeMutablePointer<Float>
    private let converted: UnsafeMutablePointer<Float>
    private var resampler = LinearResampler(inputRate: MicFormat.sampleRate)

    init() {
        mono = .allocate(capacity: Self.scratchSamples)
        mono.initialize(repeating: 0, count: Self.scratchSamples)
        converted = .allocate(capacity: Self.scratchSamples * 2)
        converted.initialize(repeating: 0, count: Self.scratchSamples * 2)
    }

    deinit {
        mono.deallocate()
        converted.deallocate()
    }

    /// Main actor, engine stopped.
    func configure(inputRate: Double) {
        resampler.reset(inputRate: inputRate)
    }

    /// Render thread.
    func capture(_ list: UnsafePointer<AudioBufferList>, frameCount: Int) {
        callbacks.add(1, ordering: .relaxed)
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, let data = first.mData else { return }
        let source = data.assumingMemoryBound(to: Float.self)
        let stride = max(Int(first.mNumberChannels), 1)
        let available = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * stride)
        let frames = min(frameCount, available, Self.scratchSamples)
        guard frames > 0 else { return }
        if stride == 1 {
            mono.update(from: source, count: frames)
        } else {
            for frame in 0..<frames {
                mono[frame] = source[frame * stride]
            }
        }
        let written = resampler.process(
            mono, inputCount: frames, into: converted, outputCapacity: Self.scratchSamples * 2)
        _ = ring.write(converted, count: written)
    }
}

/// Drains the capture ring every 5 ms on its own queue: 10 ms frames, a
/// level meter, Opus (PCM16 if the encoder cannot be created), redundancy
/// (`MicPacker`) and the hand-off to the UDP flow of the Mac that asked
/// (`send`, which hops to the receiver's queue). While armed but not asked,
/// frames only feed the meter.
///
/// Control from the main actor goes through atomics; everything else is
/// confined to `queue`.
final class MicSender: @unchecked Sendable {
    typealias Send = @Sendable (_ datagrams: [Data], _ sourceTag: UInt32) -> Void
    typealias ProfileProvider = @Sendable () -> StreamProfile

    private static let tickInterval: DispatchTimeInterval = .milliseconds(5)
    /// A backlog beyond this (the queue was held up) is dropped, oldest
    /// first, so the mic never lags behind.
    private static let maxBacklogFrames = 6

    private let queue = DispatchQueue(label: "dev.jash90.MacAudioBridge.mic-send", qos: .userInteractive)
    private let logger = Logger(subsystem: "dev.jash90.MacAudioBridge", category: "mic")
    private let ring: SPSCRingBuffer
    private let send: Send
    private let profileProvider: ProfileProvider

    private let sendingFlag = Atomic<Bool>(false)
    private let mutedFlag = Atomic<Bool>(false)
    private let target = Atomic<UInt32>(0)
    private let restartFlag = Atomic<Bool>(true)
    private let levelBits = Atomic<UInt32>(0)
    private let framesSent = Atomic<Int>(0)

    // Confined to `queue`:
    private var timer: DispatchSourceTimer?
    private var encoder: VoiceOpusEncoder?
    private var packer = MicPacker()
    private let frame: UnsafeMutablePointer<Float>
    private var sequence: UInt32 = 0
    private var sampleTime: UInt64 = 0
    private var level: Float = 0
    private var profile = StreamProfile.lan

    init(ring: SPSCRingBuffer, profile: @escaping ProfileProvider, send: @escaping Send) {
        self.ring = ring
        self.send = send
        profileProvider = profile
        frame = .allocate(capacity: MicFormat.samplesPerFrame)
        frame.initialize(repeating: 0, count: MicFormat.samplesPerFrame)
        do {
            encoder = try VoiceOpusEncoder(bitrate: MicFormat.lanBitrate)
        } catch {
            logger.error("Mic: Opus encoder unavailable (\(String(describing: error), privacy: .public)), sending PCM16")
        }
    }

    deinit {
        timer?.cancel()
        frame.deallocate()
    }

    // MARK: - Control (any thread)

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            ring.reset()
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval, leeway: .milliseconds(1))
            source.setEventHandler(handler: Self.makeTickHandler(sender: self))
            source.resume()
            timer = source
        }
    }

    func stop() {
        sendingFlag.store(false, ordering: .relaxed)
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            level = 0
            levelBits.store(0, ordering: .relaxed)
        }
    }

    /// Starts (tag ≠ nil) or stops sending to the Mac with that source tag.
    func setSending(to tag: UInt32?) {
        if let tag {
            target.store(tag, ordering: .relaxed)
            if !sendingFlag.load(ordering: .relaxed) {
                restartFlag.store(true, ordering: .relaxed)
            }
            sendingFlag.store(true, ordering: .relaxed)
        } else {
            sendingFlag.store(false, ordering: .relaxed)
        }
    }

    var isSending: Bool { sendingFlag.load(ordering: .relaxed) }

    var muted: Bool {
        get { mutedFlag.load(ordering: .relaxed) }
        set { mutedFlag.store(newValue, ordering: .relaxed) }
    }

    /// Decaying RMS of the captured signal (0...1), muted or not.
    var inputLevel: Float { Float(bitPattern: levelBits.load(ordering: .relaxed)) }

    var sentFrameCount: Int { framesSent.load(ordering: .relaxed) }

    // MARK: - Queue

    private func tick() {
        let frameSamples = MicFormat.samplesPerFrame
        var backlog = ring.availableToRead / frameSamples
        while backlog > Self.maxBacklogFrames {
            ring.read(into: frame, count: frameSamples)
            backlog -= 1
            restartFlag.store(true, ordering: .relaxed)
        }
        while ring.availableToRead >= frameSamples {
            ring.read(into: frame, count: frameSamples)
            process()
        }
    }

    private func process() {
        let frameSamples = MicFormat.samplesPerFrame
        var sumSquares: Float = 0
        for i in 0..<frameSamples {
            sumSquares += frame[i] * frame[i]
        }
        level = max((sumSquares / Float(frameSamples)).squareRoot(), level * 0.85)
        levelBits.store(level.bitPattern, ordering: .relaxed)
        guard sendingFlag.load(ordering: .relaxed) else { return }

        let currentProfile = profileProvider()
        if currentProfile != profile {
            profile = currentProfile
            try? encoder?.setBitrate(MicFormat.bitrate(for: currentProfile))
        }
        packer.profile = profile
        let muted = mutedFlag.load(ordering: .relaxed)
        if muted {
            frame.update(repeating: 0, count: frameSamples)
        }
        var flags: AudioPacketFlags = []
        if restartFlag.exchange(false, ordering: .relaxed) {
            flags = .discontinuity
            encoder?.reset()
            packer.reset()
        }
        let payload: Data
        if let encoder, let bytes = try? encoder.encode(frame) {
            payload = Data(buffer: bytes)
        } else {
            var pcm = Data(count: MicFormat.pcm16FrameBytes)
            pcm.withUnsafeMutableBytes { raw in
                for i in 0..<frameSamples {
                    let value = Int16(max(-32767, min(32767, (frame[i] * 32767).rounded())))
                    raw.storeBytes(of: value.littleEndian, toByteOffset: i * 2, as: Int16.self)
                }
            }
            payload = pcm
        }
        let packet = AudioPacket(
            codec: encoder == nil ? .pcm16 : .opus, flags: flags, sequence: sequence,
            sampleTime: sampleTime, payload: payload)
        sequence &+= 1
        sampleTime &+= UInt64(frameSamples)
        let datagrams = packer.pack(packet, muted: muted)
        framesSent.wrappingAdd(1, ordering: .relaxed)
        if !datagrams.isEmpty {
            send(datagrams, target.load(ordering: .relaxed))
        }
    }

    nonisolated private static func makeTickHandler(sender: MicSender) -> @Sendable () -> Void {
        { [weak sender] in sender?.tick() }
    }
}
