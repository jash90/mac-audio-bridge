import BridgeCore
import Foundation
import Network
import dnssd
import os
import Synchronization

/// Toggle (M2.6): send 16-byte keepalive datagrams back to the sender every
/// 20 ms while audio packets are arriving. iPhone Wi-Fi power save delivers
/// UDP in bursts (50-150 ms gaps and more), which the jitter buffer sees as
/// late/lost packets; a steady 20 ms reply stream keeps the radio in active
/// state. Set to false to measure the unmitigated burst behaviour — note
/// the sender also uses these keepalives as its liveness signal (M3) and
/// recreates its connection every 3 s without them.
private let receiverKeepaliveEnabled = true

/// Listens for UDP datagrams on port 49000 (any free port if that one is
/// taken — Bonjour carries the real port) and advertises the listener as the
/// Bonjour service `_macaudiobridge._udp` named after the device ("iPhone
/// 7KQ2", see `ReceiverIdentity`) with TXT `v=2`, so the Mac finds it by name
/// and re-resolves it when the Wi-Fi address changes. A failed listener is
/// recreated (same name, same port), so a sender keeps working across it.
///
/// Each datagram is one `AudioDatagram` (5 ms frames — interleaved
/// little-endian Int16 PCM, or one Opus packet per entry: a primary and/or
/// redundant copies); every frame is inserted into the jitter buffer stamped
/// with a monotonic arrival time, undecoded (the playout reader decodes Opus
/// in playout order). Datagrams that fail `AudioDatagram.decode`, or that
/// carry an unexpected payload size for their codec, are dropped and counted
/// as malformed. Start/stop run on the main actor, callbacks are confined to one
/// serial queue.
///
/// Exactly one source plays: every datagram carries its Mac's source tag
/// and passes the `SourceGate` (mode set by the main actor from the
/// `SourceArbiter`). Datagrams of other sources are dropped and counted;
/// the first datagram of a newly admitted source has its primary marked as a
/// discontinuity, so the jitter buffer resets and the reader crossfades.
final class UDPReceiver: @unchecked Sendable {
    static let port: UInt16 = ReceiverService.preferredPort
    private static let listenerRestartDelay: TimeInterval = 2
    /// Sender flows that delivered nothing for this long are closed (a
    /// sender that reconnected arrives as a new flow from a new port).
    private static let idlePeerTimeout: TimeInterval = 30
    /// Expected payload of one PCM16 stereo frame: 240 frames × 2 channels × 2 bytes.
    private static let expectedPayloadBytes = AudioFormat.pcm16FrameBytes
    /// Accepted Opus packet sizes: one byte up to what a jitter-buffer slot holds.
    private static let opusPayloadBytes = 1...min(OpusSettings.maxPacketBytes, JitterBuffer.maxFramePayloadBytes)
    /// How recently the last packet must have arrived for keepalives to
    /// keep flowing ("while playing"). The cadence follows the stream
    /// profile: 20 ms on the LAN (radio wake-ups), 200 ms over the Internet
    /// (liveness only — every byte counts on cellular).
    private static let keepaliveActivityWindow: TimeInterval = 1.0

    private let jitterBuffer: JitterBuffer
    /// User-interactive: arrival timestamps are taken here, and a throttled
    /// queue would add its own scheduling jitter to every delay sample.
    private let queue = DispatchQueue(label: "dev.jash90.MacAudioBridge.udp-receiver", qos: .userInteractive)
    private let logger = Logger(subsystem: "dev.jash90.MacAudioBridge", category: "udp-receiver")
    private let malformedDatagrams = Atomic<Int>(0)
    /// Datagrams dropped because they came from a non-active source.
    private let foreignDatagrams = Atomic<Int>(0)
    /// Source filter; locked briefly on the receive queue and by `setGateMode`.
    private let gate = Mutex(SourceGate())
    /// Called on the receive queue when the gate adopted a stream by itself
    /// (nothing was active). Set before `start`, never swapped afterwards.
    var onSourceAdopted: (@Sendable (UInt32) -> Void)?
    /// Arrival-clock epoch. `ContinuousClock` never goes backwards, which the
    /// jitter buffer's interarrival estimates rely on.
    private let clockStart = ContinuousClock.now
    /// Latency mode the WAN / LAN jitter configs are built for (main actor writes).
    private let latencyMode = Mutex(JitterLatencyMode.balanced)
    /// The stream profile the sender marks its datagrams with (raw value).
    private let profileValue = Atomic<UInt8>(StreamProfile.lan.rawValue)
    /// Keepalive flags (expensive path), set from the network monitor.
    private let keepaliveFlags = Atomic<UInt8>(0)
    /// Accepted audio datagrams and their UDP payload bytes, since launch.
    private let acceptedDatagrams = Atomic<Int>(0)
    private let acceptedBytes = Atomic<Int>(0)
    /// Address class of the sender whose datagrams were accepted last.
    private let senderKind = Mutex<NetworkAddressKind?>(nil)

    /// An accepted sender connection, whether its path is ready (keepalive
    /// sends are dropped until it is), and when it last delivered a packet
    /// (keepalives go only to senders that are actually streaming).
    private struct Peer {
        let connection: NWConnection
        let acceptedAt: TimeInterval
        let kind: NetworkAddressKind?
        var isReady = false
        var lastPacketArrival: TimeInterval?
    }

    /// Posts advertisement state to the main actor in FIFO order.
    private let postAdvertisement = UDPReceiver.makeAdvertisementPoster()

    // State confined to `queue`:
    private var listener: NWListener?
    /// True between start() and stop(); a failed listener is recreated only
    /// while running.
    private var isRunning = false
    /// Bumped per listener; callbacks of replaced listeners are ignored.
    private var listenerGeneration: UInt64 = 0
    private var serviceName = ""
    private var peers: [Peer] = []
    private var keepaliveTimer: DispatchSourceTimer?
    /// Arrival time of the last accepted packet, and the largest gap between
    /// consecutive packets since the last `takeMaxInterArrivalGapSeconds`.
    private var lastPacketArrival: TimeInterval?
    private var maxInterArrivalGap: TimeInterval = 0
    /// Follows the profile mark of the newest datagram only (stragglers of
    /// the previous profile do not flip it back).
    private var profileFollower = ProfileFollower()
    private var keepaliveInterval = StreamProfile.lan.keepaliveInterval

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

    /// Datagrams dropped since launch because another source is active.
    var foreignCount: Int {
        foreignDatagrams.load(ordering: .relaxed)
    }

    /// The stream profile of the current stream (from the datagram marks).
    var profile: StreamProfile {
        StreamProfile(rawValue: profileValue.load(ordering: .relaxed)) ?? .lan
    }

    /// Accepted audio datagrams / UDP payload bytes since launch.
    var datagramCount: Int { acceptedDatagrams.load(ordering: .relaxed) }
    var byteCount: Int { acceptedBytes.load(ordering: .relaxed) }

    /// Address class of the sender currently streaming (nil before any).
    var currentSenderKind: NetworkAddressKind? { senderKind.withLock { $0 } }

    /// Latency mode for profile retunes; the caller applies it to the buffer.
    func setLatencyMode(_ mode: JitterLatencyMode) {
        latencyMode.withLock { $0 = mode }
    }

    /// Tells the sender (in every keepalive) that this phone is on an
    /// expensive path (cellular / hotspot), which selects the WAN profile.
    func setExpensivePath(_ expensive: Bool) {
        let flags: ReceiverKeepalive.Flags = expensive ? [.expensivePath] : []
        keepaliveFlags.store(flags.rawValue, ordering: .relaxed)
    }

    /// Which source tags are let through (from the arbiter, main actor).
    func setGateMode(_ mode: SourceGateMode) {
        gate.withLock { $0.setMode(mode) }
    }

    /// Seconds since the last accepted audio datagram (nil = none yet).
    func secondsSinceLastAudio() -> TimeInterval? {
        queue.sync {
            lastPacketArrival.map { elapsedSeconds() - $0 }
        }
    }

    func start() throws {
        let alreadyRunning: Bool = queue.sync { isRunning }
        guard !alreadyRunning else { return }
        let name = ReceiverIdentity.serviceName()
        let newListener = try Self.makeListener(port: Self.port, serviceName: name)
        queue.async { [weak self] in
            guard let self, !self.isRunning else {
                newListener.cancel()
                return
            }
            self.isRunning = true
            self.serviceName = name
            self.install(newListener)
            self.startKeepaliveTimer()
            self.logger.info(
                "Listening on UDP port \(Self.port), advertising \(name, privacy: .public) (serviceClass interactiveVoice)")
        }
    }

    func stop() {
        queue.sync {
            isRunning = false
            listenerGeneration &+= 1
            keepaliveTimer?.cancel()
            keepaliveTimer = nil
            listener?.cancel()
            listener = nil
            peers.forEach { $0.connection.cancel() }
            peers.removeAll()
        }
        postAdvertisement(.status(.starting))
        postAdvertisement(.registeredName(nil))
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

    // MARK: - Listener lifecycle (queue-confined)

    private func install(_ newListener: NWListener) {
        listenerGeneration &+= 1
        let generation = listenerGeneration
        newListener.newConnectionHandler = Self.makeConnectionHandler(receiver: self)
        newListener.stateUpdateHandler = Self.makeListenerStateHandler(
            receiver: self, generation: generation)
        newListener.serviceRegistrationUpdateHandler = Self.makeRegistrationHandler(
            receiver: self, generation: generation)
        listener = newListener
        postAdvertisement(.status(.starting))
        newListener.start(queue: queue)
    }

    private func handleListenerState(_ state: NWListener.State, generation: UInt64) {
        guard generation == listenerGeneration, let current = listener else { return }
        switch state {
        case .ready:
            postAdvertisement(.port(current.port?.rawValue))
            // Provisional until the registration callback reports the name
            // actually registered (Bonjour renames on a conflict).
            postAdvertisement(.registeredName(serviceName))
            postAdvertisement(.status(.advertising))
        case .waiting(let error):
            logger.info("Listener waiting: \(error.localizedDescription, privacy: .public)")
            postAdvertisement(.status(
                Self.isPolicyDenied(error) ? .localNetworkDenied : .failed(error.localizedDescription)))
        case .failed(let error):
            logger.error("Listener failed: \(error.localizedDescription, privacy: .public)")
            postAdvertisement(.status(
                Self.isPolicyDenied(error) ? .localNetworkDenied : .failed(error.localizedDescription)))
            current.cancel()
            listener = nil
            // Port 49000 taken: take any port right away (discovered senders
            // follow the advertised port). Anything else: retry the
            // preferred port shortly.
            let portInUse: Bool = {
                if case .posix(let code) = error { return code == .EADDRINUSE }
                return false
            }()
            let usedPreferredPort = current.port?.rawValue == Self.port || current.port == nil
            scheduleListenerRestart(
                port: portInUse && usedPreferredPort ? nil : Self.port,
                after: portInUse ? 0 : Self.listenerRestartDelay)
        default:
            break
        }
    }

    private func handleRegistration(_ change: NWListener.ServiceRegistrationChange, generation: UInt64) {
        guard generation == listenerGeneration else { return }
        switch change {
        case .add(let endpoint):
            if case .service(let name, _, _, _) = endpoint {
                postAdvertisement(.registeredName(name))
            }
            postAdvertisement(.status(.advertising))
        case .remove:
            postAdvertisement(.registeredName(nil))
        @unknown default:
            break
        }
    }

    /// Recreates the listener (same service name) unless stopped meanwhile.
    /// `port` nil = any free port.
    private func scheduleListenerRestart(port: UInt16?, after delay: TimeInterval) {
        let generation = listenerGeneration
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isRunning, self.listener == nil,
                generation == self.listenerGeneration
            else { return }
            do {
                let newListener = try Self.makeListener(port: port, serviceName: self.serviceName)
                self.install(newListener)
                self.logger.info("Listener recreated on port \(port.map(String.init) ?? "any", privacy: .public)")
            } catch {
                self.logger.error(
                    "Listener restart failed: \(error.localizedDescription, privacy: .public)")
                self.scheduleListenerRestart(port: Self.port, after: Self.listenerRestartDelay)
            }
        }
    }

    // MARK: - Sender connections (queue-confined)

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = Self.makePeerStateHandler(receiver: self, connection: connection)
        connection.start(queue: queue)
        peers.append(Peer(
            connection: connection, acceptedAt: elapsedSeconds(), kind: Self.addressKind(connection.endpoint)))
        receiveLoop(on: connection)
    }

    private func handlePeerState(_ state: NWConnection.State, connection: NWConnection) {
        switch state {
        case .ready:
            updatePeer(for: connection) { $0.isReady = true }
        case .failed(let error):
            logger.error("Connection failed: \(error.localizedDescription, privacy: .public)")
            drop(connection)
        case .cancelled:
            drop(connection)
        default:
            break
        }
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
        connection.receiveMessage(
            completion: Self.makeReceiveHandler(receiver: self, connection: connection))
    }

    private func handleReceive(
        _ data: Data?, isComplete: Bool, error: NWError?, connection: NWConnection
    ) {
        if let data, isComplete, ingest(data) {
            let arrival = lastPacketArrival
            var kind: NetworkAddressKind?
            updatePeer(for: connection) {
                $0.lastPacketArrival = arrival
                kind = $0.kind
            }
            if kind != nil, kind != currentSenderKind {
                senderKind.withLock { $0 = kind }
            }
            acceptedDatagrams.wrappingAdd(1, ordering: .relaxed)
            acceptedBytes.wrappingAdd(data.count, ordering: .relaxed)
        }
        if let error {
            logger.error("Receive failed: \(error.localizedDescription, privacy: .public)")
            drop(connection)
            return
        }
        receiveLoop(on: connection)
    }

    /// Decodes one datagram and buffers every frame it carries (the primary
    /// and any redundant copies); true when it was a valid audio datagram.
    /// The inter-arrival gap tracks datagrams carrying a primary only.
    @discardableResult
    private func ingest(_ data: Data) -> Bool {
        let datagram: AudioDatagram
        do {
            datagram = try AudioDatagram.decode(data)
        } catch {
            countMalformed()
            return false
        }
        let validSizes: Bool
        switch datagram.codec {
        case .pcm16:
            validSizes = datagram.entries.allSatisfy { $0.payload.count == Self.expectedPayloadBytes }
        case .opus:
            validSizes = datagram.entries.allSatisfy { Self.opusPayloadBytes.contains($0.payload.count) }
        }
        guard validSizes else {
            countMalformed()
            return false
        }
        let admission = gate.withLock { $0.admit(tag: datagram.source, hasPrimary: datagram.hasPrimary) }
        guard case .accept(let newStream, let adopted) = admission else {
            foreignDatagrams.wrappingAdd(1, ordering: .relaxed)
            return false
        }
        if adopted {
            onSourceAdopted?(datagram.source)
        }
        let arrival = elapsedSeconds()
        var packets = datagram.packets()
        if newStream {
            // Another Mac's stream (or the first one): a fresh sequence
            // space — reset the buffer (once: on the oldest primary of the
            // group), crossfade at the reader.
            if let index = packets.firstIndex(where: { !$0.isRedundant }) {
                packets[index].flags.insert(.discontinuity)
            }
            profileFollower.reset()
        }
        if let profile = profileFollower.observe(datagram.profile, sequence: datagram.sequence) {
            // LAN ↔ WAN: retune in place (no reset, no audible switch),
            // before this datagram's frames go in.
            let mode = latencyMode.withLock { $0 }
            jitterBuffer.retune(profile.jitterConfig(mode))
            profileValue.store(profile.rawValue, ordering: .relaxed)
            setKeepaliveInterval(profile.keepaliveInterval)
            logger.info("Stream profile: \(profile.displayName, privacy: .public)")
        }
        if packets.contains(where: { !$0.isRedundant }) {
            if let last = lastPacketArrival {
                maxInterArrivalGap = max(maxInterArrivalGap, arrival - last)
            }
            lastPacketArrival = arrival
        }
        for packet in packets {
            jitterBuffer.insert(packet, arrivalTime: arrival)
        }
        return true
    }

    private func countMalformed() {
        malformedDatagrams.wrappingAdd(1, ordering: .relaxed)
    }

    // MARK: - Radio keepalive

    private func startKeepaliveTimer() {
        guard receiverKeepaliveEnabled, keepaliveTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + keepaliveInterval,
            repeating: keepaliveInterval
        )
        timer.setEventHandler(handler: Self.makeKeepaliveHandler(receiver: self))
        timer.resume()
        keepaliveTimer = timer
    }

    private func setKeepaliveInterval(_ interval: TimeInterval) {
        guard interval != keepaliveInterval else { return }
        keepaliveInterval = interval
        keepaliveTimer?.schedule(deadline: .now() + interval, repeating: interval)
    }

    /// Sends one keepalive per ready peer that delivered packets within the
    /// last second (the sender also uses them as its liveness signal). Sends
    /// on a not-ready connection would just error per datagram, so they are
    /// skipped instead. Also closes sender flows idle for 30 s.
    private func sendKeepaliveIfStreaming() {
        let now = elapsedSeconds()
        pruneIdlePeers(now: now)
        guard let lastArrival = lastPacketArrival,
            now - lastArrival < Self.keepaliveActivityWindow
        else { return }
        let payload = ReceiverKeepalive.encode(
            ReceiverKeepalive.Flags(rawValue: keepaliveFlags.load(ordering: .relaxed)))
        for peer in peers where peer.isReady {
            guard let peerArrival = peer.lastPacketArrival,
                now - peerArrival < Self.keepaliveActivityWindow
            else { continue }
            peer.connection.send(
                content: payload,
                completion: .contentProcessed { _ in
                    // Errors surface through the state handler; per-datagram
                    // logging would spam.
                }
            )
        }
    }

    private func pruneIdlePeers(now: TimeInterval) {
        let idle = peers.filter {
            now - ($0.lastPacketArrival ?? $0.acceptedAt) > Self.idlePeerTimeout
        }
        for peer in idle {
            drop(peer.connection)
        }
    }

    // MARK: - Nonisolated factories (capture only Sendable state)

    nonisolated private static func makeListener(port: UInt16?, serviceName: String) throws -> NWListener {
        let parameters = NWParameters.udp
        // WMM voice access class: the AP and iOS power-save scheduling favor
        // the voice queue, which tightens the delay distribution.
        parameters.serviceClass = .interactiveVoice
        let listener: NWListener
        if let port {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        } else {
            listener = try NWListener(using: parameters)
        }
        listener.service = NWListener.Service(
            name: serviceName,
            type: ReceiverService.type,
            domain: nil,
            txtRecord: NWTXTRecord([ReceiverService.versionKey: ReceiverService.protocolVersion]))
        return listener
    }

    nonisolated private static func makeAdvertisementPoster()
        -> @Sendable (ReceiverAdvertisement.Update) -> Void
    {
        { update in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { ReceiverAdvertisement.shared.apply(update) }
            }
        }
    }

    nonisolated private static func makeConnectionHandler(
        receiver: UDPReceiver
    ) -> @Sendable (NWConnection) -> Void {
        { [weak receiver] connection in
            receiver?.accept(connection)
        }
    }

    nonisolated private static func makeListenerStateHandler(
        receiver: UDPReceiver, generation: UInt64
    ) -> @Sendable (NWListener.State) -> Void {
        { [weak receiver] state in
            receiver?.handleListenerState(state, generation: generation)
        }
    }

    nonisolated private static func makeRegistrationHandler(
        receiver: UDPReceiver, generation: UInt64
    ) -> @Sendable (NWListener.ServiceRegistrationChange) -> Void {
        { [weak receiver] change in
            receiver?.handleRegistration(change, generation: generation)
        }
    }

    nonisolated private static func makePeerStateHandler(
        receiver: UDPReceiver, connection: NWConnection
    ) -> @Sendable (NWConnection.State) -> Void {
        { [weak receiver] state in
            receiver?.handlePeerState(state, connection: connection)
        }
    }

    nonisolated private static func makeReceiveHandler(
        receiver: UDPReceiver, connection: NWConnection
    ) -> @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void {
        { [weak receiver] data, _, isComplete, error in
            receiver?.handleReceive(data, isComplete: isComplete, error: error, connection: connection)
        }
    }

    nonisolated private static func makeKeepaliveHandler(receiver: UDPReceiver) -> @Sendable () -> Void {
        { [weak receiver] in
            receiver?.sendKeepaliveIfStreaming()
        }
    }

    /// Address class of a sender flow's remote endpoint.
    nonisolated private static func addressKind(_ endpoint: NWEndpoint) -> NetworkAddressKind? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let address):
            return NetworkAddress.kind(ipv4: [UInt8](address.rawValue))
        case .ipv6(let address):
            return NetworkAddress.kind(ipv6: [UInt8](address.rawValue))
        case .name(let name, _):
            return NetworkAddress.kind(name)
        @unknown default:
            return nil
        }
    }

    private static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error {
            return code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied)
        }
        return false
    }

    /// Seconds elapsed on the monotonic arrival clock.
    private func elapsedSeconds() -> TimeInterval {
        let elapsed = ContinuousClock.now - clockStart
        return Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) * 1e-18
    }
}
