import AVFoundation
import BridgeCore
import Foundation
import os
import Synchronization

/// Output gain applied to every sample before packetization: the virtual
/// device's volume scalar, zeroed when muted. Written from the main actor
/// (device listeners), read on the converter queue — a plain atomic, no locks
/// on the drain path. This is how the Mac's volume keys control the iPhone's
/// loudness: the null driver discards audio, so the tap delivers full-scale
/// samples and the attenuation happens here.
final class VolumeGate: @unchecked Sendable {
    private let gain = Atomic<Float>(1)

    var value: Float {
        get { gain.load(ordering: .relaxed) }
        set { gain.store(newValue, ordering: .relaxed) }
    }
}

/// When the stream last carried audible (non-silent) samples — the phone's
/// "audio playing" indicator. Written once per frame on the converter queue
/// (one relaxed atomic store), read ~1 Hz on the main actor.
final class AudibilityTracker: @unchecked Sendable {
    /// Peak below this (about -80 dBFS) counts as silence.
    static let threshold: Float = 1e-4
    private let lastAudibleNanos = Atomic<UInt64>(0)

    func recordAudible() {
        lastAudibleNanos.store(DispatchTime.now().uptimeNanoseconds, ordering: .relaxed)
    }

    func reset() {
        lastAudibleNanos.store(0, ordering: .relaxed)
    }

    /// Whether audible samples were seen within `window` seconds.
    func audible(within window: TimeInterval) -> Bool {
        let last = lastAudibleNanos.load(ordering: .relaxed)
        guard last > 0 else { return false }
        let now = DispatchTime.now().uptimeNanoseconds
        return now <= last || Double(now - last) / 1e9 <= window
    }
}

/// The stream quality picked in the menu, read once per drain tick on the
/// converter queue — a plain atomic, like `VolumeGate`. A change applies from
/// the next frame (within one 2.5 ms tick).
final class QualityGate: @unchecked Sendable {
    private let index = Atomic<Int>(StreamQuality.allCases.firstIndex(of: .default) ?? 0)

    var value: StreamQuality {
        get { StreamQuality.allCases[index.load(ordering: .relaxed)] }
        set { index.store(StreamQuality.allCases.firstIndex(of: newValue) ?? 0, ordering: .relaxed) }
    }
}

/// Per-second encoder telemetry: recorded per frame on the converter queue,
/// drained ~1 Hz by the stats loop. The duration buffer is preallocated and
/// capped, so recording never allocates on the drain path.
final class EncoderStats: @unchecked Sendable {
    struct Snapshot: Sendable {
        /// Codec of the last frame encoded (nil = no frame this second).
        var codec: BridgeCore.AudioCodec?
        var frames: Int
        var payloadBytes: Int
        /// p99 of the per-frame encode time (ms) over the second.
        var encodeMsP99: Double

        var averagePayloadBytes: Double {
            frames > 0 ? Double(payloadBytes) / Double(frames) : 0
        }
    }

    private static let capacity = 1_024

    private struct State {
        var codec: BridgeCore.AudioCodec?
        var frames = 0
        var payloadBytes = 0
        var encodeNanos: [UInt64]
    }

    private let state: Mutex<State>

    init() {
        var durations: [UInt64] = []
        durations.reserveCapacity(Self.capacity)
        state = Mutex(State(encodeNanos: durations))
    }

    func record(codec: BridgeCore.AudioCodec, payloadBytes: Int, encodeNanos: UInt64) {
        state.withLock { state in
            state.codec = codec
            state.frames += 1
            state.payloadBytes += payloadBytes
            if state.encodeNanos.count < Self.capacity {
                state.encodeNanos.append(encodeNanos)
            }
        }
    }

    /// The second's counters, then resets them.
    func take() -> Snapshot {
        var durations: [UInt64] = []
        let snapshot = state.withLock { state -> Snapshot in
            durations = state.encodeNanos
            let snapshot = Snapshot(
                codec: state.frames > 0 ? state.codec : nil, frames: state.frames,
                payloadBytes: state.payloadBytes, encodeMsP99: 0)
            state.frames = 0
            state.payloadBytes = 0
            state.encodeNanos.removeAll(keepingCapacity: true)
            return snapshot
        }
        guard !durations.isEmpty else { return snapshot }
        durations.sort()
        let index = min(durations.count - 1, Int((Double(durations.count - 1) * 0.99).rounded()))
        var result = snapshot
        result.encodeMsP99 = Double(durations[index]) / 1_000_000
        return result
    }
}

/// Drains the tap's ring buffer on a dedicated serial `.userInteractive` queue
/// (strict timer every 2.5 ms), resamples to 48 kHz with `AVAudioConverter` when
/// the tap rate differs, applies the virtual device's volume (see `VolumeGate`),
/// and emits fixed 5 ms frames as `AudioPacket`s in the quality picked in the menu
/// (`QualityGate`: Opus 192/128 kbit/s CBR or PCM16, encoded by `StreamFrameEncoder`
/// right here on the drain path, switching live from one frame to the next). A frame is emitted in the same
/// tick it completes — no extra queueing — and sequence and sample time advance
/// continuously for the app's lifetime; the first packet of every run carries
/// `.discontinuity` so the receiver resets its jitter buffer.
///
/// Each tick drains EVERYTHING the ring holds (loop until empty), so a late
/// timer — App Nap or timer coalescing — costs latency, not audio: the next
/// tick emits every complete frame that piled up. The worst observed gap
/// between ticks is exposed for the stats log.
///
/// All mutable state is confined to `queue`. Must be started/stopped from the main
/// actor (like all owners in this app).
final class FrameConverter: @unchecked Sendable {
    /// Called on the converter queue with one complete packetized frame.
    /// `@Sendable` so the closure carries no actor isolation when invoked off
    /// the main actor. Set before `start`, never swapped while running.
    var onFrame: (@Sendable (AudioPacket) -> Void)?

    /// Called once on the converter queue when the tap delivered only exact-zero
    /// samples for `captureGraceInterval` after start while the virtual device
    /// was running somewhere — the signature of a denied "System Audio Recording"
    /// grant. Set before `start`, never swapped while running.
    var onCaptureStalled: (@Sendable () -> Void)?

    /// Gain applied to emitted samples (volume scalar of the virtual device,
    /// 0 when muted). Safe to update any time, including while running.
    let volumeGate = VolumeGate()

    /// Stream quality (codec / bitrate) of emitted frames. Safe to update any
    /// time, including while running.
    let qualityGate = QualityGate()

    /// Encoder telemetry for the stats line.
    let encoderStats = EncoderStats()

    /// Last time a frame carried audible samples (before the volume gain).
    let audibility = AudibilityTracker()

    private static let queueLabel = "dev.jash90.MacAudioBridge.frame-converter"
    private static let inputCapacityFrames = 8_192
    /// 2.5 ms drain tick: a 5 ms frame waits at most one extra tick once complete.
    /// Expressed in seconds so the interval can be checked against the frame
    /// duration at timer creation — a tick longer than one audio frame can
    /// never ship again.
    private static let timerIntervalSeconds: Double = 0.0025
    private static let timerInterval = DispatchTimeInterval.nanoseconds(
        Int(timerIntervalSeconds * 1e9))
    /// Tight leeway plus a `.strict` timer on a `.userInteractive` queue:
    /// the measured 121 ms tick gaps came from timer coalescing of a
    /// default-QoS, non-strict source; a strict source is never deferred past
    /// its leeway, and user-interactive QoS keeps the queue off the
    /// efficiency cores' throttled lanes.
    private static let timerLeeway = DispatchTimeInterval.microseconds(100)
    private static let captureGraceInterval: TimeInterval = 3

    private let queue = DispatchQueue(label: FrameConverter.queueLabel, qos: .userInteractive)
    private let logger = Logger(subsystem: "dev.jash90.MacAudioBridge", category: "frame-converter")

    // State confined to `queue`:
    private var timer: DispatchSourceTimer?
    private var isRunning = false
    private var sawNonZeroSamples = false
    private var runGeneration = 0
    private var ring: SPSCRingBuffer?
    private var converter: AVAudioConverter?
    private var inputBuffer: AVAudioPCMBuffer?
    private var inputSamples: UnsafeMutablePointer<Float>?
    private var inputCapacitySamples = 0
    private var outputBuffer: AVAudioPCMBuffer?
    private var staging = [Float]()
    /// Opus / PCM16 frame encoder (queue-confined, preallocated).
    private let frameEncoder = StreamFrameEncoder()
    /// Sequence/sample time of the next emitted packet. Never reset between
    /// runs, so the stream is continuous across restarts; restarts are marked
    /// with `.discontinuity` instead.
    private var nextSequence: UInt32 = 0
    private var nextSampleTime: UInt64 = 0
    private var pendingDiscontinuity = false
    /// Drain-timing diagnostics: the last tick's timestamp and the largest
    /// tick-to-tick gap since the last `takeMaxTickIntervalMilliseconds`.
    private var lastTickTime: DispatchTime?
    private var maxTickInterval: TimeInterval = 0

    /// Samples (interleaved) per emitted frame: 240 frames × 2 channels.
    private static let samplesPerFrame = AudioFormat.samplesPerFrame * AudioFormat.channelCount

    init() {
        staging.reserveCapacity(Self.samplesPerFrame * 4)
    }

    /// Begins draining `ring` (tap format: interleaved Float32 stereo at
    /// `tapSampleRate`) and emitting 48 kHz Int16 frames.
    func start(ring: SPSCRingBuffer, tapSampleRate: Double) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopTimer()
            self.ring = ring
            // Consumer-side reset, deliberately on this queue: reset() must never
            // race the consumer, and this queue is the ring's only consumer.
            ring.reset()
            self.sawNonZeroSamples = false
            self.runGeneration += 1
            self.staging.removeAll(keepingCapacity: true)
            self.lastTickTime = nil
            self.maxTickInterval = 0
            // The first packet of every run tells the receiver to reset; the
            // run's first Opus frame starts a fresh Opus stream.
            self.pendingDiscontinuity = true
            self.frameEncoder.reset()

            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: AudioFormat.sampleRate,
                channels: AVAudioChannelCount(AudioFormat.channelCount),
                interleaved: true)!
            let inputFormat: AVAudioFormat
            if abs(tapSampleRate - AudioFormat.sampleRate) > 0.5 {
                inputFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: tapSampleRate,
                    channels: AVAudioChannelCount(AudioFormat.channelCount),
                    interleaved: true)!
                // Not reset between chunks: the resampler keeps internal state for
                // continuity across calls.
                self.converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            } else {
                self.converter = nil
                inputFormat = targetFormat
            }

            if let buffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: AVAudioFrameCount(Self.inputCapacityFrames))
            {
                self.inputBuffer = buffer
                self.inputSamples = buffer.audioBufferList.pointee.mBuffers.mData?
                    .assumingMemoryBound(to: Float.self)
                self.inputCapacitySamples = Self.inputCapacityFrames * AudioFormat.channelCount
            } else {
                self.inputBuffer = nil
                self.inputSamples = nil
                self.inputCapacitySamples = 0
            }

            if self.converter != nil {
                let ratio = AudioFormat.sampleRate / tapSampleRate
                let outputFrames = AVAudioFrameCount(
                    (Double(Self.inputCapacityFrames) * ratio).rounded(.up)) + 256
                self.outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: targetFormat,
                    frameCapacity: outputFrames)
            } else {
                self.outputBuffer = nil
            }

            guard self.inputSamples != nil else {
                self.logger.error("Failed to allocate converter buffers")
                return
            }

            self.isRunning = true
            precondition(
                Self.timerIntervalSeconds < Double(AudioFormat.frameDurationMs) / 1000,
                "drain tick \(Self.timerIntervalSeconds) s must be shorter than one audio frame")
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: self.queue)
            timer.schedule(
                deadline: .now() + Self.timerInterval,
                repeating: Self.timerInterval,
                leeway: Self.timerLeeway)
            timer.setEventHandler { [weak self] in
                self?.drainOnce()
            }
            timer.activate()
            self.timer = timer

            // Denial detection: if nothing but zeros arrives within the grace
            // period while the virtual device is running somewhere (some app is
            // playing to it), the "System Audio Recording" grant was denied.
            // Runs on this queue, not in the IOProc. The generation check
            // no-ops checks from prior runs.
            let generation = self.runGeneration
            self.queue.asyncAfter(deadline: .now() + Self.captureGraceInterval) { [weak self] in
                guard let self,
                    self.isRunning,
                    self.runGeneration == generation,
                    !self.sawNonZeroSamples,
                    BridgeDevice.isRunningSomewhere()
                else { return }
                self.logger.error(
                    "Tap delivered only silence for \(Self.captureGraceInterval, privacy: .public) s — capture denied?")
                self.onCaptureStalled?()
            }

            self.logger.info(
                "Converter started (tap rate \(tapSampleRate, format: .fixed(precision: 0), privacy: .public) Hz)")
        }
    }

    /// Stops the timer and releases the buffers. Blocks until the queue is drained.
    func stop() {
        queue.sync {
            stopTimer()
            isRunning = false
            runGeneration += 1
            sawNonZeroSamples = false
            ring = nil
            converter = nil
            inputBuffer = nil
            inputSamples = nil
            inputCapacitySamples = 0
            outputBuffer = nil
            staging.removeAll(keepingCapacity: true)
            lastTickTime = nil
            maxTickInterval = 0
        }
    }

    /// Largest gap between drain ticks (in milliseconds) since the last call,
    /// then resets the tracker. Includes the gap from the last tick to now,
    /// so a fully stalled timer shows up even without a subsequent tick.
    /// Zero while not running.
    func takeMaxTickIntervalMilliseconds() -> Double {
        queue.sync {
            var worst = maxTickInterval
            if let last = lastTickTime {
                let idleGap = Double(DispatchTime.now().uptimeNanoseconds - last.uptimeNanoseconds) * 1e-9
                worst = max(worst, idleGap)
            }
            maxTickInterval = 0
            return worst * 1000
        }
    }

    // MARK: - Queue-confined implementation

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func drainOnce() {
        guard isRunning, let ring else { return }
        recordTick()

        if let converter, let outputBuffer, let inputBuffer, let inputSamples,
            inputCapacitySamples > 0
        {
            // Resampling path: keep converting until a call produces nothing —
            // the ring is then fully drained into the staging buffer.
            while true {
                var conversionError: NSError?
                let capacitySamples = inputCapacitySamples
                // The converter fills up to the output buffer's capacity; frameLength
                // on return holds the produced frame count. `.inputRanDry` is normal —
                // the loop ends when a call yields no output. The input block runs
                // synchronously on this queue, so capturing the locals is safe.
                let status = converter.convert(to: outputBuffer, error: &conversionError) {
                    requestedPackets, outStatus in
                    let wanted = min(
                        Int(requestedPackets) * AudioFormat.channelCount,
                        capacitySamples)
                    let got = ring.read(into: inputSamples, count: wanted)
                    self.trackNonZeroSamples(inputSamples, count: got)
                    guard got > 0 else {
                        // Momentarily empty. `.noDataNow` keeps the converter's state
                        // intact — `.endOfStream` would terminate its input permanently.
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    inputBuffer.frameLength = AVAudioFrameCount(got / AudioFormat.channelCount)
                    return inputBuffer
                }
                if status == .error {
                    logger.error(
                        "Conversion failed: \(conversionError?.localizedDescription ?? "unknown error", privacy: .public)")
                }
                let producedSamples = Int(outputBuffer.frameLength) * AudioFormat.channelCount
                if producedSamples > 0,
                    let outputSamples = outputBuffer.audioBufferList.pointee.mBuffers.mData?
                        .assumingMemoryBound(to: Float.self)
                {
                    staging.append(
                        contentsOf: UnsafeBufferPointer(
                            start: outputSamples,
                            count: producedSamples))
                }
                if producedSamples == 0 { break }
            }
        } else if let inputSamples, inputCapacitySamples > 0 {
            // Tap already runs at 48 kHz — no resampling needed. Read until the
            // ring is empty so a late tick drains everything that piled up.
            while true {
                let got = ring.read(into: inputSamples, count: inputCapacitySamples)
                guard got > 0 else { break }
                trackNonZeroSamples(inputSamples, count: got)
                staging.append(
                    contentsOf: UnsafeBufferPointer(start: inputSamples, count: got))
            }
        }

        emitCompleteFrames()
    }

    /// Records the tick timestamp and the largest tick-to-tick gap.
    private func recordTick() {
        let now = DispatchTime.now()
        if let last = lastTickTime {
            let interval = Double(now.uptimeNanoseconds - last.uptimeNanoseconds) * 1e-9
            maxTickInterval = max(maxTickInterval, interval)
        }
        lastTickTime = now
    }

    /// Records whether any nonzero sample has been read since the run started —
    /// zero-filled buffers are how a denied capture grant manifests. Queue-confined.
    private func trackNonZeroSamples(_ samples: UnsafePointer<Float>, count: Int) {
        guard !sawNonZeroSamples, count > 0 else { return }
        for i in 0..<count where samples[i] != 0 {
            sawNonZeroSamples = true
            return
        }
    }

    /// Chops the staging buffer into whole 5 ms frames, applies the volume
    /// gate's gain, encodes each in the selected quality, and hands one
    /// `AudioPacket` per frame to `onFrame`.
    private func emitCompleteFrames() {
        // One relaxed atomic load each per drain; mute yields gain 0 (zeros out).
        let gain = volumeGate.value
        let quality = qualityGate.value
        var frameStart = 0
        while staging.count - frameStart >= Self.samplesPerFrame {
            let flags: AudioPacketFlags = pendingDiscontinuity ? [.discontinuity] : []
            let sequence = nextSequence
            let sampleTime = nextSampleTime
            let started = DispatchTime.now().uptimeNanoseconds
            let audible = staging.withUnsafeBufferPointer { buffer in
                Self.isAudible(buffer.baseAddress! + frameStart, count: Self.samplesPerFrame)
            }
            if audible {
                audibility.recordAudible()
            }
            let packet = staging.withUnsafeBufferPointer { buffer in
                frameEncoder.encode(
                    buffer.baseAddress! + frameStart, gain: gain, quality: quality, flags: flags,
                    sequence: sequence, sampleTime: sampleTime)
            }
            encoderStats.record(
                codec: packet.codec, payloadBytes: packet.payload.count,
                encodeNanos: DispatchTime.now().uptimeNanoseconds - started)
            onFrame?(packet)
            nextSequence = nextSequence &+ 1
            nextSampleTime &+= UInt64(AudioFormat.samplesPerFrame)
            pendingDiscontinuity = false
            frameStart += Self.samplesPerFrame
        }
        if frameStart > 0 {
            staging.removeFirst(frameStart)
        }
    }

    /// Whether any sample of the frame is above the silence threshold.
    private static func isAudible(_ samples: UnsafePointer<Float>, count: Int) -> Bool {
        for i in 0..<count where abs(samples[i]) > AudibilityTracker.threshold {
            return true
        }
        return false
    }
}
