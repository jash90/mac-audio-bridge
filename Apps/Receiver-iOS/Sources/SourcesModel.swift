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

    private static let lastIDKey = "lastSourceID"
    private static let lastNameKey = "lastSourceName"
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
        let browser = Self.makeBrowser(model: self)
        self.browser = browser
        browser.start()
        nowPlaying.start(onCommand: Self.makeCommandHandler(model: self))
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

    // MARK: - Browser

    private func browseResults(_ found: [SourceBrowser.Found]) {
        let visible = Set(found.map(\.id))
        for item in found {
            arbiter.sourceSeen(id: item.id, name: item.name)
            endpoints[item.id] = item.endpoint
            if clients[item.id] == nil, retryTasks[item.id] == nil {
                openClient(item.id)
            }
        }
        for (id, source) in arbiter.sources where source.visible && !visible.contains(id) {
            arbiter.sourceVanished(id: id)
            if arbiter.sources[id]?.connected != true {
                endpoints[id] = nil
            }
        }
        apply([])
    }

    private func browserStatusChanged(_ status: SourceBrowser.Status) {
        if browserStatus != status { browserStatus = status }
    }

    // MARK: - Control connections

    private func openClient(_ id: String) {
        guard let endpoint = endpoints[id] else { return }
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
            arbiter.controlConnected(id: id)
            apply([])
        case .message(let message):
            lastMessageAt[id] = elapsed()
            switch message {
            case .status(let status):
                apply(arbiter.statusReceived(id: id, status))
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
            clients[id] = nil
            clientGenerations[id] = nil
            lastMessageAt[id] = nil
            mediaRouter.forget(id: id)
            arbiter.controlDisconnected(id: id)
            apply([])
            scheduleRetry(id)
        }
    }

    /// Reconnects shortly while the Mac is still browsed.
    private func scheduleRetry(_ id: String) {
        retryTasks[id]?.cancel()
        let delay = incompatibleIDs.contains(id) ? Duration.seconds(30) : Self.retryDelay
        retryTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.retryTasks[id] = nil
            if self.arbiter.sources[id]?.visible == true, self.clients[id] == nil {
                self.openClient(id)
            }
        }
    }

    private func hello() -> PhoneHello {
        PhoneHello(phoneID: Self.phoneID, phoneName: helloName, receiverService: helloName)
    }

    private func currentReceiverName() -> String {
        ReceiverAdvertisement.shared.registeredName ?? ReceiverIdentity.serviceName()
    }

    // MARK: - Arbiter plumbing

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
        if name != helloName {
            helloName = name
            for client in clients.values {
                client.send(.hello(hello()))
            }
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

