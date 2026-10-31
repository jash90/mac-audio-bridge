import AVFoundation
import BridgeCore
import Foundation

/// Plays the jitter buffer through an `AVAudioSourceNode` (48 kHz stereo,
/// deinterleaved Float32 render format) via a `PCMFrameReader`, which turns
/// the jitter buffer's 10 ms playout slots into arbitrary-size render reads
/// with packet-loss concealment. The render block only touches preallocated
/// state — no allocation, no Swift concurrency; the jitter buffer's short
/// unfair lock is the only synchronization it meets.
final class AudioOutput: @unchecked Sendable {
    private let jitterBuffer: JitterBuffer
    private let renderContext: RenderContext
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?

    init(jitterBuffer: JitterBuffer) {
        self.jitterBuffer = jitterBuffer
        self.renderContext = RenderContext(
            frameReader: PCMFrameReader(source: { jitterBuffer.pop() }))
    }

    /// Fraction (in frames, 0..<1) of the playout frame currently being
    /// rendered — the "partially played frame" part of the latency readout.
    var partiallyPlayedFrames: Double {
        renderContext.frameReader.partiallyPlayedFrames
    }

    /// Activates the audio session and starts the engine. The session asks
    /// for 48 kHz and a 5 ms IO buffer to keep the output-side latency low.
    /// The render block outputs silence until the jitter buffer leaves
    /// prebuffering.
    func start() throws {
        guard sourceNode == nil else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setPreferredSampleRate(AudioFormat.sampleRate)
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)

        // Fresh run: drop anything buffered and the concealment history. The
        // render thread is not running yet, so this is race-free.
        jitterBuffer.reset()
        renderContext.restart()

        let renderFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioFormat.sampleRate,
            channels: AVAudioChannelCount(AudioFormat.channelCount),
            interleaved: false)!

        let node = AVAudioSourceNode(
            format: renderFormat,
            renderBlock: Self.makeRenderBlock(context: renderContext))
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

    // MARK: - Realtime callback

    /// Builds the render block in a nonisolated context so it carries no actor
    /// isolation; CoreAudio invokes it on the render thread, where hopping,
    /// allocating and locking are forbidden. It only touches the preallocated,
    /// Sendable `RenderContext`.
    nonisolated private static func makeRenderBlock(context: RenderContext) -> AVAudioSourceNodeRenderBlock {
        { _, _, frameCount, audioBufferList in
            context.render(into: audioBufferList, frameCount: Int(frameCount))
            return noErr
        }
    }
}

/// Realtime state captured by the render block: the playout reader and a
/// preallocated interleaved scratch frame.
private final class RenderContext: @unchecked Sendable {
    let frameReader: PCMFrameReader
    private let scratch: UnsafeMutablePointer<Float>
    private static let scratchSamples = 8_192

    init(frameReader: PCMFrameReader) {
        self.frameReader = frameReader
        self.scratch = UnsafeMutablePointer<Float>.allocate(capacity: Self.scratchSamples)
        self.scratch.initialize(repeating: 0, count: Self.scratchSamples)
    }

    deinit {
        scratch.deallocate()
    }

    /// Called from the render thread. Fills `list` with audio or silence; the
    /// reader's concealment and buffering rules produce the silence cases.
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

        // The reader serves any request size (render quanta are not
        // necessarily a multiple of one 10 ms frame) and never runs dry.
        let samplesNeeded = min(frameCount * AudioFormat.channelCount, Self.scratchSamples)
        frameReader.read(into: scratch, sampleCount: samplesNeeded)
        let frames = samplesNeeded / AudioFormat.channelCount

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
            for i in 0..<samplesNeeded {
                destination[i] = scratch[i]
            }
        }
    }

    /// Re-arms the reader for a fresh run (before the engine starts).
    func restart() {
        frameReader.reset()
    }
}
