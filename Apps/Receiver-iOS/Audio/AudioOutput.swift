import AVFoundation
import BridgeCore
import Foundation
import Synchronization

/// Plays the jitter buffer through an `AVAudioSourceNode` (48 kHz stereo,
/// deinterleaved Float32 render format) via a `PCMFrameReader`, which turns
/// the jitter buffer's 10 ms playout slots into arbitrary-size render reads
/// with packet-loss concealment. The render block only touches preallocated
/// state — no allocation, no Swift concurrency; the jitter buffer's short
/// unfair lock is the only synchronization it meets, plus one relaxed atomic
/// counter.
///
/// Lifecycle is driven by `PlaybackController`: `start()` is idempotent in
/// effect and safe to call again whenever the engine may have stopped (it
/// always stops, re-wires against the current hardware format and starts),
/// and `rebuildEngine()` replaces every AV object after a media-services
/// reset. Main-actor confined; only the render block runs elsewhere.
@MainActor
final class AudioOutput {
    enum StartError: Error, LocalizedError {
        case noOutputHardware

        var errorDescription: String? {
            "The audio session reports no output hardware format"
        }
    }

    /// What a successful `start()` ended up with, for logging and stats.
    struct StartReport: Sendable {
        var sessionSampleRate: Double
        var ioBufferDuration: TimeInterval
        var outputLatency: TimeInterval
        var hardwareSampleRate: Double
        var hardwareChannels: UInt32
        /// True when the source node feeds the output node directly (hardware
        /// at 48 kHz stereo: no mixer, no sample-rate converter).
        var direct: Bool
    }

    private let jitterBuffer: JitterBuffer
    private let renderContext: RenderContext
    private var engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?

    /// The render format: the stream's native 48 kHz stereo, deinterleaved.
    private let renderFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioFormat.sampleRate,
        channels: AVAudioChannelCount(AudioFormat.channelCount),
        interleaved: false)!

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

    /// Whether the engine's IO is running (false after an interruption, a
    /// configuration change or a failed start).
    var isRunning: Bool { engine.isRunning }

    /// Render callbacks since launch (relaxed atomic written by the render
    /// thread).
    var renderCallCount: Int {
        renderContext.renderCalls.load(ordering: .relaxed)
    }

    /// The engine whose configuration-change notifications matter; compared
    /// by identity to ignore stale notifications after a rebuild.
    var engineIdentifier: ObjectIdentifier { ObjectIdentifier(engine) }

    /// Sets the playback category and the low-latency preferences, then
    /// activates the session. Safe to call repeatedly: the category is only
    /// set when it differs (setting it triggers a route change).
    func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playback || session.mode != .default
            || !session.categoryOptions.isEmpty
        {
            try session.setCategory(.playback, mode: .default, options: [])
        }
        // 48 kHz is the stream's rate: when the hardware honours it the whole
        // path runs without a sample-rate converter.
        try session.setPreferredSampleRate(AudioFormat.sampleRate)
        // 5 ms IO buffer (0.005 s). Bluetooth routes may grant more.
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
    }

    /// (Re)starts playback: activates the session, stops the engine, wires
    /// the source node against the current hardware format, drops stale
    /// buffered audio and starts the engine. The render thread is stopped
    /// while the jitter buffer and the reader are reset, so that is
    /// race-free.
    @discardableResult
    func start() throws -> StartReport {
        try activateSession()
        engine.stop()

        let node: AVAudioSourceNode
        if let sourceNode {
            node = sourceNode
            engine.disconnectNodeOutput(node)
        } else {
            node = AVAudioSourceNode(
                format: renderFormat,
                renderBlock: Self.makeRenderBlock(context: renderContext))
            engine.attach(node)
            sourceNode = node
        }

        // The output node's output side is the hardware format. At 48 kHz
        // stereo, feed it directly: no mixer stage and no converter. Any other
        // hardware format goes through the main mixer, which converts.
        let hardware = engine.outputNode.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0,
            let hardwareFormat = AVAudioFormat(
                standardFormatWithSampleRate: hardware.sampleRate,
                channels: hardware.channelCount)
        else { throw StartError.noOutputHardware }
        let direct = hardware.sampleRate == AudioFormat.sampleRate
            && hardware.channelCount == AVAudioChannelCount(AudioFormat.channelCount)
        if direct {
            engine.connect(node, to: engine.outputNode, format: renderFormat)
        } else {
            engine.connect(node, to: engine.mainMixerNode, format: renderFormat)
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: hardwareFormat)
        }

        // Fresh run: anything buffered while the engine was down is stale.
        jitterBuffer.reset()
        renderContext.restart()

        engine.prepare()
        try engine.start()

        let session = AVAudioSession.sharedInstance()
        return StartReport(
            sessionSampleRate: session.sampleRate,
            ioBufferDuration: session.ioBufferDuration,
            outputLatency: session.outputLatency,
            hardwareSampleRate: hardware.sampleRate,
            hardwareChannels: hardware.channelCount,
            direct: direct)
    }

    /// Discards the engine and its node and creates fresh ones — required
    /// after a media-services reset, which invalidates every AV object. The
    /// render context (our own state) survives.
    func rebuildEngine() {
        engine.stop()
        if let sourceNode {
            engine.detach(sourceNode)
        }
        sourceNode = nil
        engine = AVAudioEngine()
    }

    func stop() {
        engine.stop()
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

/// Realtime state captured by the render block: the playout reader, a
/// preallocated interleaved scratch frame and the render-call counter.
private final class RenderContext: @unchecked Sendable {
    let frameReader: PCMFrameReader
    /// Render callbacks served; read by the watchdog and the stats.
    let renderCalls = Atomic<Int>(0)
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
        renderCalls.add(1, ordering: .relaxed)

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
