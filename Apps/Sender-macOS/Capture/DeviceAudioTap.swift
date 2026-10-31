import BridgeCore
import CoreAudio
import Foundation
import os

/// Errors thrown while creating the device-bound process tap pipeline.
enum DeviceAudioTapError: LocalizedError {
    case coreAudioFailure(stage: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case let .coreAudioFailure(stage, status):
            "\(stage) failed: \(Self.fourCharacterCode(status))"
        }
    }

    private static func fourCharacterCode(_ status: OSStatus) -> String {
        let code = UInt32(bitPattern: status)
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        let text = bytes.map { byte in
            (32...126).contains(byte) ? Character(UnicodeScalar(byte)) : "?"
        }
        return "'\(String(text))' (\(status))"
    }
}

/// Core Audio process tap bound to the "iPhone (Mac Audio Bridge)" virtual
/// device (Driver/Driver.cpp): it captures the audio of every process that
/// plays to that device — and nothing else. The device itself discards the
/// samples (null sink), so the Mac speakers stay silent while streaming; this
/// tap is the actual capture point.
///
/// The tap feeds a private aggregate device that uses the virtual device as
/// its main (clock) sub-device, so the IO cycle is clocked by our own 48 kHz
/// device instead of whatever hardware happens to be the system output. The
/// realtime IOProc only copies interleaved Float32 samples into an
/// `SPSCRingBuffer` — no allocation, no locks, no logging inside the callback.
///
/// See `docs/research/process-tap.md` for the call sequence and
/// `docs/virtual-device.md` for the whole-device picture.
@MainActor
final class DeviceAudioTap {
    /// Interleaved stereo Float32 at the tap's sample rate (the IOProc produces,
    /// the FrameConverter consumes).
    let ring = SPSCRingBuffer(capacity: DeviceAudioTap.ringCapacity)

    private static let ringCapacity = 131_072 // ≈ 1.4 s of 48 kHz interleaved stereo
    private static let ioQueueLabel = "dev.jash90.MacAudioBridge.tap-io"

    /// The tap's current sample rate (the virtual device's rate — 48 kHz).
    private(set) var sampleRate: Double = 0
    private(set) var isRunning = false

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: DeviceAudioTap.ioQueueLabel)
    private let logger = Logger(subsystem: "dev.jash90.MacAudioBridge", category: "device-audio-tap")

    /// Creates and starts the tap. Throws with a human-readable message on failure
    /// (e.g. when audio-capture permission was denied or the driver is gone).
    func start() throws {
        precondition(!isRunning)
        // 1. Translate our own PID into a process AudioObjectID. The tap covers
        //    every process EXCEPT ours: our own aggregate's IO writes into the
        //    virtual device, and excluding ourselves rules out any feedback.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var ownObject = AudioObjectID(kAudioObjectUnknown)
        var pidQualifier = ownPID
        var ownObjectSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pidQualifier,
            &ownObjectSize,
            &ownObject)
        guard status == noErr, ownObject != AudioObjectID(kAudioObjectUnknown) else {
            throw DeviceAudioTapError.coreAudioFailure(stage: "PID translation", status: status)
        }

        // 2. Device-bound tap: every process's audio destined for OUR device,
        //    stream 0 (the driver's single output stream — the tap format then
        //    matches that stream: 48 kHz stereo Float32). The excluding variant
        //    with only our own process excluded is the unambiguous "everything
        //    playing to this device except us" form (CATapDescription.h).
        //    The initializers are NS_REFINED_FOR_SWIFT without a Swift overlay,
        //    so the raw `__` name applies.
        let description = CATapDescription(
            __excludingProcesses: [ownObject as NSNumber],
            andDeviceUID: BridgeDevice.uid,
            withStream: 0)
        description.name = "mac-audio-bridge-tap"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            throw DeviceAudioTapError.coreAudioFailure(stage: "Creating process tap", status: status)
        }

        do {
            try readTapFormat()
        } catch {
            destroyTap()
            throw error
        }

        status = try createAggregateDevice(tapUUID: description.uuid)
        guard status == noErr else {
            destroyTap()
            throw DeviceAudioTapError.coreAudioFailure(stage: "Creating aggregate device", status: status)
        }

        // 6. IOProc on the realtime IO thread — it only copies the tap's input
        // into the ring buffer. The aggregate also has an output side (our null
        // device as a sub-device); the IO block leaves the output buffers
        // untouched, which is fine — the driver discards whatever is written.
        // The block MUST come from a nonisolated factory: this class is
        // @MainActor, so a closure literal written here would inherit
        // main-actor isolation and Swift 6's dynamic executor check traps when
        // CoreAudio invokes it on the IO queue (EXC_BREAKPOINT in
        // _dispatch_assert_queue_fail).
        let context = TapIOContext(ring: ring)
        var createdIOProc: AudioDeviceIOProcID?
        let ioBlock = DeviceAudioTap.makeIOBlock(context: context)
        status = AudioDeviceCreateIOProcIDWithBlock(&createdIOProc, aggregateID, ioQueue, ioBlock)
        guard status == noErr else {
            destroyAggregateDevice()
            destroyTap()
            throw DeviceAudioTapError.coreAudioFailure(stage: "Creating IOProc", status: status)
        }
        ioProcID = createdIOProc

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            destroyIOProc()
            destroyAggregateDevice()
            destroyTap()
            throw DeviceAudioTapError.coreAudioFailure(stage: "Starting device", status: status)
        }

        isRunning = true
        logger.info(
            "Device tap running at \(self.sampleRate, format: .fixed(precision: 0), privacy: .public) Hz")
    }

    /// Stops the tap and releases it. Teardown order: device → IOProc →
    /// aggregate → tap. The ring is NOT reset here — `reset()` is consumer-side
    /// only; the FrameConverter's queue (the ring's only consumer) resets it
    /// when the next run starts.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
        }
        destroyIOProc()
        destroyAggregateDevice()
        destroyTap()
        logger.info("Device tap stopped")
    }

    // MARK: - Setup steps

    /// 4. Reads the format the IOProc will deliver (the tapped stream's
    /// format: 48 kHz, Float32, 2 channels).
    private func readTapFormat() throws {
        var asbd = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &formatSize, &asbd)
        guard status == noErr, asbd.mSampleRate > 0 else {
            throw DeviceAudioTapError.coreAudioFailure(stage: "Reading tap format", status: status)
        }
        sampleRate = asbd.mSampleRate
    }

    /// 5. Private aggregate device: the virtual device as the main (clock)
    /// sub-device, plus the tap. `tapautostart` makes `AudioDeviceStart` wait
    /// for the first tapped audio instead of running dry while nothing plays.
    private func createAggregateDevice(tapUUID: UUID) throws -> OSStatus {
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "mac-audio-bridge-aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true, // required by tapautostart
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: BridgeDevice.uid, // clock = our device
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: BridgeDevice.uid],
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUID.uuidString, // must be set before this call
                ],
            ],
        ]
        return AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &aggregateID)
    }

    // MARK: - Realtime callback

    /// Builds the IOProc block in a nonisolated context so it carries no main-actor
    /// isolation. The block only touches the preallocated, Sendable `TapIOContext`:
    /// no allocation, no locks, no logging, no actor hops — realtime-thread rules.
    nonisolated private static func makeIOBlock(context: TapIOContext) -> AudioDeviceIOBlock {
        { _, inputData, _, _, _ in
            context.copyInterleavedStereo(from: inputData)
        }
    }

    // MARK: - Teardown helpers

    private func destroyIOProc() {
        guard let current = ioProcID else { return }
        AudioDeviceDestroyIOProcID(aggregateID, current)
        ioProcID = nil
    }

    private func destroyAggregateDevice() {
        guard aggregateID != AudioObjectID(kAudioObjectUnknown) else { return }
        AudioHardwareDestroyAggregateDevice(aggregateID)
        aggregateID = AudioObjectID(kAudioObjectUnknown)
    }

    private func destroyTap() {
        guard tapID != AudioObjectID(kAudioObjectUnknown) else { return }
        AudioHardwareDestroyProcessTap(tapID)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
}

/// State captured by the realtime IOProc: the ring buffer plus a preallocated scratch
/// area for interleaving non-interleaved input. Allocated once, off the IO thread.
private final class TapIOContext: @unchecked Sendable {
    private let ring: SPSCRingBuffer
    /// Interleave scratch: `scratchFrames` frames of interleaved stereo.
    private let scratch: UnsafeMutablePointer<Float>
    private static let scratchFrames = 1_024

    init(ring: SPSCRingBuffer) {
        self.ring = ring
        self.scratch = UnsafeMutablePointer<Float>.allocate(capacity: Self.scratchFrames * 2)
        self.scratch.initialize(repeating: 0, count: Self.scratchFrames * 2)
    }

    deinit {
        scratch.deallocate()
    }

    /// Copies the IO buffer list into the ring as interleaved stereo. Handles both
    /// layouts the tap can deliver: non-interleaved (2 AudioBuffers, one per channel)
    /// and interleaved (1 AudioBuffer). Frame counts derive from byte sizes —
    /// `AudioBuffer` carries no `mBytesPerFrame`.
    ///
    /// The list is indexed through `UnsafeMutableAudioBufferListPointer` so the
    /// variable-length C array is read in place: copying `bufferList.pointee` out
    /// would leave only ONE AudioBuffer of storage, and reading `mNumberBuffers`
    /// elements from that copy would run past its end. Allocation-free.
    func copyInterleavedStereo(from bufferList: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: bufferList))
        guard buffers.count > 0, let firstData = buffers[0].mData else { return }

        if buffers.count == 1 {
            // Interleaved stereo: one buffer, 2 Float32 per frame.
            let samples = firstData.assumingMemoryBound(to: Float.self)
            let sampleCount = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
            ring.write(samples, count: sampleCount / 2 * 2)
        } else if buffers.count >= 2 {
            // Non-interleaved stereo: one mono Float32 buffer per channel.
            guard let leftData = buffers[0].mData, let rightData = buffers[1].mData else { return }
            let left = leftData.assumingMemoryBound(to: Float.self)
            let right = rightData.assumingMemoryBound(to: Float.self)
            let frames = min(
                Int(buffers[0].mDataByteSize),
                Int(buffers[1].mDataByteSize)) / MemoryLayout<Float>.size
            var offset = 0
            while offset < frames {
                let chunk = min(frames - offset, Self.scratchFrames)
                for i in 0..<chunk {
                    scratch[i * 2] = left[offset + i]
                    scratch[i * 2 + 1] = right[offset + i]
                }
                ring.write(scratch, count: chunk * 2)
                offset += chunk
            }
        }
    }
}
