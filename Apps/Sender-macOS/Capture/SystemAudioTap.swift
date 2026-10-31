import BridgeCore
import CoreAudio
import Foundation
import os

/// Errors thrown while creating the process tap pipeline.
enum SystemAudioTapError: LocalizedError {
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

/// Global stereo Core Audio process tap that captures every process's output except
/// our own. The realtime IOProc only copies interleaved Float32 samples into an
/// `SPSCRingBuffer` — no allocation, no locks, no logging inside the callback.
///
/// See `docs/research/process-tap.md` for the call sequence and its pitfalls.
@MainActor
final class SystemAudioTap {
    /// Interleaved stereo Float32 at the tap's sample rate (the IOProc produces,
    /// the FrameConverter consumes).
    let ring = SPSCRingBuffer(capacity: SystemAudioTap.ringCapacity)

    private static let ringCapacity = 131_072 // ≈ 1.4 s of 48 kHz interleaved stereo
    private static let ioQueueLabel = "dev.jash90.MacAudioBridge.tap-io"

    /// The tap's current sample rate (typically the default output device's rate).
    private(set) var sampleRate: Double = 0
    private(set) var isRunning = false

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: SystemAudioTap.ioQueueLabel)
    private let logger = Logger(subsystem: "dev.jash90.MacAudioBridge", category: "system-audio-tap")

    /// Creates and starts the tap. Throws with a human-readable message on failure
    /// (e.g. when audio-capture permission was denied).
    func start() throws {
        precondition(!isRunning)
        // 1. Translate our own PID into a process AudioObjectID (the tap excludes it).
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
            throw SystemAudioTapError.coreAudioFailure(stage: "PID translation", status: status)
        }

        // 2. Global tap: every process that outputs audio except ours, stereo mixdown,
        //    still audible locally. The CATapDescription initializers are
        //    NS_REFINED_FOR_SWIFT without a Swift overlay, so the raw `__` name applies.
        let description = CATapDescription(__stereoGlobalTapButExcludeProcesses: [ownObject as NSNumber])
        description.name = "mac-audio-bridge-tap"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            throw SystemAudioTapError.coreAudioFailure(stage: "Creating process tap", status: status)
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
            throw SystemAudioTapError.coreAudioFailure(stage: "Creating aggregate device", status: status)
        }

        // 6. IOProc on the realtime IO thread — it only copies into the ring buffer.
        let context = IOContext(ring: ring)
        var createdIOProc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&createdIOProc, aggregateID, ioQueue) { _, inputData, _, _, _ in
            context.copyInterleavedStereo(from: inputData)
        }
        guard status == noErr else {
            destroyAggregateDevice()
            destroyTap()
            throw SystemAudioTapError.coreAudioFailure(stage: "Creating IOProc", status: status)
        }
        ioProcID = createdIOProc

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            destroyIOProc()
            destroyAggregateDevice()
            destroyTap()
            throw SystemAudioTapError.coreAudioFailure(stage: "Starting device", status: status)
        }

        isRunning = true
        logger.info(
            "Tap running at \(self.sampleRate, format: .fixed(precision: 0), privacy: .public) Hz")
    }

    /// Stops the tap. Teardown order: device → IOProc → aggregate → tap.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
        }
        destroyIOProc()
        destroyAggregateDevice()
        destroyTap()
        ring.reset()
        logger.info("Tap stopped")
    }

    // MARK: - Setup steps

    /// 4. Reads the format the IOProc will deliver (device rate, Float32, 2 channels).
    private func readTapFormat() throws {
        var asbd = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &formatSize, &asbd)
        guard status == noErr, asbd.mSampleRate > 0 else {
            throw SystemAudioTapError.coreAudioFailure(stage: "Reading tap format", status: status)
        }
        sampleRate = asbd.mSampleRate
    }

    /// 5. Private input-only aggregate device that contains the tap.
    private func createAggregateDevice(tapUUID: UUID) throws -> OSStatus {
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "mac-audio-bridge-aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true, // required by tapautostart
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [] as [[String: Any]], // input-only
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
private final class IOContext: @unchecked Sendable {
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
    func copyInterleavedStereo(from bufferList: UnsafePointer<AudioBufferList>) {
        let list = bufferList.pointee
        // AudioBufferList.mBuffers is a variable-length C array — expose it as a Swift
        // buffer so both buffers of a non-interleaved list are addressable.
        let buffers = withUnsafePointer(to: list.mBuffers) { base in
            UnsafeBufferPointer(
                start: UnsafeRawPointer(base).assumingMemoryBound(to: AudioBuffer.self),
                count: Int(list.mNumberBuffers))
        }
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
