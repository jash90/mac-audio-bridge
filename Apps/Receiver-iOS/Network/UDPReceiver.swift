import BridgeCore
import Foundation
import Network
import os
import Synchronization

/// Packet counter shared between the network queue (writer) and the UI (reader).
final class PacketStats: @unchecked Sendable {
    private let packets = Atomic<Int>(0)

    func add() {
        packets.wrappingAdd(1, ordering: .relaxed)
    }

    /// Returns the count since the last call and resets it to zero.
    func takePerSecondCount() -> Int {
        packets.exchange(0, ordering: .acquiringAndReleasing)
    }
}

/// Listens for UDP datagrams on port 49000. Each datagram is one 10 ms frame of
/// interleaved little-endian Int16; it is decoded to Float32 and appended to the
/// shared ring buffer. Start/stop run on the main actor, callbacks are confined
/// to one serial queue.
final class UDPReceiver: @unchecked Sendable {
    static let port: UInt16 = 49_000

    private let ring: SPSCRingBuffer
    private let queue = DispatchQueue(label: "dev.jash90.MacAudioBridge.udp-receiver")
    private let logger = Logger(subsystem: "dev.jash90.MacAudioBridge", category: "udp-receiver")
    let packetStats = PacketStats()

    // State confined to `queue`:
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var decodeScratch: UnsafeMutablePointer<Float>?
    private static let scratchSamples = 4_096

    init(ring: SPSCRingBuffer) {
        self.ring = ring
    }

    deinit {
        decodeScratch?.deallocate()
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

    /// Returns and resets the packets-per-second count for the UI.
    func takePerSecondPackets() -> Int {
        packetStats.takePerSecondCount()
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
        packetStats.add()
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return }
        if decodeScratch == nil {
            decodeScratch = UnsafeMutablePointer<Float>.allocate(capacity: Self.scratchSamples)
            decodeScratch?.initialize(repeating: 0, count: Self.scratchSamples)
        }
        guard let scratch = decodeScratch else { return }
        let toDecode = min(sampleCount, Self.scratchSamples)
        data.withUnsafeBytes { raw in
            for i in 0..<toDecode {
                let rawValue = raw.loadUnaligned(fromByteOffset: i * MemoryLayout<Int16>.size, as: Int16.self)
                scratch[i] = Float(Int16(littleEndian: rawValue)) / 32768
            }
        }
        ring.write(scratch, count: toDecode)
    }
}
