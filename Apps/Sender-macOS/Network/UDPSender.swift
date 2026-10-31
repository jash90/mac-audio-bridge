import Foundation
import Network
import os

/// Sends one UDP datagram per audio frame to `host:49000`. Recreates the connection
/// when the host changes. Thread-safe: `send` runs on the converter queue, the other
/// methods on the main actor.
final class UDPSender: @unchecked Sendable {
    static let port: UInt16 = 49_000

    private let stateQueue = DispatchQueue(label: "dev.jash90.MacAudioBridge.udp-sender")
    private let lock = NSLock()
    private var connection: NWConnection?
    private var host: String?
    private var isReady = false
    private let logger = Logger(subsystem: "dev.jash90.MacAudioBridge", category: "udp-sender")

    /// Points the sender at `host`, recreating the connection when it changes.
    /// An empty string tears the connection down.
    func setHost(_ host: String) {
        lock.lock()
        defer { lock.unlock() }
        guard host != self.host else { return }
        self.host = host
        if let oldConnection = connection {
            oldConnection.cancel()
            connection = nil
        }
        isReady = false
        guard !host.isEmpty else { return }

        let endpoint = NWEndpoint.Host(host)
        let port = NWEndpoint.Port(rawValue: Self.port)!
        let parameters = NWParameters.udp
        // WMM voice access class: keeps the stream in the AP's voice queue
        // and out of best-effort contention, and helps iOS power-save
        // scheduling on the receiving side.
        parameters.serviceClass = .interactiveVoice
        let newConnection = NWConnection(host: endpoint, port: port, using: parameters)
        newConnection.stateUpdateHandler = { [weak self] state in
            self?.handleState(state, host: host)
            if case .ready = state {
                self?.drainReceive(on: newConnection)
            }
        }
        newConnection.start(queue: stateQueue)
        connection = newConnection
        logger.info("Connecting to \(host, privacy: .public):\(Self.port)")
    }

    /// Consumes incoming datagrams silently. The receiver replies with 16-byte
    /// keepalive datagrams (and anything else that is not a valid audio packet
    /// for this sender role) — they are dropped here, without per-datagram
    /// logging; errors surface through the state handler.
    private func drainReceive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] _, _, _, error in
            guard error == nil else { return }
            self?.drainReceive(on: connection)
        }
    }

    /// Sends one datagram; dropped silently when the connection is not ready yet.
    func send(_ data: Data) {
        lock.lock()
        let connection = isReady ? connection : nil
        lock.unlock()
        guard let connection else { return }
        connection.send(content: data, completion: .contentProcessed { _ in
            // Errors surface through the state handler; per-frame logging would spam.
        })
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        connection?.cancel()
        connection = nil
        host = nil
        isReady = false
    }

    private func handleState(_ state: NWConnection.State, host: String) {
        lock.lock()
        switch state {
        case .ready:
            isReady = true
        case .waiting(let error):
            isReady = false
            logger.info("Waiting for path to \(host, privacy: .public): \(error.localizedDescription, privacy: .public)")
        case .failed(let error):
            isReady = false
            logger.error("Connection to \(host, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        case .cancelled:
            isReady = false
        default:
            break
        }
        lock.unlock()
    }
}
