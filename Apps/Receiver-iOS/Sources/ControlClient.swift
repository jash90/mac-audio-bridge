import BridgeCore
import Foundation
import Network
import os

/// One control connection to one Mac (TCP to its `_macaudiosrc._tcp`
/// service, so every new connection resolves the Mac's current address).
/// Sends the hello on connect, then delivers decoded `ControlMessage`s. A
/// connection whose resolved peer is not on the local network is refused.
/// One-shot: after `.disconnected` the owner creates a new client.
///
/// State is confined to `queue`; events go out through the `@Sendable`
/// callback (the owner hops to the main actor). `send`/`cancel` may be
/// called from any thread.
final class ControlClient: @unchecked Sendable {
    enum Event: Sendable {
        case connected
        case message(ControlMessage)
        /// The Mac runs another protocol version (update one of the apps).
        case incompatible(Int)
        case disconnected
    }

    private let queue = DispatchQueue(label: "dev.jash90.MacAudioBridge.control-client")
    private let logger = Logger(subsystem: "dev.jash90.MacAudioBridge", category: "control-client")
    private let onEvent: @Sendable (Event) -> Void
    private let connection: NWConnection

    // Confined to `queue`:
    private var decoder = ControlFrameDecoder()
    private var isReady = false
    private var isFinished = false
    private var pendingHello: PhoneHello?

    init(endpoint: NWEndpoint, onEvent: @escaping @Sendable (Event) -> Void) {
        self.onEvent = onEvent
        connection = Self.makeConnection(to: endpoint)
    }

    func start(hello: PhoneHello) {
        queue.async { [self] in
            pendingHello = hello
            connection.stateUpdateHandler = Self.makeStateHandler(client: self)
            connection.start(queue: queue)
        }
    }

    func send(_ message: ControlMessage) {
        let frame = message.frame()
        queue.async { [self] in
            guard isReady, !isFinished else { return }
            connection.send(content: frame, completion: Self.makeSendCompletion())
        }
    }

    func cancel() {
        queue.async { [self] in
            finish()
        }
    }

    // MARK: - Queue-confined

    private func handleState(_ state: NWConnection.State) {
        guard !isFinished else { return }
        switch state {
        case .ready:
            guard Self.isLocalPeer(connection) else {
                logger.notice("Refusing a non-local source address")
                finish()
                return
            }
            isReady = true
            if let hello = pendingHello {
                connection.send(content: ControlMessage.hello(hello).frame(), completion: Self.makeSendCompletion())
            }
            onEvent(.connected)
            receive()
        case .waiting, .failed:
            // Refused / unreachable: the owner retries with a fresh client.
            finish()
        case .cancelled:
            finish()
        default:
            break
        }
    }

    private func receive() {
        connection.receive(
            minimumIncompleteLength: 1, maximumLength: 65_536,
            completion: Self.makeReceiveHandler(client: self))
    }

    private func handleReceive(_ data: Data?, isComplete: Bool, error: NWError?) {
        guard !isFinished else { return }
        if let data, !data.isEmpty {
            let payloads: [Data]
            do {
                payloads = try decoder.append(data)
            } catch {
                logger.error("Bad control framing from the Mac, closing")
                finish()
                return
            }
            for payload in payloads {
                do {
                    onEvent(.message(try ControlMessage.decode(payload: payload)))
                } catch .versionMismatch(let version) {
                    onEvent(.incompatible(version))
                    finish()
                    return
                } catch {
                    logger.error("Malformed control frame skipped")
                }
            }
        }
        if isComplete || error != nil {
            finish()
            return
        }
        receive()
    }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        isReady = false
        connection.cancel()
        onEvent(.disconnected)
    }

    // MARK: - Nonisolated factories

    nonisolated private static func makeConnection(to endpoint: NWEndpoint) -> NWConnection {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 5
        return NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: tcp))
    }

    nonisolated private static func makeStateHandler(client: ControlClient) -> @Sendable (NWConnection.State) -> Void {
        { [weak client] state in
            client?.handleState(state)
        }
    }

    nonisolated private static func makeReceiveHandler(
        client: ControlClient
    ) -> @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void {
        { [weak client] data, _, isComplete, error in
            client?.handleReceive(data, isComplete: isComplete, error: error)
        }
    }

    nonisolated private static func makeSendCompletion() -> NWConnection.SendCompletion {
        .contentProcessed { _ in
            // Failures surface through the state handler.
        }
    }

    /// The resolved peer address must be on the local network (a path
    /// without a reported remote address is let through: it was resolved
    /// from a link-local Bonjour browse).
    private static func isLocalPeer(_ connection: NWConnection) -> Bool {
        guard let remote = connection.currentPath?.remoteEndpoint else { return true }
        guard case .hostPort(let host, _) = remote else { return false }
        switch host {
        case .ipv4(let address): return LocalNetworkAddress.isLocal(ipv4: [UInt8](address.rawValue))
        case .ipv6(let address): return LocalNetworkAddress.isLocal(ipv6: [UInt8](address.rawValue))
        default: return false
        }
    }
}
