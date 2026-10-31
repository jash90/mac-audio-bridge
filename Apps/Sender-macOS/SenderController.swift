import AVFoundation
import BridgeCore
import Foundation
import Synchronization

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

    private let tap = SystemAudioTap()
    private let converter = FrameConverter()
    private let udpSender = UDPSender()
    private let frameStats = FrameStats()

    var isRunning: Bool { phase == .running }

    func toggle(host: String) {
        if isRunning {
            stop()
        } else {
            Task { await start(host: host) }
        }
    }

    func start(host: String) async {
        guard !isRunning else { return }
        guard !host.isEmpty else {
            phase = .failed("Enter the iPhone's IP address first.")
            return
        }

        // Audio capture is gated by TCC; trigger the prompt up front so a denial is
        // reported here instead of as a silent tap.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                phase = .failed("Audio capture permission was denied.")
                return
            }
        default:
            phase = .failed(
                "Audio capture permission is denied. Allow it in System Settings → "
                    + "Privacy & Security → Microphone.")
            return
        }

        do {
            try tap.start()
        } catch {
            phase = .failed("Could not start the audio tap: \(error.localizedDescription)")
            return
        }

        tapSampleRate = tap.sampleRate
        frameStats.reset()
        converter.onFrame = { [udpSender, frameStats] frame in
            udpSender.send(frame)
            frameStats.increment()
        }
        udpSender.setHost(host)
        converter.start(ring: tap.ring, tapSampleRate: tap.sampleRate)
        phase = .running
    }

    func stop() {
        converter.stop()
        udpSender.cancel()
        tap.stop()
        tapSampleRate = nil
        framesPerSecond = 0
        phase = .idle
    }

    /// Pulls counter snapshots for the UI — call ~1 Hz.
    func refreshStats() {
        framesPerSecond = frameStats.takePerSecondCount()
    }
}
