import BridgeCore
import Foundation
import Network
import os
import Synchronization

/// Toggle (M2.6): send 16-byte keepalive datagrams back to the sender every
/// 20 ms while audio packets are arriving. iPhone Wi-Fi power save delivers
/// UDP in bursts (50-150 ms gaps and more), which the jitter buffer sees as
/// late/lost packets; a steady 20 ms reply stream keeps the radio in active
/// state. Set to false to measure the unmitigated burst behaviour.
private let receiverKeepaliveEnabled = true

/// Listens for UDP datagrams on port 49000. Each datagram is one `AudioPacket`
/// (10 ms of interleaved little-endian Int16 PCM); decoded packets are inserted
/// into the jitter buffer stamped with a monotonic arrival time. Datagrams that
/// fail `AudioPacket.decode`, or that carry an unexpected codec or payload
/// size, are dropped and counted as malformed. Start/stop run on the main
/// actor, callbacks are confined to one serial queue.
final class UDPReceiver: @unchecked Sendable {
    static let port: UInt16 = 49_000
    /// Expected payload of one PCM16 stereo frame: 480 frames × 2 channels × 2 bytes.
    private static let expectedPayloadBytes =
        AudioFormat.samplesPerFrame * AudioFormat.channelCount * MemoryLayout<Int16>.size
    /// Keepalive cadence, and how recently the last packet must have arrived
    /// for keepalives to keep flowing ("while playing").
    private static let keepaliveInterval: TimeInterval = 0.020
    private static let keepaliveActivityWindow: TimeInterval = 1.0
    /// 16-byte datagram, "MABK" magic + zeros. The sender drains and ignores
    /// everything that is not a valid audio packet.
    private static let keepalivePayload: Data = {
        var data = Data(count: 16)
        data[0] = 0x4D
        data[1] = 0x41
        data[2] = 0x42
        data[3] = 0x4B
        return data
    }()

    private let jitterBuffer: JitterBuffer
    private let queue = DispatchQueue(label: "dev.jash90.MacAudioBridge.udp-receiver")
    private let logger = Logger(subsystem: "dev.jash90.MacAudioBridge", category: "udp-receiver")
    private let malformedDatagrams = Atomic<Int>(0)
    /// Arrival-clock epoch. `ContinuousClock` never goes backwards, which the
    /// jitter buffer's interarrival estimates rely on.
    private let clockStart = ContinuousClock.now

    /// An accepted sender connection, and whether its path is ready (keepalive
    /// sends are dropped until it is).
    private struct Peer {
        let connection: NWConnection
        var isReady = false
    }

    // State confined to `queue`:
    private var listener: NWListener?
    private var peers: [Peer] = []
    private var keepaliveTimer: DispatchSourceTimer?
    /// Arrival time of the last accepted packet, and the largest gap between
    /// consecutive packets since the last `takeMaxInterArrivalGapSeconds`.
    private var lastPacketArrival: TimeInterval?
    private var maxInterArrivalGap: TimeInterval = 0

    init(jitterBuffer: JitterBuffer) {
        self.jitterBuffer = jitterBuffer
    }

    deinit {
        keepaliveTimer?.cancel()
    }

    /// Datagrams dropped since launch because they were not a valid audio packet.
    var malformedCount: Int {
        malformedDatagrams.load(ordering: .relaxed)
    }

    func start() throws {
        let alreadyRunning: Bool = queue.sync { listener != nil }
        guard !alreadyRunning else { return }
        let parameters = NWParameters.udp
        // WMM voice access class: the AP and iOS power-save scheduling favor
        // the voice queue, which tightens the delay distribution.
        parameters.serviceClass = .interactiveVoice
        let newListener = try NWListener(
            using: parameters,
            on: NWEndpoint.Port(rawValue: Self.port)!)
        queue.async { [weak self] in
            guard let self, self.listener == nil else {
                newListener.cancel()
                return
            }
            self.listener = newListener
            newListener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            newListener.start(queue: self.queue)
            self.startKeepaliveTimer()
            self.logger.info("Listening on UDP port \(Self.port) (serviceClass interactiveVoice)")
        }
    }

    func stop() {
        queue.sync {
            keepaliveTimer?.cancel()
            keepaliveTimer = nil
            listener?.cancel()
            listener = nil
            peers.forEach { $0.connection.cancel() }
            peers.removeAll()
        }
    }

    /// Largest gap between consecutive accepted packets since the last call
    /// (the burst signature of Wi-Fi power save), then resets the tracker.
    func takeMaxInterArrivalGapSeconds() -> TimeInterval {
        queue.sync {
            let value = maxInterArrivalGap
            maxInterArrivalGap = 0
            return value
        }
    }

    // MARK: - Queue-confined implementation

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.updatePeer(for: connection) { $0.isReady = true }
            case .failed(let error):
                self.logger.error("Connection failed: \(error.localizedDescription, privacy: .public)")
                self.drop(connection)
            case .cancelled:
                self.drop(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        peers.append(Peer(connection: connection))
        receiveLoop(on: connection)
    }

    private func updatePeer(for connection: NWConnection, _ update: (inout Peer) -> Void) {
        guard let index = peers.firstIndex(where: { $0.connection === connection }) else { return }
        update(&peers[index])
    }

    private func drop(_ connection: NWConnection) {
        connection.cancel()
        peers.removeAll { $0.connection === connection }
    }

    private func receiveLoop(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, isComplete {
                self.ingest(data)
            }
            if let error {
                self.logger.error(
                    "Receive failed: \(error.localizedDescription, privacy: .public)")
                self.drop(connection)
                return
            }
            self.receiveLoop(on: connection)
        }
    }

    private func ingest(_ data: Data) {
        let packet: AudioPacket
        do {
            packet = try AudioPacket.decode(data)
        } catch {
            countMalformed()
            return
        }
        guard packet.codec == .pcm16, packet.payload.count == Self.expectedPayloadBytes else {
            countMalformed()
            return
        }
        let arrival = elapsedSeconds()
        if let last = lastPacketArrival {
            maxInterArrivalGap = max(maxInterArrivalGap, arrival - last)
        }
        lastPacketArrival = arrival
        jitterBuffer.insert(packet, arrivalTime: arrival)
    }

    private func countMalformed() {
        malformedDatagrams.wrappingAdd(1, ordering: .relaxed)
    }

    // MARK: - Radio keepalive

    private func startKeepaliveTimer() {
        guard receiverKeepaliveEnabled, keepaliveTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.keepaliveInterval,
            repeating: Self.keepaliveInterval
        )
        timer.setEventHandler { [weak self] in
            self?.sendKeepaliveIfStreaming()
        }
        timer.resume()
        keepaliveTimer = timer
    }

    /// Sends one keepalive per ready peer while packets arrived within the
    /// last second. Sends on a not-ready connection would just error per
    /// datagram, so they are skipped instead.
    private func sendKeepaliveIfStreaming() {
        guard let lastArrival = lastPacketArrival,
            elapsedSeconds() - lastArrival < Self.keepaliveActivityWindow
        else { return }
        for peer in peers where peer.isReady {
            peer.connection.send(
                content: Self.keepalivePayload,
                completion: .contentProcessed { _ in
                    // Errors surface through the state handler; per-datagram
                    // logging would spam.
                }
            )
        }
    }

    /// Seconds elapsed on the monotonic arrival clock.
    private func elapsedSeconds() -> TimeInterval {
        let elapsed = ContinuousClock.now - clockStart
        return Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) * 1e-18
    }
}
