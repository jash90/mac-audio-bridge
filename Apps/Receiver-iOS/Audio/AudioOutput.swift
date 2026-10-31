import AVFoundation
import BridgeCore
import Foundation
import Synchronization

/// Plays the shared ring buffer through an `AVAudioSourceNode` (48 kHz stereo,
/// deinterleaved Float32 render format). The render block only reads from the
/// lock-free ring buffer — no allocation, no locking on the render thread.
final class AudioOutput: @unchecked Sendable {
    /// 60 ms of interleaved stereo before the render block starts reading.
    private static let prebufferSamples =
        Int(AudioFormat.sampleRate) * 60 / 1000 * AudioFormat.channelCount

    private let ring: SPSCRingBuffer
    private let renderContext: RenderContext
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?

    init(ring: SPSCRingBuffer) {
        self.ring = ring
        self.renderContext = RenderContext(ring: ring, prebufferSamples: Self.prebufferSamples)
    }

    var underrunCount: Int {
        renderContext.underrunCount.load(ordering: .relaxed)
    }

    /// Activates the audio session and starts the engine. The render block outputs
    /// silence until the ring buffer holds the prebuffer amount.
    func start() throws {
        guard sourceNode == nil else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)

        // The consumer (render thread) is not running yet, so resetting here is safe.
        ring.reset()
        renderContext.restart()

        let renderFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioFormat.sampleRate,
            channels: AVAudioChannelCount(AudioFormat.channelCount),
            interleaved: false)!

        let node = AVAudioSourceNode(format: renderFormat) { [renderContext] _, _, frameCount, audioBufferList in
            renderContext.render(into: audioBufferList, frameCount: Int(frameCount))
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: renderFormat)
        engine.prepare()
        try engine.start()
        sourceNode = node
    }

    func stop() {
        engine.stop()
        if let sourceNode {
            engine.detach(sourceNode)
        }
        sourceNode = nil
    }
}

/// Realtime state captured by the render block: the ring, a preallocated scratch
/// buffer, the prebuffer gate and the underrun counter.
private final class RenderContext: @unchecked Sendable {
    private let ring: SPSCRingBuffer
    private let prebufferSamples: Int
    private let scratch: UnsafeMutablePointer<Float>
    private static let scratchSamples = 8_192

    let primed = Atomic<Bool>(false)
    let underrunCount = Atomic<Int>(0)

    init(ring: SPSCRingBuffer, prebufferSamples: Int) {
        self.ring = ring
        self.prebufferSamples = prebufferSamples
        self.scratch = UnsafeMutablePointer<Float>.allocate(capacity: Self.scratchSamples)
        self.scratch.initialize(repeating: 0, count: Self.scratchSamples)
    }

    deinit {
        scratch.deallocate()
    }

    /// Called from the render thread. Fills `list` with audio or silence.
    func render(into list: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        // Index the variable-length list in place via its dedicated pointer view —
        // copying the struct out would leave only one AudioBuffer of storage.
        let buffers = UnsafeMutableAudioBufferListPointer(list)

        // Default to silence; decoded samples overwrite the prefix below.
        for buffer in buffers {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }

        // Hold off until the network has buffered enough audio (60 ms).
        if !primed.load(ordering: .relaxed) {
            guard ring.availableToRead >= prebufferSamples else { return }
            primed.store(true, ordering: .relaxed)
        }

        let samplesNeeded = min(frameCount * AudioFormat.channelCount, Self.scratchSamples)
        let got = ring.read(into: scratch, count: samplesNeeded)
        if got < samplesNeeded {
            underrunCount.wrappingAdd(1, ordering: .relaxed)
        }
        guard got > 0 else { return }
        let frames = got / AudioFormat.channelCount

        if buffers.count == 2 {
            // Deinterleaved: one mono buffer per channel.
            for channel in 0..<2 {
                guard let data = buffers[channel].mData else { continue }
                let destination = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<frames {
                    destination[frame] = scratch[frame * 2 + channel]
                }
            }
        } else if buffers.count == 1, let data = buffers[0].mData {
            // Interleaved fallback.
            let destination = data.assumingMemoryBound(to: Float.self)
            for i in 0..<got {
                destination[i] = scratch[i]
            }
        }
    }

    /// Re-arms the prebuffer gate for a fresh run (before the engine starts).
    func restart() {
        primed.store(false, ordering: .relaxed)
    }
}
