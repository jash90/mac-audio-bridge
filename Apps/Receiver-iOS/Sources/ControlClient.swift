import BridgeCore
import Foundation
import Network
import os

/// One control connection to one Mac: TCP to its `_macaudiosrc._tcp`
/// service (every new connection resolves the Mac's current address), or to
/// an address — the Mac's tailnet IP / a typed host — on the fixed control
/// port. Sends the hello on connect, then delivers decoded `ControlMessage`s.
/// A connection whose peer is not on the local network or the tailnet
/// (`NetworkAddress.isTrustedForControl`) is refused. One-shot: after
/// `.disconnected` the owner creates a new client.
///
/// State is confined to `queue`; events go out through the `@Sendable`
/// callback (the owner hops to the main actor). `send`/`cancel` may be
/// called from any thread.
final class ControlClient: @unchecked Sendable {
    enum Event: Sendable {
        /// Ready; the peer's address class (nil: not reported).
        case connected(NetworkAddressKind?)
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

    /// An address (IP or host name) on the Mac's fixed control port.
    static func endpoint(host: String) -> NWEndpoint {
        let trimmed = host.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        return .hostPort(
            host: NWEndpoint.Host(trimmed), port: NWEndpoint.Port(rawValue: ControlProtocol.preferredPort)!)
    }

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
            let kind = Self.peerKind(connection)
            guard Self.isTrusted(kind, endpoint: connection.endpoint) else {
                logger.notice("Refusing a source address outside the LAN and the tailnet")
                finish()
                return
            }
            isReady = true
            if let hello = pendingHello {
                connection.send(content: ControlMessage.hello(hello).frame(), completion: Self.makeSendCompletion())
            }
            onEvent(.connected(kind))
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

    /// The connected peer's address class (nil when the path reports none).
    private static func peerKind(_ connection: NWConnection) -> NetworkAddressKind? {
        guard let remote = connection.currentPath?.remoteEndpoint,
            case .hostPort(let host, _) = remote
        else { return nil }
        switch host {
        case .ipv4(let address): return NetworkAddress.kind(ipv4: [UInt8](address.rawValue))
        case .ipv6(let address): return NetworkAddress.kind(ipv6: [UInt8](address.rawValue))
        case .name(let name, _): return NetworkAddress.kind(name)
        @unknown default: return nil
        }
    }

    /// Trusted: a LAN / tailnet / loopback peer. A path without a reported
    /// remote address is let through only for a Bonjour endpoint (resolved
    /// from a link-local browse).
    private static func isTrusted(_ kind: NetworkAddressKind?, endpoint: NWEndpoint) -> Bool {
        if let kind { return NetworkAddress.isTrustedForControl(kind) }
        if case .service = endpoint { return true }
        return false
    }
}
