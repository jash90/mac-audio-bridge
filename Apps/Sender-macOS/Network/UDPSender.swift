import BridgeCore
import Foundation
import Network
import os
import Synchronization

/// Sends the datagrams of every audio frame (primary + redundant copy, see
/// `AudioRedundancy`) to the current `ReceiverTarget` —
/// a Bonjour service (resolved by the system on every new connection) or a
/// manual host on port 49000.
///
/// Liveness: the receiver answers with a 16-byte "MABK" keepalive every
/// 20 ms (200 ms on the WAN profile) while packets arrive; its flags byte
/// says whether the phone's path is expensive. A timer on the connection
/// queue (every 500 ms, independent of the UI) feeds the keepalive / send
/// timestamps into `ReceiverLiveness`; after `livenessTimeout` (3 s, 5 s on
/// WAN) of unanswered sends, or without a ready path, the connection is
/// cancelled and recreated, which re-resolves the service — this is what
/// follows the iPhone to a new DHCP address. The owner watches the
/// reconnect count to fail over to another path (`PathFailover`).
///
/// Thread-safety: `send` runs on the converter queue (one lock read plus
/// relaxed atomics — no buffering, no extra hop: datagrams go straight to
/// `NWConnection.send`), `setTarget`/`cancel`/`linkSnapshot` on the main
/// actor, framework callbacks and the liveness timer on `stateQueue`.
final class UDPSender: @unchecked Sendable {
    /// Point-in-time view of the link for the menu and the stats line.
    struct LinkSnapshot: Sendable {
        var target: ReceiverTarget?
        /// NWConnection state name ("none" without a connection).
        var connectionState: String
        var link: ReceiverLiveness.State?
        var keepaliveAge: TimeInterval?
        /// Connections recreated by the liveness check since launch.
        var reconnects: Int
        /// The resolved remote address of the ready connection.
        var remoteAddress: String?
        var remoteKind: NetworkAddressKind?
        /// Flags of the latest keepalive (the phone's path).
        var peerFlags: ReceiverKeepalive.Flags
    }

    private static let livenessCheckInterval: DispatchTimeInterval = .milliseconds(500)

    /// User-interactive: the connection's I/O and callbacks run here, and a
    /// throttled queue would add its own pacing jitter to every datagram.
    private let stateQueue = DispatchQueue(label: "dev.jash90.MacAudioBridge.udp-sender", qos: .userInteractive)
    private let logger = Logger(subsystem: "dev.jash90.MacAudioBridge", category: "udp-sender")

    // Guarded by `lock`:
    private let lock = NSLock()
    private var target: ReceiverTarget?
    private var connection: NWConnection?
    /// Bumped on every new connection; callbacks of older ones are ignored.
    private var generation: UInt64 = 0
    private var isReady = false
    private var connectionState = "none"
    private var connectionStartNanos: UInt64 = 0
    private var lastLinkState: ReceiverLiveness.State?
    private var reconnectCount = 0
    private var livenessTimer: DispatchSourceTimer?
    private var livenessTimeout = ReceiverLiveness.defaultTimeout
    private var remoteAddress: String?
    private var remoteKind: NetworkAddressKind?

    /// Uptime (ns) of the last keepalive on the current connection, 0 = none.
    private let lastKeepaliveNanos = Atomic<UInt64>(0)
    /// Uptime (ns) of the first datagram sent after the last keepalive,
    /// 0 = nothing unanswered.
    private let unansweredSinceNanos = Atomic<UInt64>(0)
    /// Cumulative datagrams/bytes handed to the connection (diagnostics for
    /// the stats log; relaxed readouts).
    private let sentDatagrams = Atomic<Int>(0)
    private let sentBytes = Atomic<Int>(0)
    /// Flags byte of the latest keepalive.
    private let peerFlags = Atomic<UInt8>(0)

    // MARK: - Control (main actor)

    /// Points the sender at `target`, recreating the connection when it
    /// changes; nil tears it down.
    func setTarget(_ newTarget: ReceiverTarget?) {
        lock.withLock {
            guard newTarget != target else { return }
            target = newTarget
            reconnectLocked(reason: "target changed")
            if newTarget == nil {
                stopLivenessTimerLocked()
            } else {
                startLivenessTimerLocked()
            }
        }
    }

    /// The keepalive timeout of the profile in use.
    func setLivenessTimeout(_ seconds: TimeInterval) {
        lock.withLock { livenessTimeout = seconds }
    }

    func cancel() {
        lock.withLock {
            target = nil
            reconnectLocked(reason: "cancelled")
            stopLivenessTimerLocked()
        }
    }

    /// Sends one datagram; dropped silently when the connection is not ready yet.
    func send(_ data: Data) {
        lock.lock()
        let connection = isReady ? connection : nil
        lock.unlock()
        guard let connection else { return }
        if unansweredSinceNanos.load(ordering: .relaxed) == 0 {
            _ = unansweredSinceNanos.compareExchange(
                expected: 0, desired: Self.nowNanos(), ordering: .relaxed)
        }
        sentDatagrams.wrappingAdd(1, ordering: .relaxed)
        sentBytes.wrappingAdd(data.count, ordering: .relaxed)
        connection.send(content: data, completion: .contentProcessed { _ in
            // Errors surface through the state handler; per-frame logging would spam.
        })
    }

    /// Datagrams and bytes sent since the last call, then resets the counters.
    func takeSentCounts() -> (datagrams: Int, bytes: Int) {
        let datagrams = sentDatagrams.exchange(0, ordering: .acquiringAndReleasing)
        let bytes = sentBytes.exchange(0, ordering: .acquiringAndReleasing)
        return (datagrams, bytes)
    }

    func linkSnapshot() -> LinkSnapshot {
        let keepalive = lastKeepaliveNanos.load(ordering: .relaxed)
        let keepaliveAge = keepalive == 0 ? nil : Self.seconds(since: keepalive)
        return lock.withLock {
            LinkSnapshot(
                target: target,
                connectionState: connectionState,
                link: connection == nil ? nil : lastLinkState,
                keepaliveAge: connection == nil ? nil : keepaliveAge,
                reconnects: reconnectCount,
                remoteAddress: connection == nil ? nil : remoteAddress,
                remoteKind: connection == nil ? nil : remoteKind,
                peerFlags: ReceiverKeepalive.Flags(rawValue: peerFlags.load(ordering: .relaxed)))
        }
    }

    // MARK: - Connection lifecycle (lock held)

    /// Cancels the current connection and, when a target is set, starts a
    /// fresh one (a fresh connection resolves the Bonjour service again).
    private func reconnectLocked(reason: String) {
        connection?.cancel()
        connection = nil
        isReady = false
        lastLinkState = nil
        generation &+= 1
        lastKeepaliveNanos.store(0, ordering: .relaxed)
        unansweredSinceNanos.store(0, ordering: .relaxed)
        remoteAddress = nil
        remoteKind = nil
        guard let target else {
            connectionState = "none"
            return
        }
        let newConnection = Self.makeConnection(to: target)
        newConnection.stateUpdateHandler = Self.makeStateHandler(
            sender: self, connection: newConnection, generation: generation)
        connection = newConnection
        connectionState = "setup"
        connectionStartNanos = Self.nowNanos()
        lastLinkState = .connecting
        newConnection.start(queue: stateQueue)
        logger.info(
            "Connecting to \(target.displayName, privacy: .public) (\(reason, privacy: .public))")
    }

    private func startLivenessTimerLocked() {
        guard livenessTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(
            deadline: .now() + Self.livenessCheckInterval,
            repeating: Self.livenessCheckInterval)
        timer.setEventHandler(handler: Self.makeLivenessHandler(sender: self))
        timer.resume()
        livenessTimer = timer
    }

    private func stopLivenessTimerLocked() {
        livenessTimer?.cancel()
        livenessTimer = nil
    }

    // MARK: - Framework callbacks (stateQueue)

    private func handleState(_ state: NWConnection.State, generation: UInt64) {
        let ready: Bool
        lock.lock()
        guard generation == self.generation else {
            lock.unlock()
            return
        }
        let name = target?.displayName ?? "?"
        switch state {
        case .setup:
            connectionState = "setup"
        case .preparing:
            connectionState = "preparing"
        case .ready:
            connectionState = "ready"
            isReady = true
            if case .hostPort(let host, _)? = connection?.currentPath?.remoteEndpoint {
                (remoteAddress, remoteKind) = Self.describe(host)
            }
        case .waiting(let error):
            connectionState = "waiting"
            isReady = false
            logger.info(
                "Waiting for path to \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        case .failed(let error):
            connectionState = "failed"
            isReady = false
            logger.error(
                "Connection to \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        case .cancelled:
            connectionState = "cancelled"
            isReady = false
        @unknown default:
            break
        }
        ready = isReady
        let connection = self.connection
        lock.unlock()
        if ready, case .ready = state, let connection {
            receiveLoop(on: connection, generation: generation)
        }
    }

    /// Reads the receiver's replies. 16-byte "MABK" keepalives refresh the
    /// liveness clock; anything else is dropped silently (no per-datagram
    /// logging). Errors end the loop; the state handler reports them.
    private func receiveLoop(on connection: NWConnection, generation: UInt64) {
        connection.receiveMessage(
            completion: Self.makeReceiveHandler(
                sender: self, connection: connection, generation: generation))
    }

    private func handleReceive(
        _ data: Data?, error: NWError?, connection: NWConnection, generation: UInt64
    ) {
        guard error == nil else { return }
        let current = lock.withLock { generation == self.generation }
        guard current else { return }
        if let data, let flags = ReceiverKeepalive.decode(data) {
            lastKeepaliveNanos.store(Self.nowNanos(), ordering: .relaxed)
            unansweredSinceNanos.store(0, ordering: .relaxed)
            peerFlags.store(flags.rawValue, ordering: .relaxed)
        }
        receiveLoop(on: connection, generation: generation)
    }

    /// Liveness check, every 500 ms on `stateQueue`.
    private func checkLiveness() {
        let now = Self.nowNanos()
        let keepalive = lastKeepaliveNanos.load(ordering: .relaxed)
        let unanswered = unansweredSinceNanos.load(ordering: .relaxed)
        lock.withLock {
            guard target != nil, connection != nil else { return }
            let assessment = ReceiverLiveness.assess(
                connectionAge: Self.seconds(from: connectionStartNanos, to: now),
                isReady: isReady,
                keepaliveAge: keepalive == 0 ? nil : Self.seconds(from: keepalive, to: now),
                unansweredSendAge: unanswered == 0 ? nil : Self.seconds(from: unanswered, to: now),
                timeout: livenessTimeout)
            if assessment.decision == .reconnect {
                reconnectCount += 1
                logger.info(
                    "No keepalive from \(self.target?.displayName ?? "?", privacy: .public) — recreating the connection")
                reconnectLocked(reason: "liveness timeout")
                lastLinkState = .noResponse
            } else if assessment.state == .connecting, lastLinkState == .noResponse {
                // Recreated after a timeout: keep reporting "no response"
                // until a keepalive actually arrives on the new connection.
            } else {
                lastLinkState = assessment.state
            }
        }
    }

    // MARK: - Nonisolated factories (capture only Sendable state)

    nonisolated private static func makeConnection(to target: ReceiverTarget) -> NWConnection {
        let parameters = NWParameters.udp
        // WMM voice access class: keeps the stream in the AP's voice queue
        // and out of best-effort contention, and helps iOS power-save
        // scheduling on the receiving side.
        parameters.serviceClass = .interactiveVoice
        let endpoint: NWEndpoint
        switch target {
        case .service(let name):
            endpoint = .service(
                name: name, type: ReceiverService.type, domain: ReceiverService.domain,
                interface: nil)
        case .host(let host):
            endpoint = .hostPort(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: ReceiverService.preferredPort)!)
        }
        return NWConnection(to: endpoint, using: parameters)
    }

    nonisolated private static func makeStateHandler(
        sender: UDPSender, connection: NWConnection, generation: UInt64
    ) -> @Sendable (NWConnection.State) -> Void {
        { [weak sender] state in
            sender?.handleState(state, generation: generation)
        }
    }

    nonisolated private static func makeReceiveHandler(
        sender: UDPSender, connection: NWConnection, generation: UInt64
    ) -> @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void {
        { [weak sender] data, _, _, error in
            sender?.handleReceive(data, error: error, connection: connection, generation: generation)
        }
    }

    nonisolated private static func makeLivenessHandler(sender: UDPSender) -> @Sendable () -> Void {
        { [weak sender] in
            sender?.checkLiveness()
        }
    }

    // MARK: - Helpers

    /// Text and kind of a resolved address (scope suffix dropped).
    private static func describe(_ host: NWEndpoint.Host) -> (String?, NetworkAddressKind?) {
        switch host {
        case .ipv4(let address):
            let bytes = [UInt8](address.rawValue)
            return (bytes.map(String.init).joined(separator: "."), NetworkAddress.kind(ipv4: bytes))
        case .ipv6(let address):
            let text = "\(address)".split(separator: "%").first.map(String.init)
            return (text, NetworkAddress.kind(ipv6: [UInt8](address.rawValue)))
        case .name(let name, _):
            return (name, NetworkAddress.kind(name))
        @unknown default:
            return (nil, nil)
        }
    }

    /// Monotonic uptime in nanoseconds (never 0 in practice; 0 is "none").
    private static func nowNanos() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    private static func seconds(since start: UInt64) -> TimeInterval {
        seconds(from: start, to: nowNanos())
    }

    private static func seconds(from start: UInt64, to end: UInt64) -> TimeInterval {
        end > start ? Double(end - start) / 1_000_000_000 : 0
    }
}
