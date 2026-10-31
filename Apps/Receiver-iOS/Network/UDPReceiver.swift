import BridgeCore
import Foundation
import Network
import os
import Synchronization

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

    private let jitterBuffer: JitterBuffer
    private let queue = DispatchQueue(label: "dev.jash90.MacAudioBridge.udp-receiver")
    private let logger = Logger(subsystem: "dev.jash90.MacAudioBridge", category: "udp-receiver")
    private let malformedDatagrams = Atomic<Int>(0)
    /// Arrival-clock epoch. `ContinuousClock` never goes backwards, which the
    /// jitter buffer's interarrival estimates rely on.
    private let clockStart = ContinuousClock.now

    // State confined to `queue`:
    private var listener: NWListener?
    private var connections: [NWConnection] = []

    init(jitterBuffer: JitterBuffer) {
        self.jitterBuffer = jitterBuffer
    }

    /// Datagrams dropped since launch because they were not a valid audio packet.
    var malformedCount: Int {
        malformedDatagrams.load(ordering: .relaxed)
    }

    func start() throws {
        let alreadyRunning: Bool = queue.sync { listener != nil }
        guard !alreadyRunning else { return }
        let newListener = try NWListener(
            using: .udp,
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
            self.logger.info("Listening on UDP port \(Self.port)")
        }
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    // MARK: - Queue-confined implementation

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                self?.logger.error("Connection failed: \(error.localizedDescription, privacy: .public)")
                self?.drop(connection)
            case .cancelled:
                self?.drop(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveLoop(on: connection)
    }

    private func drop(_ connection: NWConnection) {
        connection.cancel()
        connections.removeAll { $0 === connection }
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
        jitterBuffer.insert(packet, arrivalTime: elapsedSeconds())
    }

    private func countMalformed() {
        malformedDatagrams.wrappingAdd(1, ordering: .relaxed)
    }

    /// Seconds elapsed on the monotonic arrival clock.
    private func elapsedSeconds() -> TimeInterval {
        let elapsed = ContinuousClock.now - clockStart
        return Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) * 1e-18
    }
}
