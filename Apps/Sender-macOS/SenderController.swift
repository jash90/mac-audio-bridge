import BridgeCore
import Foundation
import Synchronization

// File-scope constant so @Sendable background closures can reference it without
// touching main-actor-isolated static state.
private let captureDeniedMessage =
    "No audio captured — allow Mac Audio Bridge in System Settings → Privacy & Security → Screen & System Audio Recording"

/// Mailbox for warnings raised on background queues. `refreshStats` drains it on
/// the main actor (~1 Hz), so background callbacks never touch UI state directly.
private final class WarningMailbox: @unchecked Sendable {
    private let message = Mutex<String?>(nil)

    func post(_ value: String) {
        message.withLock { current in
            current = value
        }
    }

    func take() -> String? {
        message.withLock { current in
            let value = current
            current = nil
            return value
        }
    }
}

/// Packet counter shared between the converter queue (writer) and the UI (reader).
final class FrameStats: @unchecked Sendable {
    private let packets = Atomic<Int>(0)
    private let lastSequence = Atomic<UInt32>(0)

    func record(sequence: UInt32) {
        packets.wrappingAdd(1, ordering: .relaxed)
        lastSequence.store(sequence, ordering: .relaxed)
    }

    func reset() {
        packets.store(0, ordering: .relaxed)
        lastSequence.store(0, ordering: .relaxed)
    }

    /// Returns the packet count since the last call and resets it to zero.
    func takePerSecondCount() -> Int {
        packets.exchange(0, ordering: .acquiringAndReleasing)
    }

    /// Sequence number of the most recently emitted packet.
    var sequence: UInt32 {
        lastSequence.load(ordering: .relaxed)
    }
}

/// One second of sender telemetry, appended as a JSON line to
/// `~/Library/Logs/MacAudioBridge/sender-stats.jsonl`.
private struct SenderStatsLine: Codable, Sendable {
    var timestamp: Double
    /// Ring write() calls (≈ tap IOProc callbacks) in the last second.
    var ioCallbacks: Int
    /// Samples the tap delivered into the ring (stored + dropped).
    var samplesCaptured: Int
    /// Samples the ring dropped to overflow in the last second.
    var ringDroppedSamples: Int
    /// Samples currently sitting in the ring.
    var ringFillSamples: Int
    var packetsSent: Int
    var bytesSent: Int
    /// Largest gap between drain ticks in the last second, ms — the App Nap
    /// / timer-throttling signature.
    var maxTickMs: Double
    var appNapActivityHeld: Bool
}

/// Glues tap → frame converter → UDP sender together and exposes UI state
/// on the main actor.
@MainActor
final class SenderController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running
        case failed(String)
    }

    private static let statsFileURL = FileManager.default.urls(
        for: .libraryDirectory, in: .userDomainMask
    )[0].appendingPathComponent("Logs/MacAudioBridge/sender-stats.jsonl")

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var tapSampleRate: Double?
    @Published private(set) var packetsPerSecond = 0
    @Published private(set) var currentSequence: UInt32 = 0
    @Published private(set) var captureWarning: String?

    private let tap = SystemAudioTap()
    private let converter = FrameConverter()
    private let udpSender = UDPSender()
    private let frameStats = FrameStats()
    private let captureWarningMailbox = WarningMailbox()
    private let statsWriter = RollingJSONLWriter(fileURL: SenderController.statsFileURL)
    private let statsEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// App Nap prevention held while streaming: without it (LSUIElement menu
    /// bar app, no windows), macOS throttles the 2.5 ms drain timer and the
    /// tap ring overflows.
    private var streamingActivity: NSObjectProtocol?
    /// Ring counter baselines for per-second deltas.
    private var lastRingWriteCalls = 0
    private var lastRingCapturedSamples = 0
    private var lastRingDroppedSamples = 0

    var isRunning: Bool { phase == .running }

    func toggle(host: String) {
        if isRunning {
            stop()
        } else {
            start(host: host)
        }
    }

    func start(host: String) {
        guard !isRunning else { return }
        guard !host.isEmpty else {
            phase = .failed("Enter the iPhone's IP address first.")
            return
        }

        // Hold the system awake for the whole run: this is an LSUIElement app
        // with no window, so without an activity assertion App Nap coalesces
        // the 2.5 ms drain timer into seconds-long silences and the tap ring
        // overflows (measured: 26 kB/s out of an expected 194 kB/s).
        streamingActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Streaming audio to iPhone")

        // Process taps are gated by the "System Audio Recording" TCC service: the
        // system prompt appears when the tap/IO starts. A denial shows up either as
        // an error from start, or as zero-filled buffers — detected by the converter
        // after 3 s and reported through `captureWarning`.
        do {
            try tap.start()
        } catch {
            phase = .failed("Could not start the audio tap: \(error.localizedDescription)")
            return
        }

        tapSampleRate = tap.sampleRate
        captureWarning = nil
        frameStats.reset()
        // Both callbacks run on the converter queue: they are @Sendable, capture
        // only Sendable state (no self), and never touch UI state directly.
        converter.onFrame = { [udpSender, frameStats] packet in
            udpSender.send(packet.encoded())
            frameStats.record(sequence: packet.sequence)
        }
        converter.onCaptureStalled = { [captureWarningMailbox] in
            captureWarningMailbox.post(captureDeniedMessage)
        }
        udpSender.setHost(host)
        converter.start(ring: tap.ring, tapSampleRate: tap.sampleRate)
        phase = .running
    }

    func stop() {
        // The converter is the ring's consumer side: stop (and drain) it on its
        // queue BEFORE the tap goes away. The ring reset for the next run happens
        // on that same queue in FrameConverter.start.
        converter.stop()
        udpSender.cancel()
        tap.stop()
        if let activity = streamingActivity {
            ProcessInfo.processInfo.endActivity(activity)
            streamingActivity = nil
        }
        tapSampleRate = nil
        packetsPerSecond = 0
        currentSequence = 0
        captureWarning = nil
        phase = .idle
    }

    /// Pulls counter snapshots and background warnings for the UI — call ~1 Hz.
    func refreshStats() {
        packetsPerSecond = frameStats.takePerSecondCount()
        currentSequence = frameStats.sequence
        if let warning = captureWarningMailbox.take() {
            captureWarning = warning
        }
        logStats()
    }

    /// Appends one JSON line of sender telemetry to
    /// `~/Library/Logs/MacAudioBridge/sender-stats.jsonl` — call ~1 Hz while
    /// streaming. Only atomic ring/sender counters come off the hot paths;
    /// encoding happens here, the file write on the writer's utility queue.
    private func logStats() {
        guard phase == .running else { return }
        let ring = tap.ring
        let writeCalls = ring.writeCallCount
        let capturedSamples = ring.storedSampleCount + ring.droppedSampleCount
        let droppedSamples = ring.droppedSampleCount
        let sent = udpSender.takeSentCounts()
        let line = SenderStatsLine(
            timestamp: Date().timeIntervalSince1970,
            ioCallbacks: writeCalls - lastRingWriteCalls,
            samplesCaptured: capturedSamples - lastRingCapturedSamples,
            ringDroppedSamples: droppedSamples - lastRingDroppedSamples,
            ringFillSamples: ring.availableToRead,
            packetsSent: sent.datagrams,
            bytesSent: sent.bytes,
            maxTickMs: converter.takeMaxTickIntervalMilliseconds(),
            appNapActivityHeld: streamingActivity != nil
        )
        lastRingWriteCalls = writeCalls
        lastRingCapturedSamples = capturedSamples
        lastRingDroppedSamples = droppedSamples
        if let data = try? statsEncoder.encode(line) {
            statsWriter.append(data)
        }
    }
}
