import BridgeCore
import CoreAudio
import Foundation
import os
import Synchronization

/// The Mac half of "Talk through iPhone": the mic jitter buffer, the
/// network-side ingest and the realtime reader that the feeder's IOProc
/// pulls from. Sendable: `ingest` runs on the UDP sender's queue, `reader`
/// on the feeder's IO thread, the rest on the main actor.
final class MicEngine: @unchecked Sendable {
    let jitterBuffer: JitterBuffer
    let reader: MicFrameReader
    private let logger = Logger(subsystem: "dev.jash90.MacAudioBridge", category: "mic")
    /// Datagrams are buffered only while the Mac asked for the mic.
    private let accepting = Atomic<Bool>(false)
    private let datagrams = Atomic<Int>(0)
    private let malformed = Atomic<Int>(0)
    private let lastArrivalNanos = Atomic<UInt64>(0)
    private let mutedFlag = Atomic<Bool>(false)
    private let profileValue = Atomic<UInt8>(StreamProfile.lan.rawValue)
    /// Confined to the ingest (UDP sender) queue.
    private let follower = Mutex(ProfileFollower())

    init() {
        let jitterBuffer = JitterBuffer(config: .mic(.lan))
        self.jitterBuffer = jitterBuffer
        reader = MicFrameReader(
            source: Self.makeSource(jitterBuffer), depthProbe: Self.makeDepthProbe(jitterBuffer))
    }

    // MARK: - Main actor

    /// A fresh run: stale audio dropped, the reader silent until frames come.
    func begin() {
        jitterBuffer.reset()
        follower.withLock { $0.reset() }
        reader.fadeOut = false
        reader.requestReset()
        lastArrivalNanos.store(0, ordering: .relaxed)
        accepting.store(true, ordering: .relaxed)
    }

    func end() {
        accepting.store(false, ordering: .relaxed)
        reader.fadeOut = true
    }

    /// Seconds since the last mic datagram (nil = none this run).
    var secondsSinceLastPacket: TimeInterval? {
        let last = lastArrivalNanos.load(ordering: .relaxed)
        guard last > 0 else { return nil }
        let now = DispatchTime.now().uptimeNanoseconds
        return now > last ? Double(now - last) / 1e9 : 0
    }

    var phoneMuted: Bool { mutedFlag.load(ordering: .relaxed) }
    var profile: StreamProfile { StreamProfile(rawValue: profileValue.load(ordering: .relaxed)) ?? .lan }
    var datagramCount: Int { datagrams.load(ordering: .relaxed) }
    var malformedCount: Int { malformed.load(ordering: .relaxed) }

    // MARK: - Network queue

    /// One datagram from the phone's flow that is a mic datagram.
    func ingest(_ data: Data) {
        guard accepting.load(ordering: .relaxed) else { return }
        let datagram: MicDatagram
        do {
            datagram = try MicDatagram.decode(data)
        } catch {
            malformed.wrappingAdd(1, ordering: .relaxed)
            return
        }
        let validSizes = datagram.entries.allSatisfy { entry in
            switch datagram.codec {
            case .opus: (1...JitterBuffer.maxFramePayloadBytes).contains(entry.payload.count)
            case .pcm16: entry.payload.count == MicFormat.pcm16FrameBytes
            }
        }
        guard validSizes, datagram.samplesPerFrame == MicFormat.samplesPerFrame else {
            malformed.wrappingAdd(1, ordering: .relaxed)
            return
        }
        let nanos = DispatchTime.now().uptimeNanoseconds
        if datagram.flags.contains(.discontinuity) {
            follower.withLock { $0.reset() }
        }
        let changed = follower.withLock { $0.observe(datagram.profile, sequence: datagram.sequence) }
        if let changed {
            jitterBuffer.retune(.mic(changed))
            profileValue.store(changed.rawValue, ordering: .relaxed)
            logger.info("Mic stream profile: \(changed.displayName, privacy: .public)")
        }
        let arrival = Double(nanos) / 1e9
        for packet in datagram.packets() {
            jitterBuffer.insert(packet, arrivalTime: arrival)
        }
        mutedFlag.store(datagram.flags.contains(.muted), ordering: .relaxed)
        datagrams.wrappingAdd(1, ordering: .relaxed)
        lastArrivalNanos.store(nanos, ordering: .relaxed)
    }

    // MARK: - Nonisolated factories (run on the IO thread)

    nonisolated private static func makeSource(_ jitterBuffer: JitterBuffer) -> MicFrameReader.Source {
        { payload, skipped in jitterBuffer.pop(payload: payload, skippedPayload: skipped) }
    }

    nonisolated private static func makeDepthProbe(_ jitterBuffer: JitterBuffer) -> MicFrameReader.DepthProbe {
        { jitterBuffer.playoutDepth() }
    }
}

/// Plays the mic reader's output into the driver's hidden feeder device
/// ("Mac Audio Bridge Mic Feed", UID `dev.jash90.MacAudioBridge.MicFeed`):
/// the driver copies the feeder's mixed output into its ring, and the
/// visible "iPhone Mic (Mac Audio Bridge)" reads it back for Meet / Teams.
///
/// The IOProc runs directly on the device's IO thread (no dispatch queue:
/// output must be filled synchronously) and only touches the preallocated
/// `FeederIOContext`: no allocation, no locks of its own, no logging.
@MainActor
final class MicFeeder {
    static let feedUID = "dev.jash90.MacAudioBridge.MicFeed"
    /// Requested IO buffer (5.3 ms): the feeder writes a buffer ahead of the
    /// device clock, so a small one keeps the mic path short.
    private static let bufferFrames: UInt32 = 256
    /// Wait for the reader's 5 ms fade before stopping the IO.
    private static let stopDelay: Duration = .milliseconds(40)

    private let engine: MicEngine
    private let logger = Logger(subsystem: "dev.jash90.MacAudioBridge", category: "mic-feeder")
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var context: FeederIOContext?
    private var pendingStop: Task<Void, Never>?
    private(set) var isRunning = false

    init(engine: MicEngine) {
        self.engine = engine
    }

    /// Starts the feeder IO (idempotent). Fails when the driver has no
    /// feeder device (an older driver is installed).
    @discardableResult
    func start() -> Bool {
        pendingStop?.cancel()
        pendingStop = nil
        if isRunning { return true }
        guard let id = BridgeDevice.deviceID(uid: Self.feedUID) else {
            logger.error("Mic feeder device not found — the installed driver predates the mic")
            return false
        }
        deviceID = id
        setBufferFrameSize(Self.bufferFrames)
        let context = FeederIOContext(reader: engine.reader)
        var created: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&created, id, nil, Self.makeIOBlock(context: context))
        guard status == noErr, let created else {
            logger.error("Mic feeder: creating the IOProc failed (\(status))")
            return false
        }
        status = AudioDeviceStart(id, created)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(id, created)
            logger.error("Mic feeder: starting the device failed (\(status))")
            return false
        }
        ioProcID = created
        self.context = context
        isRunning = true
        logger.info("Mic feeder running")
        return true
    }

    /// Fades out, then stops the IO.
    func stop() {
        guard isRunning, pendingStop == nil else { return }
        engine.reader.fadeOut = true
        pendingStop = Task { [weak self] in
            try? await Task.sleep(for: Self.stopDelay)
            guard !Task.isCancelled else { return }
            self?.stopNow()
        }
    }

    func stopNow() {
        pendingStop?.cancel()
        pendingStop = nil
        guard isRunning, let ioProcID else { return }
        AudioDeviceStop(deviceID, ioProcID)
        AudioDeviceDestroyIOProcID(deviceID, ioProcID)
        self.ioProcID = nil
        context = nil
        isRunning = false
        logger.info("Mic feeder stopped")
    }

    private func setBufferFrameSize(_ frames: UInt32) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = frames
        // Best effort: the HAL clamps or refuses sizes outside the range.
        _ = AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    /// Built in a nonisolated context: no main-actor isolation on the IO
    /// thread (Swift 6's executor check would trap).
    nonisolated private static func makeIOBlock(context: FeederIOContext) -> AudioDeviceIOBlock {
        { _, _, _, outputData, _ in
            context.render(into: outputData)
        }
    }
}

/// State captured by the feeder IOProc: the reader and a preallocated
/// mono scratch buffer.
private final class FeederIOContext: @unchecked Sendable {
    private let reader: MicFrameReader
    private static let scratchFrames = 8_192
    private let scratch: UnsafeMutablePointer<Float>

    init(reader: MicFrameReader) {
        self.reader = reader
        scratch = .allocate(capacity: Self.scratchFrames)
        scratch.initialize(repeating: 0, count: Self.scratchFrames)
    }

    deinit {
        scratch.deallocate()
    }

    /// IO thread: one mono read, copied to every channel of every buffer
    /// (the feeder stream is Float32 mono; more channels are duplicated).
    func render(into list: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard let first = buffers.first else { return }
        let channels = max(Int(first.mNumberChannels), 1)
        let frames = min(Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels), Self.scratchFrames)
        reader.read(into: scratch, sampleCount: frames)
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let destination = data.assumingMemoryBound(to: Float.self)
            let bufferChannels = max(Int(buffer.mNumberChannels), 1)
            let bufferFrames = min(Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * bufferChannels), frames)
            for frame in 0..<bufferFrames {
                let value = scratch[frame]
                for channel in 0..<bufferChannels {
                    destination[frame * bufferChannels + channel] = value
                }
            }
        }
    }
}
