import BridgeCore
import Foundation
import Network
import UIKit

/// The phone's side of "control from the iPhone + several Macs": browses
/// the Macs, keeps one control connection to each, runs the pure
/// `SourceArbiter`, carries out its effects (control messages) and keeps
/// the receiver's audio gate in step with it. Also remembers the last used
/// Mac, publishes the active Mac (name; its track from protocol v2) to Now
/// Playing and routes playback commands to it (`MediaControlRouter`).
///
/// Internet mode: each Mac's status carries its tailnet addresses, stored
/// per Mac. A `PathFailover` per Mac picks the control endpoint — the
/// Bonjour service while the Mac is browsed, else its tailnet addresses and
/// any address the user added ("Add Mac by address"). When the Mac is
/// browsed again the connection moves back to the LAN. The hello tells the
/// Mac this phone's tailnet addresses and whether its path is expensive.
@MainActor
final class SourcesModel: ObservableObject {
    /// The rows of the Sources list.
    @Published private(set) var sources: [SourceArbiter.Source] = []
    @Published private(set) var activeID: String?
    @Published private(set) var lastUsedID: String?
    @Published private(set) var browserStatus: SourceBrowser.Status = .starting
    /// Sources running another protocol version.
    @Published private(set) var incompatibleIDs: Set<String> = []
    /// What plays on the active Mac (protocol v2), nil when not known.
    @Published private(set) var activeNowPlaying: NowPlayingInfo?
    /// The active Mac takes playback commands (play / pause / next / previous).
    @Published private(set) var activeCanControl = false
    /// Addresses the user added; each one's Mac name once it answered.
    @Published private(set) var manualHosts: [String] = []
    @Published private(set) var manualHostNames: [String: String] = [:]
    /// Addresses that could not be reached at the last attempt.
    @Published private(set) var unreachableHosts: Set<String> = []
    /// Sources whose control connection runs over a remote address.
    @Published private(set) var remoteAddresses: [String: String] = [:]
    /// The phone's network ("Wi-Fi", "Cellular", …) and whether it is metered.
    @Published private(set) var network = NetworkMonitor.Snapshot(network: "Wi-Fi", isExpensive: false)

    private var arbiter: SourceArbiter
    private var mediaRouter = MediaControlRouter()
    private let receiver: UDPReceiver
    private var browser: SourceBrowser?
    private var clients: [String: ControlClient] = [:]
    /// Generation of each current client; events of replaced ones are stale.
    private var clientGenerations: [String: Int] = [:]
    private var nextGeneration = 0
    private var endpoints: [String: NWEndpoint] = [:]
    /// When each connected client last delivered a message.
    private var lastMessageAt: [String: TimeInterval] = [:]
    private var retryTasks: [String: Task<Void, Never>] = [:]
    private var tickLoop: Task<Void, Never>?
    private var helloName = ""
    private let nowPlaying = NowPlayingPublisher()
    private let clockStart = ContinuousClock.now
    private var networkMonitor: NetworkMonitor?
    /// Each Mac's tailnet addresses (from its status), persisted by source ID.
    private var macAddresses: [String: [String]]
    /// Typed host → the source ID that answered on it, persisted.
    private var hostOwners: [String: String]
    /// Known names of Macs reachable by address only (for the list before
    /// the first status of this launch).
    private var knownNames: [String: String]
    private var failovers: [String: PathFailover] = [:]
    /// The path each current client was opened on.
    private var clientPaths: [String: PathFailover.Path] = [:]
    /// Clients that reached `.connected` (a disconnect after that is not a
    /// failed attempt of the path, unless it went silent).
    private var connectedClients: Set<String> = []
    /// One-off clients for typed hosts not yet bound to a Mac.
    private var probes: [String: ControlClient] = [:]
    private var probeGenerations: [String: Int] = [:]
    private var probeRetries: [String: Task<Void, Never>] = [:]
    private var tailnetAddresses: [String] = []
    /// The phone mic's state, reported to every Mac on protocol version 4
    /// (each Mac asks with `micStart` only while it streams to us).
    private var micState: MicState?
    private var micStateSent: [String: MicState] = [:]
    private var macTags: [String: UInt32] = [:]
    private var macVersions: [String: Int] = [:]
    /// A Mac asked for (true) or released (false) the mic; its source tag
    /// picks the UDP flow. Called on the main actor.
    var onMicCommand: ((_ sourceID: String, _ start: Bool, _ sourceTag: UInt32) -> Void)?

    private static let lastIDKey = "lastSourceID"
    private static let lastNameKey = "lastSourceName"
    private static let macAddressesKey = "macTailnetAddresses"
    private static let manualHostsKey = "manualMacHosts"
    private static let hostOwnersKey = "manualMacHostOwners"
    private static let knownNamesKey = "remoteMacNames"
    /// Retry cadence for a Mac reachable only by address (each failed probe
    /// over the Internet costs a TCP connect timeout).
    private static let remoteRetryDelay: Duration = .seconds(10)
    private static let phoneIDKey = "phoneID"
    private static let retryDelay: Duration = .seconds(2)
    /// Statuses arrive at least every 2 s; silence for this long = dead.
    private static let staleAfter: TimeInterval = 6
    /// An adopted stream without a known Mac is let go after this silence.
    private static let unknownSilence: TimeInterval = 3

    private static let phoneID: String = {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: phoneIDKey) { return stored }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: phoneIDKey)
        return fresh
    }()

    init(receiver: UDPReceiver) {
        self.receiver = receiver
        let defaults = UserDefaults.standard
        let lastUsed = defaults.string(forKey: Self.lastIDKey).map { id in
            (id: id, name: defaults.string(forKey: Self.lastNameKey) ?? "Mac")
        }
        arbiter = SourceArbiter(lastUsed: lastUsed)
        macAddresses = (defaults.dictionary(forKey: Self.macAddressesKey) as? [String: [String]]) ?? [:]
        hostOwners = (defaults.dictionary(forKey: Self.hostOwnersKey) as? [String: String]) ?? [:]
        knownNames = (defaults.dictionary(forKey: Self.knownNamesKey) as? [String: String]) ?? [:]
        manualHosts = defaults.stringArray(forKey: Self.manualHostsKey) ?? []
        for host in manualHosts {
            if let id = hostOwners[host], let name = knownNames[id] { manualHostNames[host] = name }
        }
        receiver.onSourceAdopted = Self.makeAdoptionHandler(model: self)
        receiver.setGateMode(arbiter.gateMode)
        publish()
    }

    deinit {
        tickLoop?.cancel()
    }

    /// Starts browsing and the 1 Hz housekeeping (call once, at launch).
    func start() {
        guard browser == nil else { return }
        helloName = currentReceiverName()
        tailnetAddresses = InterfaceAddresses.tailnet()
        let monitor = Self.makeNetworkMonitor(model: self)
        networkMonitor = monitor
        monitor.start()
        let browser = Self.makeBrowser(model: self)
        self.browser = browser
        browser.start()
        nowPlaying.start(onCommand: Self.makeCommandHandler(model: self))
        // Macs known by address: try them right away (Bonjour may never see them).
        for id in remoteIDs() {
            arbiter.sourceKnown(id: id, name: knownNames[id] ?? "Mac")
            openClient(id)
        }
        for host in manualHosts where hostOwners[host] == nil {
            openProbe(host)
        }
        tickLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    var active: SourceArbiter.Source? { activeID.flatMap { arbiter.sources[$0] } }
    var lastUsed: SourceArbiter.Source? { lastUsedID.flatMap { arbiter.sources[$0] } }

    // MARK: - User actions

    func connect(_ id: String) {
        apply(arbiter.userConnect(id: id))
    }

    func disconnect(_ id: String) {
        apply(arbiter.userDisconnect(id: id))
    }

    func reconnectLast() {
        apply(arbiter.reconnectLast())
    }

    func setVolume(_ volume: Float, for id: String) {
        clients[id]?.send(.setVolume(volume))
    }

    func setMuted(_ muted: Bool, for id: String) {
        clients[id]?.send(.setMuted(muted))
    }

    func setQuality(_ quality: StreamQuality, for id: String) {
        clients[id]?.send(.setQuality(quality))
    }

    /// The Internet quality — only to a Mac that speaks it (version 5; an
    /// older Mac would close the session on the unknown envelope version).
    func setInternetQuality(_ quality: InternetQuality, for id: String) {
        guard supportsInternetQuality(id) else { return }
        clients[id]?.send(.setInternetQuality(quality))
    }

    /// Whether the Mac `id` has the Internet quality ladder.
    func supportsInternetQuality(_ id: String) -> Bool {
        (macVersions[id] ?? 0) >= ControlProtocol.internetQualityVersion
    }

    /// A playback command (in-app buttons, lock screen, Control Center,
    /// AirPods): to the active Mac's player when it takes commands,
    /// otherwise play / pause unmute / mute it.
    func media(_ command: MediaCommand) {
        switch mediaRouter.route(command, active: arbiter.active) {
        case .mac(let id, let command):
            clients[id]?.send(.media(command))
        case .setMuted(let id, let muted):
            setMuted(muted, for: id)
        case .none:
            break
        }
    }

    // MARK: - Macs by address

    /// "Add Mac by address": an IP or a host name (e.g. a Tailscale name).
    func addManualHost(_ text: String) {
        let host = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !manualHosts.contains(host) else { return }
        manualHosts.append(host)
        UserDefaults.standard.set(manualHosts, forKey: Self.manualHostsKey)
        if let id = hostOwners[host] {
            refreshFailover(id)
            if clients[id] == nil { openClient(id) }
        } else {
            openProbe(host)
        }
    }

    func removeManualHost(_ host: String) {
        manualHosts.removeAll { $0 == host }
        UserDefaults.standard.set(manualHosts, forKey: Self.manualHostsKey)
        manualHostNames[host] = nil
        unreachableHosts.remove(host)
        probes[host]?.cancel()
        probes[host] = nil
        probeGenerations[host] = nil
        probeRetries[host]?.cancel()
        probeRetries[host] = nil
        if let id = hostOwners.removeValue(forKey: host) {
            UserDefaults.standard.set(hostOwners, forKey: Self.hostOwnersKey)
            refreshFailover(id)
            if clientPaths[id] == .remote(host) {
                clients[id]?.cancel()
            }
        }
    }

    /// Sources with a remote address (stored tailnet IPs or a bound typed host).
    private func remoteIDs() -> [String] {
        let bound = manualHosts.compactMap { hostOwners[$0] }
        return Array(Set(macAddresses.keys).union(bound)).sorted()
    }

    private func remoteCandidates(_ id: String) -> [String] {
        let typed = manualHosts.filter { hostOwners[$0] == id }
        return typed + (macAddresses[id] ?? [])
    }

    private func localAvailable(_ id: String) -> Bool {
        arbiter.sources[id]?.visible == true && endpoints[id] != nil
    }

    /// Brings the source's failover up to date with Bonjour and the known
    /// addresses (created on first use).
    @discardableResult
    private func refreshFailover(_ id: String) -> PathFailover {
        let now = elapsed()
        var failover = failovers[id]
            ?? PathFailover(localAvailable: localAvailable(id), remoteAddresses: remoteCandidates(id), now: now)
        failover.setLocalAvailable(localAvailable(id), now: now)
        failover.setRemoteAddresses(remoteCandidates(id), now: now)
        failover.tick(now: now)
        failovers[id] = failover
        return failover
    }

    private func endpoint(for path: PathFailover.Path?, id: String) -> NWEndpoint? {
        switch path {
        case .local?: return endpoints[id]
        case .remote(let address)?: return ControlClient.endpoint(host: address)
        case nil: return nil
        }
    }

    private func openProbe(_ host: String) {
        guard probes[host] == nil else { return }
        nextGeneration += 1
        let generation = nextGeneration
        let client = ControlClient(
            endpoint: ControlClient.endpoint(host: host),
            onEvent: Self.makeProbeHandler(model: self, host: host, generation: generation))
        probes[host] = client
        probeGenerations[host] = generation
        client.start(hello: hello())
    }

    /// A typed host answered (or not): the first status names its Mac, which
    /// then gets a regular client choosing between LAN and this address.
    private func probeEvent(_ event: ControlClient.Event, host: String, generation: Int) {
        guard probeGenerations[host] == generation else { return }
        switch event {
        case .connected:
            unreachableHosts.remove(host)
        case .message(.status(let status)):
            probes[host]?.cancel()
            probes[host] = nil
            probeGenerations[host] = nil
            bind(host: host, to: status)
        case .message:
            break
        case .incompatible:
            probes[host]?.cancel()
            unreachableHosts.insert(host)
        case .disconnected:
            probes[host] = nil
            probeGenerations[host] = nil
            guard manualHosts.contains(host), hostOwners[host] == nil else { return }
            unreachableHosts.insert(host)
            probeRetries[host]?.cancel()
            probeRetries[host] = Task { [weak self] in
                try? await Task.sleep(for: Self.remoteRetryDelay)
                guard let self, !Task.isCancelled else { return }
                self.probeRetries[host] = nil
                if self.manualHosts.contains(host), self.hostOwners[host] == nil {
                    self.openProbe(host)
                }
            }
        }
    }

    private func bind(host: String, to status: SourceStatus) {
        let id = status.sourceID
        hostOwners[host] = id
        UserDefaults.standard.set(hostOwners, forKey: Self.hostOwnersKey)
        manualHostNames[host] = status.name
        rememberName(status.name, for: id)
        learnAddresses(status, id: id)
        arbiter.sourceKnown(id: id, name: status.name)
        refreshFailover(id)
        if clients[id] == nil, retryTasks[id] == nil {
            openClient(id)
        }
        apply([])
    }

    private func rememberName(_ name: String, for id: String) {
        guard knownNames[id] != name else { return }
        knownNames[id] = name
        UserDefaults.standard.set(knownNames, forKey: Self.knownNamesKey)
    }

    /// Stores the Mac's tailnet addresses from its status.
    private func learnAddresses(_ status: SourceStatus, id: String) {
        let addresses = InterfaceAddresses.ordered((status.tailnetAddresses ?? []).filter(NetworkAddress.isTailnet))
        guard !addresses.isEmpty, macAddresses[id] != addresses else { return }
        macAddresses[id] = addresses
        UserDefaults.standard.set(macAddresses, forKey: Self.macAddressesKey)
        rememberName(status.name, for: id)
        refreshFailover(id)
    }

    // MARK: - Browser

    private func browseResults(_ found: [SourceBrowser.Found]) {
        let visible = Set(found.map(\.id))
        for item in found {
            arbiter.sourceSeen(id: item.id, name: item.name)
            endpoints[item.id] = item.endpoint
            let failover = refreshFailover(item.id)
            if clients[item.id] == nil {
                retryTasks[item.id]?.cancel()
                retryTasks[item.id] = nil
                openClient(item.id)
            } else if failover.current == .local, clientPaths[item.id] != .local {
                // Back on the Mac's LAN: move the control connection there.
                clients[item.id]?.cancel()
            }
        }
        for (id, source) in arbiter.sources where source.visible && !visible.contains(id) {
            arbiter.sourceVanished(id: id)
            if arbiter.sources[id]?.connected != true {
                endpoints[id] = nil
            }
            refreshFailover(id)
        }
        apply([])
    }

    private func browserStatusChanged(_ status: SourceBrowser.Status) {
        if browserStatus != status { browserStatus = status }
    }

    // MARK: - Control connections

    private func openClient(_ id: String) {
        var path = refreshFailover(id).current
        if path == .local, !localAvailable(id), !remoteCandidates(id).isEmpty {
            // Not browsed any more (left the Mac's Wi-Fi): try the tailnet.
            failovers[id]?.pathFailed(now: elapsed())
            path = failovers[id]?.current
        }
        guard let endpoint = endpoint(for: path, id: id), let path else { return }
        clientPaths[id] = path
        nextGeneration += 1
        let generation = nextGeneration
        let client = ControlClient(
            endpoint: endpoint,
            onEvent: Self.makeClientHandler(model: self, id: id, generation: generation))
        clients[id] = client
        clientGenerations[id] = generation
        client.start(hello: hello())
    }

    private func clientEvent(_ event: ControlClient.Event, id: String, generation: Int) {
        // Events of a client that was replaced are stale.
        guard clientGenerations[id] == generation else { return }
        switch event {
        case .connected:
            lastMessageAt[id] = elapsed()
            incompatibleIDs.remove(id)
            connectedClients.insert(id)
            failovers[id]?.pathAlive(now: elapsed())
            publishRemoteAddress(id)
            arbiter.controlConnected(id: id)
            apply([])
        case .message(let message):
            lastMessageAt[id] = elapsed()
            switch message {
            case .status(let status):
                if status.sourceID == id {
                    rememberNameIfRemote(status.name, id: id)
                    learnAddresses(status, id: id)
                }
                macTags[id] = status.sourceTag
                macVersions[id] = status.protocolVersion ?? 1
                apply(arbiter.statusReceived(id: id, status))
                sendMicStateIfNeeded(id)
            case .micStart:
                onMicCommand?(id, true, macTags[id] ?? 0)
            case .micStop:
                onMicCommand?(id, false, macTags[id] ?? 0)
            case .claim:
                apply(arbiter.claimReceived(id: id))
            case .nowPlaying(let info):
                mediaRouter.nowPlayingReceived(id: id, info)
                publish()
            default:
                break  // phone → Mac messages are not expected here
            }
        case .incompatible:
            incompatibleIDs.insert(id)
        case .disconnected:
            let failedPath = clientPaths[id]
            let wasConnected = connectedClients.remove(id) != nil
            let wentStale = lastMessageAt[id].map { elapsed() - $0 > Self.staleAfter } ?? false
            clients[id] = nil
            clientGenerations[id] = nil
            clientPaths[id] = nil
            lastMessageAt[id] = nil
            micStateSent[id] = nil
            onMicCommand?(id, false, macTags[id] ?? 0)
            mediaRouter.forget(id: id)
            // A path that never connected, or went silent, failed; a clean
            // close (Mac quit, LAN switch-back) did not.
            let movingToLocal = failedPath != .local && refreshFailover(id).current == .local
            if (!wasConnected || wentStale), !movingToLocal {
                failovers[id]?.pathFailed(now: elapsed())
            }
            publishRemoteAddress(id)
            arbiter.controlDisconnected(id: id)
            apply([])
            scheduleRetry(id, after: failedPath)
        }
    }

    /// Reconnects while the Mac is browsed or has a remote address: soon
    /// when the path changed, every 10 s on the same remote path.
    private func scheduleRetry(_ id: String, after failedPath: PathFailover.Path?) {
        retryTasks[id]?.cancel()
        let next = refreshFailover(id).current
        let delay: Duration
        if incompatibleIDs.contains(id) {
            delay = .seconds(30)
        } else if next != failedPath, next != nil {
            delay = .milliseconds(300)
        } else if next?.isRemote == true {
            delay = Self.remoteRetryDelay
        } else {
            delay = Self.retryDelay
        }
        retryTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.retryTasks[id] = nil
            let reachable = self.arbiter.sources[id]?.visible == true || !self.remoteCandidates(id).isEmpty
            if reachable, self.clients[id] == nil {
                self.openClient(id)
            }
        }
    }

    private func rememberNameIfRemote(_ name: String, id: String) {
        if !remoteCandidates(id).isEmpty { rememberName(name, for: id) }
        for host in manualHosts where hostOwners[host] == id && manualHostNames[host] != name {
            manualHostNames[host] = name
        }
    }

    private func publishRemoteAddress(_ id: String) {
        let address = connectedClients.contains(id) ? clientPaths[id]?.remoteAddress : nil
        if remoteAddresses[id] != address { remoteAddresses[id] = address }
    }

    private func hello() -> PhoneHello {
        PhoneHello(
            phoneID: Self.phoneID, phoneName: helloName, receiverService: helloName,
            tailnetAddresses: tailnetAddresses.isEmpty ? nil : tailnetAddresses,
            network: network.network, expensivePath: network.isExpensive)
    }

    private func resendHello() {
        let message = ControlMessage.hello(hello())
        for client in clients.values {
            client.send(message)
        }
    }

    private func networkChanged(_ snapshot: NetworkMonitor.Snapshot) {
        guard snapshot != network else { return }
        network = snapshot
        receiver.setExpensivePath(snapshot.isExpensive)
        resendHello()
    }

    private func currentReceiverName() -> String {
        ReceiverAdvertisement.shared.registeredName ?? ReceiverIdentity.serviceName()
    }

    // MARK: - Arbiter plumbing

    // MARK: - Microphone

    /// The phone mic changed: tell every Mac that understands it.
    func setMicState(_ state: MicState) {
        guard state != micState else { return }
        micState = state
        for id in clients.keys {
            sendMicStateIfNeeded(id)
        }
    }

    /// Whether the active Mac speaks the mic protocol (version 4).
    var activeSupportsMic: Bool {
        guard let id = activeID else { return false }
        return (macVersions[id] ?? 0) >= ControlProtocol.micVersion
    }

    private func sendMicStateIfNeeded(_ id: String) {
        guard let micState, (macVersions[id] ?? 0) >= ControlProtocol.micVersion,
            micStateSent[id] != micState, let client = clients[id]
        else { return }
        client.send(.micState(micState))
        micStateSent[id] = micState
    }

    private func apply(_ effects: [SourceArbiter.Effect]) {
        for effect in effects {
            switch effect {
            case .send(let id, let message):
                clients[id]?.send(message)
            }
        }
        receiver.setGateMode(arbiter.gateMode)
        persistLastUsed()
        publish()
    }

    private func sourceAdopted(tag: UInt32) {
        arbiter.audioAdopted(tag: tag)
        apply([])
    }

    private func persistLastUsed() {
        guard let last = arbiter.lastUsed else { return }
        let defaults = UserDefaults.standard
        if defaults.string(forKey: Self.lastIDKey) != last.id {
            defaults.set(last.id, forKey: Self.lastIDKey)
        }
        if defaults.string(forKey: Self.lastNameKey) != last.name {
            defaults.set(last.name, forKey: Self.lastNameKey)
        }
    }

    private func publish() {
        let listed = arbiter.listed
        if sources != listed { sources = listed }
        if activeID != arbiter.activeID { activeID = arbiter.activeID }
        if lastUsedID != arbiter.lastUsedID { lastUsedID = arbiter.lastUsedID }
        let active = arbiter.active
        let track = active.flatMap { mediaRouter.nowPlaying[$0.id] }
        let canControl = mediaRouter.canControl(active)
        if activeNowPlaying != track { activeNowPlaying = track }
        if activeCanControl != canControl { activeCanControl = canControl }
        nowPlaying.update(
            NowPlayingPublisher.Content(
                sourceName: active?.name, muted: active?.status?.muted ?? false,
                track: track, canControl: canControl))
    }

    /// 1 Hz: dead connections, an unknown stream gone silent, a renamed
    /// receiver (hello again).
    private func tick() {
        let now = elapsed()
        for (id, client) in clients {
            if let last = lastMessageAt[id], now - last > Self.staleAfter {
                client.cancel()
            }
        }
        if let unknown = arbiter.adoptedUnknownTag,
            (receiver.secondsSinceLastAudio() ?? .infinity) > Self.unknownSilence
        {
            arbiter.audioStopped(tag: unknown)
            apply([])
        }
        let name = currentReceiverName()
        let addresses = InterfaceAddresses.tailnet()
        if name != helloName || addresses != tailnetAddresses {
            helloName = name
            tailnetAddresses = addresses
            resendHello()
        }
    }

    private func elapsed() -> TimeInterval {
        let duration = ContinuousClock.now - clockStart
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
    }

    // MARK: - Nonisolated factories (framework queues → main actor, FIFO)

    nonisolated private static func makeBrowser(model: SourcesModel) -> SourceBrowser {
        SourceBrowser(
            onResults: { [weak model] found in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { model?.browseResults(found) }
                }
            },
            onStatus: { [weak model] status in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { model?.browserStatusChanged(status) }
                }
            })
    }

    nonisolated private static func makeNetworkMonitor(model: SourcesModel) -> NetworkMonitor {
        NetworkMonitor { [weak model] snapshot in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { model?.networkChanged(snapshot) }
            }
        }
    }

    nonisolated private static func makeProbeHandler(
        model: SourcesModel, host: String, generation: Int
    ) -> @Sendable (ControlClient.Event) -> Void {
        { [weak model] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { model?.probeEvent(event, host: host, generation: generation) }
            }
        }
    }

    nonisolated private static func makeClientHandler(
        model: SourcesModel, id: String, generation: Int
    ) -> @Sendable (ControlClient.Event) -> Void {
        { [weak model] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { model?.clientEvent(event, id: id, generation: generation) }
            }
        }
    }

    nonisolated private static func makeAdoptionHandler(model: SourcesModel) -> @Sendable (UInt32) -> Void {
        { [weak model] tag in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { model?.sourceAdopted(tag: tag) }
            }
        }
    }

    nonisolated private static func makeCommandHandler(
        model: SourcesModel
    ) -> @Sendable (MediaCommand) -> Void {
        { [weak model] command in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { model?.media(command) }
            }
        }
    }
}

