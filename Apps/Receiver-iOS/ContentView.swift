import BridgeCore
import Combine
import SwiftUI

/// Wires the UDP receiver to the audio output and exposes UI state.
@MainActor
final class ReceiverModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var ipAddress: String?
    @Published private(set) var packetsPerSecond = 0
    @Published private(set) var bufferedMilliseconds = 0
    @Published private(set) var underrunCount = 0

    /// ≥ 1 s of 48 kHz interleaved stereo.
    private let ring = SPSCRingBuffer(capacity: 131_072)
    private let receiver: UDPReceiver
    private let output: AudioOutput

    init() {
        receiver = UDPReceiver(ring: ring)
        output = AudioOutput(ring: ring)
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

    /// Pulls counter snapshots for the UI — call ~1 Hz.
    func refreshStats() {
        packetsPerSecond = receiver.takePerSecondPackets()
        bufferedMilliseconds = Int(
            Double(ring.availableToRead / AudioFormat.channelCount)
                / AudioFormat.sampleRate * 1000)
        underrunCount = output.underrunCount
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
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
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
            statRow("Packets", "\(model.packetsPerSecond)/s")
            statRow("Buffered", "\(model.bufferedMilliseconds) ms")
            statRow("Underruns", "\(model.underrunCount)")
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
