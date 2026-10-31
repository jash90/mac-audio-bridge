import BridgeCore
import Foundation
import Network
import SystemConfiguration
import dnssd
import os

/// This Mac's identity as an audio source: a UUID generated once and
/// persisted (so the phone recognises the Mac across launches and address
/// changes) and the computer name the phone shows.
enum SourceIdentity {
    private static let idKey = "sourceID"

    static let id: String = {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: idKey), UUID(uuidString: stored) != nil {
            return stored
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: idKey)
        return fresh
    }()

    static var tag: UInt32 { SourceTag.make(sourceID: id) }

    /// The computer name (System Settings → General → Sharing), trimmed to
    /// the 63-byte DNS-SD limit.
    static func computerName() -> String {
        var name = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
        if name.trimmingCharacters(in: .whitespaces).isEmpty { name = "Mac" }
        while name.utf8.count > ReceiverService.maxNameBytes { name.removeLast() }
        return name
    }
}

/// Advertises this Mac as `_macaudiosrc._tcp` (TXT `v`, `id`) and serves the
/// phones' control connections (TCP, `ControlProtocol` frames). A failed
/// listener is recreated. Connections from non-local addresses are closed
/// at once (see the trust note in `ControlProtocol`).
///
/// All state is confined to `queue`; events reach the owner through the
/// `@Sendable` callback (which hops to the main actor itself). `send` and
/// `close` may be called from any thread.
final class ControlServer: @unchecked Sendable {
    typealias SessionID = Int

    enum Status: Equatable, Sendable {
        case starting
        case advertising
        case localNetworkDenied
        case failed(String)
    }

    enum Event: Sendable {
        case status(Status)
        /// The name Bonjour actually registered (it renames on a conflict).
        case registeredName(String)
        case opened(SessionID)
        case message(SessionID, ControlMessage)
        case closed(SessionID)
    }

    private struct Session {
        let connection: NWConnection
        var decoder = ControlFrameDecoder()
    }

    private static let restartDelay: TimeInterval = 2

    private let queue = DispatchQueue(label: "dev.jash90.MacAudioBridge.control-server")
    private let logger = Logger(subsystem: "dev.jash90.MacAudioBridge", category: "control-server")
    private let serviceName: String
    private let onEvent: @Sendable (Event) -> Void

    // Confined to `queue`:
    private var listener: NWListener?
    private var generation: UInt64 = 0
    private var isRunning = false
    private var sessions: [SessionID: Session] = [:]
    private var nextSessionID: SessionID = 1

    init(serviceName: String, onEvent: @escaping @Sendable (Event) -> Void) {
        self.serviceName = serviceName
        self.onEvent = onEvent
    }

    func start() {
        queue.async { [self] in
            guard !isRunning else { return }
            isRunning = true
            startListenerOnQueue()
        }
    }

    func stop() {
        queue.async { [self] in
            isRunning = false
            generation &+= 1
            listener?.cancel()
            listener = nil
            for session in sessions.values { session.connection.cancel() }
            sessions.removeAll()
        }
    }

    func send(_ message: ControlMessage, to id: SessionID) {
        let frame = message.frame()
        queue.async { [self] in
            guard let session = sessions[id] else { return }
            session.connection.send(content: frame, completion: Self.makeSendCompletion())
        }
    }

    func close(_ id: SessionID) {
        queue.async { [self] in
            drop(id)
        }
    }

    // MARK: - Listener (queue-confined)

    private func startListenerOnQueue() {
        listener?.cancel()
        listener = nil
        generation &+= 1
        let newListener: NWListener
        do {
            newListener = try Self.makeListener(serviceName: serviceName)
        } catch {
            logger.error("Control listener creation failed: \(error.localizedDescription, privacy: .public)")
            onEvent(.status(.failed(error.localizedDescription)))
            scheduleRestart()
            return
        }
        let generation = generation
        newListener.stateUpdateHandler = Self.makeListenerStateHandler(server: self, generation: generation)
        newListener.newConnectionHandler = Self.makeConnectionHandler(server: self, generation: generation)
        newListener.serviceRegistrationUpdateHandler = Self.makeRegistrationHandler(
            server: self, generation: generation)
        listener = newListener
        onEvent(.status(.starting))
        newListener.start(queue: queue)
    }

    private func scheduleRestart() {
        let generation = generation
        queue.asyncAfter(deadline: .now() + Self.restartDelay) { [self] in
            guard isRunning, generation == self.generation else { return }
            startListenerOnQueue()
        }
    }

    private func handleListenerState(_ state: NWListener.State, generation: UInt64) {
        guard generation == self.generation else { return }
        switch state {
        case .ready:
            onEvent(.status(.advertising))
            logger.info("Control listener on port \(self.listener?.port?.rawValue ?? 0)")
        case .waiting(let error):
            onEvent(.status(Self.isPolicyDenied(error) ? .localNetworkDenied : .failed(error.localizedDescription)))
        case .failed(let error):
            logger.error("Control listener failed: \(error.localizedDescription, privacy: .public)")
            onEvent(.status(Self.isPolicyDenied(error) ? .localNetworkDenied : .failed(error.localizedDescription)))
            listener?.cancel()
            listener = nil
            scheduleRestart()
        default:
            break
        }
    }

    private func handleRegistration(_ change: NWListener.ServiceRegistrationChange, generation: UInt64) {
        guard generation == self.generation else { return }
        if case .add(let endpoint) = change, case .service(let name, _, _, _) = endpoint {
            onEvent(.registeredName(name))
        }
    }

    // MARK: - Sessions (queue-confined)

    private func accept(_ connection: NWConnection, generation: UInt64) {
        guard generation == self.generation, isRunning else {
            connection.cancel()
            return
        }
        guard Self.isLocal(connection.endpoint) else {
            logger.notice("Rejected control connection from non-local \(String(describing: connection.endpoint), privacy: .public)")
            connection.cancel()
            return
        }
        let id = nextSessionID
        nextSessionID += 1
        sessions[id] = Session(connection: connection)
        connection.stateUpdateHandler = Self.makeSessionStateHandler(server: self, id: id)
        connection.start(queue: queue)
        receive(on: connection, id: id)
        onEvent(.opened(id))
    }

    private func handleSessionState(_ state: NWConnection.State, id: SessionID) {
        switch state {
        case .failed(let error):
            logger.info("Control session \(id) failed: \(error.localizedDescription, privacy: .public)")
            drop(id)
        case .cancelled:
            drop(id)
        default:
            break
        }
    }

    private func receive(on connection: NWConnection, id: SessionID) {
        connection.receive(
            minimumIncompleteLength: 1, maximumLength: 65_536,
            completion: Self.makeReceiveHandler(server: self, id: id))
    }

    private func handleReceive(_ data: Data?, isComplete: Bool, error: NWError?, id: SessionID) {
        guard var session = sessions[id] else { return }
        if let data, !data.isEmpty {
            let payloads: [Data]
            do {
                payloads = try session.decoder.append(data)
            } catch {
                logger.error("Control session \(id): bad framing, closing")
                drop(id)
                return
            }
            sessions[id] = session
            for payload in payloads {
                do {
                    onEvent(.message(id, try ControlMessage.decode(payload: payload)))
                } catch .versionMismatch(let version) {
                    logger.error("Control session \(id): protocol version \(version), closing")
                    drop(id)
                    return
                } catch {
                    logger.error("Control session \(id): malformed frame skipped")
                }
            }
        }
        if isComplete || error != nil {
            drop(id)
            return
        }
        receive(on: session.connection, id: id)
    }

    private func drop(_ id: SessionID) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        session.connection.cancel()
        onEvent(.closed(id))
    }

    // MARK: - Nonisolated factories (capture only Sendable state)

    nonisolated private static func makeListener(serviceName: String) throws -> NWListener {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcp)
        let listener = try NWListener(using: parameters)
        listener.service = NWListener.Service(
            name: serviceName,
            type: ControlProtocol.serviceType,
            domain: nil,
            txtRecord: NWTXTRecord([
                ControlProtocol.versionKey: ControlProtocol.txtVersion,
                ControlProtocol.idKey: SourceIdentity.id,
            ]))
        return listener
    }

    nonisolated private static func makeListenerStateHandler(
        server: ControlServer, generation: UInt64
    ) -> @Sendable (NWListener.State) -> Void {
        { [weak server] state in
            server?.handleListenerState(state, generation: generation)
        }
    }

    nonisolated private static func makeConnectionHandler(
        server: ControlServer, generation: UInt64
    ) -> @Sendable (NWConnection) -> Void {
        { [weak server] connection in
            guard let server else {
                connection.cancel()
                return
            }
            server.accept(connection, generation: generation)
        }
    }

    nonisolated private static func makeRegistrationHandler(
        server: ControlServer, generation: UInt64
    ) -> @Sendable (NWListener.ServiceRegistrationChange) -> Void {
        { [weak server] change in
            server?.handleRegistration(change, generation: generation)
        }
    }

    nonisolated private static func makeSessionStateHandler(
        server: ControlServer, id: SessionID
    ) -> @Sendable (NWConnection.State) -> Void {
        { [weak server] state in
            server?.handleSessionState(state, id: id)
        }
    }

    nonisolated private static func makeReceiveHandler(
        server: ControlServer, id: SessionID
    ) -> @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void {
        { [weak server] data, _, isComplete, error in
            server?.handleReceive(data, isComplete: isComplete, error: error, id: id)
        }
    }

    nonisolated private static func makeSendCompletion() -> NWConnection.SendCompletion {
        .contentProcessed { _ in
            // Failures surface through the state handler.
        }
    }

    // MARK: - Helpers

    /// Whether the peer's address is on the local network.
    static func isLocal(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return LocalNetworkAddress.isLocal(ipv4: [UInt8](address.rawValue))
        case .ipv6(let address): return LocalNetworkAddress.isLocal(ipv6: [UInt8](address.rawValue))
        default: return false
        }
    }

    private static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error {
            return code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied)
        }
        return false
    }
}
