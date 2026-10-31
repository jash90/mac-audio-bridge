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

/// Frame counter shared between the converter queue (writer) and the UI (reader).
final class FrameStats: @unchecked Sendable {
    private let frames = Atomic<Int>(0)

    func increment() {
        frames.wrappingAdd(1, ordering: .relaxed)
    }

    func reset() {
        frames.store(0, ordering: .relaxed)
    }

    /// Returns the count since the last call and resets it to zero.
    func takePerSecondCount() -> Int {
        frames.exchange(0, ordering: .acquiringAndReleasing)
    }
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

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var tapSampleRate: Double?
    @Published private(set) var framesPerSecond = 0
    @Published private(set) var captureWarning: String?

    private let tap = SystemAudioTap()
    private let converter = FrameConverter()
    private let udpSender = UDPSender()
    private let frameStats = FrameStats()
    private let captureWarningMailbox = WarningMailbox()

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
        converter.onFrame = { [udpSender, frameStats] frame in
            udpSender.send(frame)
            frameStats.increment()
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
        tapSampleRate = nil
        framesPerSecond = 0
        captureWarning = nil
        phase = .idle
    }

    /// Pulls counter snapshots and background warnings for the UI — call ~1 Hz.
    func refreshStats() {
        framesPerSecond = frameStats.takePerSecondCount()
        if let warning = captureWarningMailbox.take() {
            captureWarning = warning
        }
    }
}
