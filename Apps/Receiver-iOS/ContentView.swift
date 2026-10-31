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
    @Published private(set) var recoveredCount = 0
    @Published private(set) var concealedCount = 0
    @Published private(set) var malformedCount = 0
    /// "Opus 192 kbit/s" / "PCM (uncompressed)"; nil before the first frame.
    @Published private(set) var codecDescription: String?
    @Published private(set) var outputRoute: String?
    @Published private(set) var latencyMode: JitterLatencyMode = .balanced
    @Published private(set) var engineRunning = false
    @Published private(set) var engineRestarts = 0

    private let jitterBuffer = JitterBuffer(config: .latency(.balanced))
    private let receiver: UDPReceiver
    /// Owns the audio engine and keeps it running across interruptions,
    /// route changes and media-services resets.
    private let playback: PlaybackController
    private let statsWriter = StatsJSONLWriter()

    /// Model-owned stats loop (4 Hz UI refresh, 1 Hz JSONL line). It must NOT
    /// live in the view: `Timer.publish` publishers created inside a SwiftUI
    /// `body` are re-created on every body evaluation, so the 1 Hz logging
    /// timer was reset by the 4 Hz UI updates and never fired — stats.jsonl
    /// only got stale zero lines whenever the view sat still. A main-actor
    /// task keeps ticking in the background too, as long as the active audio
    /// session keeps the app running.
    private var statsLoop: Task<Void, Never>?
    private var tick = 0

    init() {
        receiver = UDPReceiver(jitterBuffer: jitterBuffer)
        playback = PlaybackController(jitterBuffer: jitterBuffer)
    }

    deinit {
        statsLoop?.cancel()
    }

    /// Starts listening and audio playback (called automatically on launch).
    /// Playback never fails the start: the controller retries on its own, so
    /// a session that cannot be activated right now (locked launch, call in
    /// progress) recovers without user action.
    func start() {
        guard phase != .running else { return }
        ipAddress = Self.wiFiIPv4Address()
        playback.start()
        do {
            try receiver.start()
            phase = .running
            startStatsLoop()
        } catch {
            phase = .failed("Start failed: \(error.localizedDescription)")
        }
    }

    /// Main-actor loop (the model is @MainActor, so the task inherits it):
    /// refresh the UI state every tick and write one JSONL line every fourth
    /// tick. Ticks where the task was resumed late self-correct on the next
    /// tick — the jitter-buffer counters are cumulative, not per-tick.
    private func startStatsLoop() {
        guard statsLoop == nil else { return }
        statsLoop = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshStats()
                if let self {
                    self.tick += 1
                    if self.tick.isMultiple(of: 4) {
                        self.logStats()
                    }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Applies a latency-mode change immediately: the buffer resets and
    /// prebuffers with the new target range.
    func setLatencyMode(_ mode: JitterLatencyMode) {
        guard mode != latencyMode else { return }
        latencyMode = mode
        jitterBuffer.applyConfig(.latency(mode))
    }

    /// Pulls latency and loss snapshots for the UI — called 4×/s by the
    /// model's stats loop.
    func refreshStats() {
        let stats = jitterBuffer.stats
        let session = AVAudioSession.sharedInstance()

        // Jitter-buffer depth plus the frame currently being rendered.
        let bufferFrames = Double(stats.depthFrames) + playback.partiallyPlayedFrames
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
        recoveredCount = stats.recovered
        let audio = playback.snapshot
        concealedCount = audio.concealment.concealedFrames
        codecDescription = audio.stream?.displayName
        malformedCount = receiver.malformedCount
        outputRoute = session.currentRoute.outputs.first?.portName
        engineRunning = playback.isEngineRunning
        engineRestarts = audio.engineRestarts
    }

    /// Writes one JSON line of telemetry to `Documents/stats.jsonl` — called
    /// 1 Hz by the model's stats loop. The encode happens here; only `Data`
    /// crosses to the writer's utility queue.
    func logStats() {
        guard phase == .running else { return }
        let stats = jitterBuffer.stats
        let session = AVAudioSession.sharedInstance()
        let outputSeconds = session.outputLatency + session.ioBufferDuration
        let audio = playback.snapshot
        statsWriter.append(
            StatsLine(
                timestamp: Date().timeIntervalSince1970,
                received: stats.received,
                played: stats.played,
                lost: stats.lost,
                late: stats.late,
                duplicates: stats.duplicates,
                overflowDropped: stats.overflowDropped,
                underruns: stats.underruns,
                rebuffers: stats.rebuffers,
                bufferingPops: stats.bufferingPops,
                depthFrames: stats.depthFrames,
                targetFrames: stats.targetFrames,
                jitterMs: stats.jitterSeconds * 1000,
                delayP50Ms: stats.delayP50Seconds * 1000,
                delayP95Ms: stats.delayP95Seconds * 1000,
                delayP99Ms: stats.delayP99Seconds * 1000,
                delayMaxMs: stats.delayMaxSeconds * 1000,
                maxInterArrivalGapMs: receiver.takeMaxInterArrivalGapSeconds() * 1000,
                outputMs: outputSeconds * 1000,
                route: session.currentRoute.outputs.first?.portName ?? "",
                latencyMode: latencyMode.rawValue,
                malformed: receiver.malformedCount,
                trimmed: stats.trimmed,
                engineRunning: audio.engineRunning,
                renderCallsPerSec: audio.renderCallsPerSecond,
                engineRestarts: audio.engineRestarts,
                sessionSampleRate: audio.sessionSampleRate,
                ioBufferMs: audio.ioBufferMilliseconds,
                routeChanges: audio.routeChanges,
                interruptions: audio.interruptions,
                redundantReceived: stats.redundantReceived,
                recovered: stats.recovered,
                underrunFrames: stats.underrunFrames,
                waitFrames: stats.waitFrames,
                concealedFrames: audio.concealment.concealedFrames,
                concealments: audio.concealment.concealments,
                fadeOuts: audio.concealment.fadeOuts,
                fadeIns: audio.concealment.fadeIns,
                crossfades: audio.concealment.crossfades,
                frameMs: AudioFormat.frameDurationMs,
                codec: audio.stream.map { StreamQuality.statsName($0.codec) } ?? "",
                codecKbps: audio.stream.map {
                    $0.payloadBytes * 8 / AudioFormat.frameDurationMs
                } ?? 0,
                decodeErrors: audio.concealment.decodeErrors,
                opusPlcFrames: audio.concealment.opusPlcFrames
            )
        )
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
    @AppStorage("latencyMode") private var latencyMode: JitterLatencyMode = .balanced

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "headphones")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            Text("Mac Audio Bridge")
                .font(.title2.bold())

            address

            latencyPicker

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
            model.setLatencyMode(latencyMode)
            model.start()
        }
        .onChange(of: latencyMode) { _, mode in
            model.setLatencyMode(mode)
        }
    }

    private var latencyPicker: some View {
        VStack(spacing: 4) {
            Text("Latency mode")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Picker("Latency mode", selection: $latencyMode) {
                ForEach(JitterLatencyMode.allCases, id: \.rawValue) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    /// The Mac discovers this receiver over Bonjour; the IP stays below,
    /// small, for debugging and the Mac's manual-address fallback.
    private var address: some View {
        ReceiverVisibilityView(ipAddress: model.ipAddress, isListening: model.phase == .running)
    }

    private var stats: some View {
        VStack(spacing: 6) {
            statRow("Codec", model.codecDescription ?? "—")
            statRow("Buffer", "\(model.bufferMilliseconds) ms")
            statRow("Target", "\(model.targetMilliseconds) ms")
            statRow("Output", "\(model.outputMilliseconds) ms")
            statRow("Total", "≈\(model.totalMilliseconds) ms (+ network)")
            statRow("Lost", String(format: "%.1f %%", model.lostPercent))
            statRow("Late", "\(model.lateCount)")
            statRow("Rebuffers", "\(model.rebufferCount)")
            statRow("Underruns", "\(model.underrunCount)")
            statRow("Recovered", "\(model.recoveredCount)")
            statRow("Concealed", "\(model.concealedCount) × \(AudioFormat.frameDurationMs) ms")
            statRow("Malformed", "\(model.malformedCount)")
            statRow(
                "Audio engine",
                "\(model.engineRunning ? "running" : "stopped") (restarts \(model.engineRestarts))")
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

extension JitterLatencyMode {
    var displayName: String {
        switch self {
        case .low: "Low"
        case .balanced: "Balanced"
        case .safe: "Safe"
        }
    }
}
