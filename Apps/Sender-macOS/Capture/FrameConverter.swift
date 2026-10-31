import AVFoundation
import BridgeCore
import Foundation
import os

/// Drains the tap's ring buffer on a dedicated serial queue (timer every 5 ms),
/// resamples to 48 kHz with `AVAudioConverter` when the tap rate differs, and emits
/// fixed 10 ms frames as interleaved little-endian Int16 `Data` (1920 bytes).
///
/// All mutable state is confined to `queue`. Must be started/stopped from the main
/// actor (like all owners in this app).
final class FrameConverter: @unchecked Sendable {
    /// Called on the converter queue with one complete frame. `@Sendable` so the
    /// closure carries no actor isolation when invoked off the main actor.
    /// Set before `start`, never swapped while running.
    var onFrame: (@Sendable (Data) -> Void)?

    /// Called once on the converter queue when the tap delivered only exact-zero
    /// samples for `captureGraceInterval` after start while the default output
    /// device was running — the signature of a denied "System Audio Recording"
    /// grant. Set before `start`, never swapped while running.
    var onCaptureStalled: (@Sendable () -> Void)?

    private static let queueLabel = "dev.jash90.MacAudioBridge.frame-converter"
    private static let inputCapacityFrames = 8_192
    private static let timerIntervalMs = 5
    private static let captureGraceInterval: TimeInterval = 3

    private let queue = DispatchQueue(label: FrameConverter.queueLabel)
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

    /// Samples (interleaved) per emitted frame: 480 frames × 2 channels.
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
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(
                deadline: .now() + .milliseconds(Self.timerIntervalMs),
                repeating: .milliseconds(Self.timerIntervalMs),
                leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in
                self?.drainOnce()
            }
            timer.activate()
            self.timer = timer

            // Denial detection: if nothing but zeros arrives within the grace
            // period while the default output device is playing somewhere, the
            // "System Audio Recording" grant was denied. Runs on this queue, not
            // in the IOProc. The generation check no-ops checks from prior runs.
            let generation = self.runGeneration
            self.queue.asyncAfter(deadline: .now() + Self.captureGraceInterval) { [weak self] in
                guard let self,
                    self.isRunning,
                    self.runGeneration == generation,
                    !self.sawNonZeroSamples,
                    isDefaultOutputDeviceRunningSomewhere()
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
        }
    }

    // MARK: - Queue-confined implementation

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func drainOnce() {
        guard isRunning, let ring else { return }

        if let converter, let outputBuffer, let inputBuffer, let inputSamples,
            inputCapacitySamples > 0
        {
            var conversionError: NSError?
            let capacitySamples = inputCapacitySamples
            // The converter fills up to the output buffer's capacity; frameLength on
            // return holds the produced frame count. `.inputRanDry` is normal — the
            // next timer tick pulls whatever arrived in the meantime. The input block
            // runs synchronously on this queue, so capturing the locals is safe.
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
            if outputBuffer.frameLength > 0,
                let outputSamples = outputBuffer.audioBufferList.pointee.mBuffers.mData?
                    .assumingMemoryBound(to: Float.self)
            {
                staging.append(
                    contentsOf: UnsafeBufferPointer(
                        start: outputSamples,
                        count: Int(outputBuffer.frameLength) * AudioFormat.channelCount))
            }
        } else if let inputSamples, inputCapacitySamples > 0 {
            // Tap already runs at 48 kHz — no resampling needed.
            let got = ring.read(into: inputSamples, count: inputCapacitySamples)
            trackNonZeroSamples(inputSamples, count: got)
            if got > 0 {
                staging.append(
                    contentsOf: UnsafeBufferPointer(start: inputSamples, count: got))
            }
        }

        emitCompleteFrames()
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

    /// Chops the staging buffer into whole 10 ms frames and hands them to `onFrame`.
    private func emitCompleteFrames() {
        var frameStart = 0
        while staging.count - frameStart >= Self.samplesPerFrame {
            let frameData = staging.withUnsafeBufferPointer { buffer in
                Self.encodeFrame(samples: buffer, offset: frameStart)
            }
            onFrame?(frameData)
            frameStart += Self.samplesPerFrame
        }
        if frameStart > 0 {
            staging.removeFirst(frameStart)
        }
    }

    /// Converts one frame of interleaved Float32 into little-endian Int16 `Data`.
    private static func encodeFrame(samples: UnsafeBufferPointer<Float>, offset: Int) -> Data {
        var data = Data(capacity: samplesPerFrame * MemoryLayout<Int16>.size)
        for i in offset..<(offset + samplesPerFrame) {
            let clamped = min(1, max(-1, samples[i]))
            let value = UInt16(bitPattern: Int16(clamped * 32767)).littleEndian
            withUnsafeBytes(of: value) { bytes in
                data.append(contentsOf: bytes)
            }
        }
        return data
    }
}
