import AVFoundation
import BridgeCore
import SwiftUI

/// Wires the UDP receiver and audio output to the shared jitter buffer and
/// exposes UI state.
@MainActor
final class ReceiverModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var ipAddress: String?
    @Published private(set) var bufferMilliseconds = 0
    @Published private(set) var targetMilliseconds = 0
    @Published private(set) var outputMilliseconds = 0
    @Published private(set) var totalMilliseconds = 0
    @Published private(set) var lostPercent: Double = 0
    @Published private(set) var lateCount = 0
    @Published private(set) var rebufferCount = 0
    @Published private(set) var underrunCount = 0
    @Published private(set) var malformedCount = 0
    @Published private(set) var outputRoute: String?

    private let jitterBuffer = JitterBuffer(config: .lowLatency)
    private let receiver: UDPReceiver
    private let output: AudioOutput

    init() {
        receiver = UDPReceiver(jitterBuffer: jitterBuffer)
        output = AudioOutput(jitterBuffer: jitterBuffer)
    }

    /// Starts listening and audio playback (called automatically on launch).
    func start() {
        guard phase != .running else { return }
        ipAddress = Self.wiFiIPv4Address()
        do {
            try output.start()
            try receiver.start()
            phase = .running
        } catch {
            phase = .failed("Start failed: \(error.localizedDescription)")
        }
    }

    /// Pulls latency and loss snapshots for the UI — call 4×/s.
    func refreshStats() {
        let stats = jitterBuffer.stats
        let session = AVAudioSession.sharedInstance()

        // Jitter-buffer depth plus the frame currently being rendered.
        let bufferFrames = Double(stats.depthFrames) + output.partiallyPlayedFrames
        bufferMilliseconds = Int(
            (bufferFrames * Double(AudioFormat.frameDurationMs)).rounded())
        targetMilliseconds = stats.targetFrames * AudioFormat.frameDurationMs
        // On Bluetooth this includes the headphone link's own latency.
        let outputSeconds = session.outputLatency + session.ioBufferDuration
        outputMilliseconds = Int((outputSeconds * 1000).rounded())
        totalMilliseconds = bufferMilliseconds + outputMilliseconds

        let playoutSlots = stats.played + stats.lost
        lostPercent = playoutSlots > 0
            ? Double(stats.lost) / Double(playoutSlots) * 100 : 0
        lateCount = stats.late
        rebufferCount = stats.rebuffers
        underrunCount = stats.underruns
        malformedCount = receiver.malformedCount
        outputRoute = session.currentRoute.outputs.first?.portName
    }

    /// The device's Wi-Fi IPv4 address (interface en0), shown so the user can type
    /// it into the Mac app.
    nonisolated private static func wiFiIPv4Address() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let interface = current.pointee
            cursor = interface.ifa_next
            guard let address = interface.ifa_addr,
                address.pointee.sa_family == UInt8(AF_INET),
                String(cString: interface.ifa_name) == "en0"
            else { continue }
            var addressCopy = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard let rendered = inet_ntop(
                AF_INET, &addressCopy.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN))
            else {
                return nil
            }
            let length = Int(strlen(rendered))
            return rendered.withMemoryRebound(to: UInt8.self, capacity: length) {
                String(decoding: UnsafeBufferPointer(start: $0, count: length), as: UTF8.self)
            }
        }
        return nil
    }
}

struct ContentView: View {
    @StateObject private var model = ReceiverModel()

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "headphones")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            Text("Mac Audio Bridge")
                .font(.title2.bold())

            address

            stats

            if case .failed(let message) = model.phase {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .task {
            model.start()
        }
        .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { _ in
            model.refreshStats()
        }
    }

    private var address: some View {
        VStack(spacing: 4) {
            Text("Type this address into the Mac app")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(model.ipAddress ?? "No Wi-Fi address (en0)")
                .font(.title3.monospaced().bold())
                .textSelection(.enabled)
            Text(model.phase == .running ? "Listening on UDP 49000" : "Listener stopped")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var stats: some View {
        VStack(spacing: 6) {
            statRow("Buffer", "\(model.bufferMilliseconds) ms")
            statRow("Target", "\(model.targetMilliseconds) ms")
            statRow("Output", "\(model.outputMilliseconds) ms")
            statRow("Total", "≈\(model.totalMilliseconds) ms (+ network)")
            statRow("Lost", String(format: "%.1f %%", model.lostPercent))
            statRow("Late", "\(model.lateCount)")
            statRow("Rebuffers", "\(model.rebufferCount)")
            statRow("Underruns", "\(model.underrunCount)")
            statRow("Malformed", "\(model.malformedCount)")
            if let route = model.outputRoute {
                statRow("Route", route)
            }
        }
        .font(.callout.monospacedDigit())
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .frame(maxWidth: 260)
    }
}
