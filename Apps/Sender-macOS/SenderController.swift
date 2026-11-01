import BridgeCore
import CoreAudio
import Foundation
import Synchronization

// File-scope constant so @Sendable background closures can reference it without
// touching main-actor-isolated static state.
private let captureDeniedMessage =
    "No audio captured — allow Mac Audio Bridge in System Settings → Privacy & Security → Screen & System Audio Recording"

/// Mailbox for warnings raised on background queues. `refreshStats` drains it on
/// the main actor (~1 Hz), so background callbacks never touch UI state directly.
private final class WarningMailbox: @unchecked Sendable {
    private let message = Mutex<String?>(nil)

    func post(_ value: String) {
        message.withLock { current in
            current = value
        }
    }

    func take() -> String? {
        message.withLock { current in
            let value = current
            current = nil
            return value
        }
    }
}

/// Packet counter shared between the converter queue (writer) and the UI (reader).
final class FrameStats: @unchecked Sendable {
    private let packets = Atomic<Int>(0)
    private let lastSequence = Atomic<UInt32>(0)

    func record(sequence: UInt32) {
        packets.wrappingAdd(1, ordering: .relaxed)
        lastSequence.store(sequence, ordering: .relaxed)
    }

    func reset() {
        packets.store(0, ordering: .relaxed)
        lastSequence.store(0, ordering: .relaxed)
    }

    /// Returns the packet count since the last call and resets it to zero.
    func takePerSecondCount() -> Int {
        packets.exchange(0, ordering: .acquiringAndReleasing)
    }

    /// Sequence number of the most recently emitted packet.
    var sequence: UInt32 {
        lastSequence.load(ordering: .relaxed)
    }
}

/// The stream profile (LAN / WAN) the packer marks and lays out datagrams
/// with — set on the main actor, read per frame on the converter queue.
final class ProfileGate: @unchecked Sendable {
    private let raw = Atomic<UInt8>(StreamProfile.lan.rawValue)

    var value: StreamProfile {
        get { StreamProfile(rawValue: raw.load(ordering: .relaxed)) ?? .lan }
        set { raw.store(newValue.rawValue, ordering: .relaxed) }
    }
}

/// Holds the `RedundancyPacker` for the converter's frame callback. Only
/// touched on the converter queue (the callback's only caller); a fresh box
/// per streaming run.
final class RedundancyPackerBox: @unchecked Sendable {
    private var packer = RedundancyPacker()
    private let profileGate: ProfileGate

    /// `sourceTag` goes into every datagram, so the phone can tell this
    /// Mac's stream from another Mac's.
    init(sourceTag: UInt32, profileGate: ProfileGate) {
        packer.sourceTag = sourceTag
        self.profileGate = profileGate
    }

    /// A profile switch first sends the frames held for an incomplete WAN
    /// group, so the sequence stays continuous across the switch.
    func pack(_ frame: AudioPacket) -> [Data] {
        let flushed = packer.setProfile(profileGate.value)
        let packed = packer.pack(frame)
        return flushed.isEmpty ? packed : flushed + packed
    }
}

/// One second of sender telemetry, appended as a JSON line to
/// `~/Library/Logs/MacAudioBridge/sender-stats.jsonl`.
private struct SenderStatsLine: Codable, Sendable {
    /// "waiting" (device not selected / no address) or "streaming".
    var mode: String
    /// Whether "iPhone (Mac Audio Bridge)" is the default output device.
    var defaultOutputIsOurs: Bool
    /// Virtual-device volume actually applied to the stream (0 when muted).
    var volume: Double
    var timestamp: Double
    /// Ring write() calls (≈ tap IOProc callbacks) in the last second.
    var ioCallbacks: Int
    /// Samples the tap delivered into the ring (stored + dropped).
    var samplesCaptured: Int
    /// Samples the ring dropped to overflow in the last second.
    var ringDroppedSamples: Int
    /// Samples currently sitting in the ring.
    var ringFillSamples: Int
    var packetsSent: Int
    var bytesSent: Int
    /// Largest gap between drain ticks in the last second, ms — the App Nap
    /// / timer-throttling signature.
    var maxTickMs: Double
    var appNapActivityHeld: Bool
    /// Receiver streamed to: Bonjour service name or manual host ("" = none).
    var receiver: String
    /// Age of the last receiver keepalive on the current connection, ms
    /// (-1 = none yet / no connection).
    var keepaliveAgeMs: Double
    /// NWConnection state: none / setup / preparing / waiting / ready /
    /// failed / cancelled.
    var connectionState: String
    /// Keepalive liveness: connecting / alive / idle / noResponse ("" = no
    /// connection).
    var link: String
    /// Connections recreated by the keepalive timeout since launch.
    var reconnects: Int
    /// Codec of the frames sent in the last second: "opus" / "pcm16" ("" =
    /// none sent).
    var codec: String
    /// Audio payload bitrate of that codec, bit/s (Opus CBR target, or
    /// 1536000 for PCM16; 0 = none sent).
    var bitrate: Int
    /// Mean payload bytes per 5 ms frame (Opus 192: 120, Opus 128: 80,
    /// PCM16: 960).
    var avgPayloadBytes: Double
    /// p99 of the per-frame encode time in the last second, ms.
    var encodeMsP99: Double
    /// Where the audio travels: "Wi-Fi", "Tailscale direct", "Tailscale
    /// relay", "Tailscale", "Internet" ("" = not streaming).
    var path: String
    /// Stream profile: "lan" / "wan".
    var profile: String
    /// Concrete address streamed to (Bonjour service, or the tailnet IP the
    /// failover picked).
    var endpoint: String
    /// Wire bytes this streaming session (payload + IP/UDP/WireGuard
    /// header estimate per datagram).
    var bytesTotal: Int
    /// ≈ MB per hour at the rate of the last 10 s.
    var mbPerHour: Double
}

/// Owns tap → frame converter → UDP sender and drives them from the virtual
/// device's state: streaming runs while "iPhone (Mac Audio Bridge)" is the
/// default output AND a receiver is known — a Bonjour service (selected in the
/// menu or the only one visible) or a manual host — and stops (releasing the
/// tap) the moment the user switches the output away. All state lives on the
/// main actor; CoreAudio listeners and the Bonjour browser hop over from their
/// own queues via `@Sendable` callbacks built in nonisolated factories.
@MainActor
final class SenderController: ObservableObject {
    /// Whether the audio pipeline is currently running.
    enum Mode: Equatable {
        case waiting
        case streaming
    }

    private static let statsFileURL = FileManager.default.urls(
        for: .libraryDirectory, in: .userDomainMask
    )[0].appendingPathComponent("Logs/MacAudioBridge/sender-stats.jsonl")

    @Published private(set) var mode: Mode = .waiting
    /// False while the HAL driver is not loaded (not installed / coreaudiod
    /// restart pending). The menu then shows the install command.
    @Published private(set) var driverInstalled = false
    @Published private(set) var defaultOutputIsOurs = false
    /// Virtual-device volume scalar (0...1) — reflects the volume keys.
    @Published private(set) var deviceVolume: Float = 0
    @Published private(set) var deviceMuted = false
    /// Name of the output device used before "iPhone (Mac Audio Bridge)" was
    /// selected, for the "Switch back" button.
    @Published private(set) var previousDeviceName: String?
    @Published private(set) var hasPreviousDevice = false
    @Published private(set) var tapSampleRate: Double?
    @Published private(set) var packetsPerSecond = 0
    @Published private(set) var currentSequence: UInt32 = 0
    @Published private(set) var captureWarning: String?
    @Published var failureMessage: String?
    /// Receiver currently streamed to (service name or host; "" when idle).
    @Published private(set) var activeReceiver = ""
    /// Bonjour receivers currently visible, sorted.
    @Published private(set) var visibleReceivers: [String] = []
    /// The receiver picked in the menu (nil = automatic).
    @Published private(set) var selectedReceiver: String?
    @Published private(set) var selectionStatus: ReceiverSelection.Status = .noReceiver
    /// Keepalive liveness of the current connection (nil = no connection).
    @Published private(set) var link: ReceiverLiveness.State?
    @Published private(set) var browserStatus: ReceiverBrowser.Status = .starting
    /// Whether the manual address is in effect — only after the user opened
    /// the "Manual address" section once, so an old typed-in IP from before
    /// discovery existed is not silently used.
    @Published private(set) var manualAddressEnabled: Bool
    /// The manual host as typed (persisted under `receiverHost`).
    @Published private(set) var manualHost: String
    /// Codec / bitrate picked in the menu (persisted under `streamQuality`).
    @Published private(set) var quality: StreamQuality
    /// The Internet profile's quality (persisted under `internetQuality`).
    @Published private(set) var internetQuality: InternetQuality
    /// Bytes sent per second (all datagrams), in kB/s, for the menu.
    @Published private(set) var kilobytesPerSecond: Double = 0

    // MARK: Internet mode state (see SenderController+Internet.swift)

    @Published var streamProfile: StreamProfile = .lan
    @Published var streamPath: StreamPath = .local
    /// Why the encoded quality differs from the pick (WAN cap).
    @Published var qualityNote: String?
    @Published var sessionMegabytes: Double = 0
    @Published var megabytesPerHour: Double = 0
    /// The concrete endpoint in use ("" = none): the service name or the
    /// tailnet address the failover picked.
    @Published var endpointName = ""
    @Published var tailscaleState: TailscaleMonitor.State = .unknown
    /// iOS peers of the tailnet (from `tailscale status`).
    @Published var tailscalePeers: [TailscaleStatus.Peer] = []
    /// Receivers whose tailnet addresses are known, sorted.
    @Published var remoteReceivers: [String] = []
    /// Host chosen explicitly in the menu (typed address / Tailscale peer).
    @Published var storedHost: String?
    @Published var controlPort: UInt16?
    var tailscaleStatus: TailscaleStatus?
    var tailscaleMonitor: TailscaleMonitor?
    /// Receiver service → its tailnet addresses (from the phone's hello),
    /// persisted under `tailnetAddressesKey`.
    var tailnetBook: [String: [String]] = [:]
    /// Receiver service → its phone reports an expensive path.
    var phoneExpensive: [String: Bool] = [:]
    /// Address kind of each control session's peer.
    var sessionKinds: [ControlServer.SessionID: NetworkAddressKind] = [:]
    var failover: PathFailover?
    /// The logical target `failover` belongs to.
    var failoverTarget: ReceiverTarget?
    /// The concrete target the UDP sender is pointed at.
    var concreteTarget: ReceiverTarget?
    /// Reconnect count seen at the last failover check.
    var lastReconnects = 0
    var usageMeter = DataUsageMeter()
    let profileGate = ProfileGate()
    var ownTailnetAddresses: [String] = []
    var menuOpen = false
    static let tailnetAddressesKey = "tailnetAddresses"
    static let storedHostKey = "receiverChosenHost"

    // MARK: Remote control state (see SenderController+Remote.swift)

    /// Phone currently controlling the stream (its control session targets
    /// the receiver we stream to) — "Controlled from iPhone …".
    @Published var controllingPhone: String?
    /// The Mac that took the phone over from us — "iPhone used by …".
    @Published var usedBy: String?
    /// Released by the phone while there was no other output to switch to:
    /// the output stays ours but streaming is paused until an explicit
    /// action (menu "Resume", phone connect, re-selecting the output).
    @Published var releasedHold = false
    @Published var controlServerStatus: ControlServer.Status = .starting
    /// Name of the current default output device (for the phone).
    var outputDeviceName: String?
    /// Name this Mac is advertised under (Bonjour may rename on a conflict).
    var advertisedName = SourceIdentity.computerName()
    var controlServer: ControlServer?
    /// Playback control from the phone + what plays here (M9).
    let media = MacMediaControl()
    /// Hello per open control session (nil until the phone sent it).
    var sessions: [ControlServer.SessionID: PhoneHello?] = [:]
    // Phone microphone (SenderController+Mic.swift).
    let micEngine = MicEngine()
    var micFeeder: MicFeeder?
    var micDemand = MicDemand()
    let micEvents = DeviceEventObserver()
    var micObservedDeviceID: AudioObjectID?
    /// Each phone's last reported mic (protocol version 4 phones only).
    var micStates: [ControlServer.SessionID: MicState] = [:]
    /// The phone that was sent `micStart` (nil = none).
    var micRequestedSession: ControlServer.SessionID?
    @Published var micStatus: MicMenuStatus = .off
    var lastSentStatus: [ControlServer.SessionID: (status: SourceStatus, at: TimeInterval)] = [:]
    /// Output switch memory + takeover detection.
    var outputModel: OutputRestoreModel
    /// Set when the user selected our output on the Mac; the claim goes to
    /// the phone once streaming to it has started (expires after 10 s).
    var pendingClaimSince: TimeInterval?
    /// The next "became ours" transition is ours (phone connect), not a
    /// user action: no claim until this uptime.
    var suppressClaimUntil: TimeInterval = 0
    static let rememberedOutputUIDKey = "rememberedOutputUID"
    static let rememberedOutputNameKey = "rememberedOutputName"

    var selection: ReceiverSelection
    private(set) var activeTarget: ReceiverTarget?
    private var browser: ReceiverBrowser?

    /// The 1 Hz state loop, owned by the controller itself: the menu's
    /// SwiftUI lifetime only spans an open menu, so nothing view-side may
    /// drive evaluation or stats.
    private var stateLoop: Task<Void, Never>?

    /// UserDefaults keys.
    private static let hostKey = "receiverHost"
    private static let serviceNameKey = "receiverServiceName"
    private static let manualAddressEnabledKey = "manualAddressEnabled"
    /// Shared with the menu's `@AppStorage("streamQuality")`.
    static let qualityKey = "streamQuality"
    /// Shared with the menu's `@AppStorage("internetQuality")`.
    static let internetQualityKey = "internetQuality"

    init() {
        // Persisted choices — read here so streaming can start at launch
        // with the menu never opened.
        let defaults = UserDefaults.standard
        let storedService = defaults.string(forKey: Self.serviceNameKey)
        let manualEnabled = defaults.bool(forKey: Self.manualAddressEnabledKey)
        let host = (defaults.string(forKey: Self.hostKey) ?? "")
            .trimmingCharacters(in: .whitespaces)
        manualAddressEnabled = manualEnabled
        manualHost = host
        quality = defaults.string(forKey: Self.qualityKey).flatMap(StreamQuality.init(rawValue:))
            .flatMap { StreamQuality.lanChoices.contains($0) ? $0 : nil } ?? .default
        internetQuality = defaults.string(forKey: Self.internetQualityKey).flatMap(InternetQuality.init(rawValue:))
            ?? .default
        let book = (defaults.dictionary(forKey: Self.tailnetAddressesKey) as? [String: [String]]) ?? [:]
        let chosenHost = defaults.string(forKey: Self.storedHostKey)
        tailnetBook = book
        storedHost = chosenHost
        remoteReceivers = book.keys.sorted()
        selection = ReceiverSelection(
            storedSelection: storedService,
            manualHost: manualEnabled ? host : "",
            storedHost: chosenHost,
            remoteReachable: Set(book.keys),
            now: Self.uptime())
        outputModel = OutputRestoreModel(
            bridgeUID: BridgeDevice.uid,
            remembered: defaults.string(forKey: Self.rememberedOutputUIDKey).map { uid in
                OutputDeviceInfo(
                    uid: uid, name: defaults.string(forKey: Self.rememberedOutputNameKey) ?? uid,
                    isBuiltIn: false)
            })
        converter.encodingGate.value = .lan(quality)
        udpSender.setMicEngine(micEngine)
        tailscaleMonitor = Self.makeTailscaleMonitor(controller: self)
        ownTailnetAddresses = InterfaceAddresses.tailnet()
        // Bonjour browsing runs for the whole app lifetime, from launch.
        let browser = Self.makeBrowser(controller: self)
        self.browser = browser
        browser.start()
        // Phones find this Mac as a source and control it from launch on.
        let server = Self.makeControlServer(controller: self, serviceName: advertisedName)
        controlServer = server
        server.start()
        media.start { [weak self] info in
            self?.broadcastNowPlaying(info)
        }
        // Main-actor task loop (the class is @MainActor, so the task inherits
        // the main actor): one immediate pass — streaming starts within this
        // first evaluate when our device is the default output and a receiver
        // is known — then refresh every second.
        stateLoop = Task { [weak self] in
            self?.evaluate()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.refreshStats()
            }
        }
    }

    deinit {
        stateLoop?.cancel()
        browser?.stop()
        controlServer?.stop()
    }

    private let tap = DeviceAudioTap()
    let converter = FrameConverter()
    private let udpSender = UDPSender()
    private let frameStats = FrameStats()
    private let captureWarningMailbox = WarningMailbox()
    private let deviceEvents = DeviceEventObserver()
    private let statsWriter = RollingJSONLWriter(fileURL: SenderController.statsFileURL)
    private let statsEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// App Nap prevention held while streaming: without it (LSUIElement menu
    /// bar app, no windows), macOS throttles the 2.5 ms drain timer and the
    /// tap ring overflows.
    private var streamingActivity: NSObjectProtocol?
    /// Ring counter baselines for per-second deltas.
    private var lastRingWriteCalls = 0
    private var lastRingCapturedSamples = 0
    private var lastRingDroppedSamples = 0
    /// Device ID the current listener registrations are bound to (device IDs
    /// change when coreaudiod restarts, e.g. on driver install/uninstall).
    private var observedDeviceID: AudioObjectID?

    var isStreaming: Bool { mode == .streaming }
    /// Device volume as a whole percent for the menu.
    var volumePercent: Int { Int((deviceVolume * 100).rounded()) }
    // MARK: - Stream quality

    /// The user picked a quality in the menu: applies from the next frame,
    /// also mid-stream (the receiver follows each frame's codec), and is
    /// persisted.
    func setQuality(_ newQuality: StreamQuality) {
        guard newQuality != quality, StreamQuality.lanChoices.contains(newQuality) else { return }
        quality = newQuality
        UserDefaults.standard.set(newQuality.rawValue, forKey: Self.qualityKey)
        applyEffectiveQuality()
        remoteStateChanged()
    }

    /// The Internet quality was picked (menu or phone): applies from the next
    /// frame while the stream runs the Internet profile, and is persisted.
    func setInternetQuality(_ newQuality: InternetQuality) {
        guard newQuality != internetQuality else { return }
        internetQuality = newQuality
        UserDefaults.standard.set(newQuality.rawValue, forKey: Self.internetQualityKey)
        applyEffectiveQuality()
        remoteStateChanged()
    }

    // MARK: - Receiver selection

    /// The user picked a receiver in the menu (nil = automatic). Persisted by
    /// service name, so it survives relaunches and address changes.
    func selectReceiver(_ name: String?) {
        let name = name.flatMap { $0.isEmpty ? nil : $0 }
        if let name {
            UserDefaults.standard.set(name, forKey: Self.serviceNameKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.serviceNameKey)
        }
        UserDefaults.standard.removeObject(forKey: Self.storedHostKey)
        storedHost = nil
        selection.select(name, now: Self.uptime())
        evaluate()
    }

    /// Called when the "Manual address" section is opened: from then on the
    /// (possibly pre-discovery) typed host is in effect.
    func enableManualAddress() {
        guard !manualAddressEnabled else { return }
        manualAddressEnabled = true
        UserDefaults.standard.set(true, forKey: Self.manualAddressEnabledKey)
        selection.setManualHost(manualHost, now: Self.uptime())
        evaluate()
    }

    /// The manual host, kept in sync with the menu's text field — editable at
    /// any time, also while streaming (the connection is recreated).
    func setManualHost(_ host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard trimmed != manualHost else { return }
        manualHost = trimmed
        UserDefaults.standard.set(trimmed, forKey: Self.hostKey)
        guard manualAddressEnabled else { return }
        selection.setManualHost(trimmed, now: Self.uptime())
        evaluate()
    }

    private func receiversChanged(_ names: [String]) {
        selection.updateVisibleServices(names, now: Self.uptime())
        evaluate()
    }

    private func browserStatusChanged(_ status: ReceiverBrowser.Status) {
        browserStatus = status
    }

    private func publishSelection() {
        if visibleReceivers != selection.visibleServices {
            visibleReceivers = selection.visibleServices
        }
        if selectedReceiver != selection.storedSelection {
            selectedReceiver = selection.storedSelection
        }
        if selectionStatus != selection.status {
            selectionStatus = selection.status
        }
    }

    /// Monotonic seconds for the selection's grace timing.
    static func uptime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    // MARK: - Output-device actions

    /// Makes "iPhone (Mac Audio Bridge)" the default output (an explicit
    /// Mac-side action: the phone switches to this Mac), remembering the
    /// device used before so `switchBackToPreviousOutput` can restore it.
    func useIPhoneAsOutput() {
        guard let deviceID = BridgeDevice.deviceID(),
            let currentDefault = BridgeDevice.defaultOutputDeviceID(),
            currentDefault != deviceID
        else { return }
        observeOutput(BridgeDevice.outputDeviceInfo(currentDefault))
        _ = BridgeDevice.setDefaultOutputDevice(deviceID)
        evaluate()
    }

    /// Restores the output device used before ours was selected (or the
    /// built-in output when that one is gone).
    func switchBackToPreviousOutput() {
        _ = restorePreviousOutput()
        evaluate()
    }

    /// Switches the default output to `outputModel.restoreTarget`; false
    /// when there is no other output device.
    func restorePreviousOutput() -> Bool {
        let available = BridgeDevice.outputDevices()
        guard let target = outputModel.restoreTarget(available: available.map(\.info)),
            let id = available.first(where: { $0.info.uid == target.uid })?.id
        else { return false }
        return BridgeDevice.setDefaultOutputDevice(id)
    }

    /// Feeds the default output into the switch model; persists the
    /// remembered device and reacts to takeovers. Returns the transition.
    @discardableResult
    func observeOutput(_ device: OutputDeviceInfo?) -> OutputRestoreModel.Transition {
        let before = outputModel.remembered
        let transition = outputModel.observeDefaultOutput(device)
        if let remembered = outputModel.remembered, remembered != before {
            UserDefaults.standard.set(remembered.uid, forKey: Self.rememberedOutputUIDKey)
            UserDefaults.standard.set(remembered.name, forKey: Self.rememberedOutputNameKey)
        }
        if previousDeviceName != outputModel.remembered?.name {
            previousDeviceName = outputModel.remembered?.name
        }
        if !hasPreviousDevice {
            // The model always has a fallback (built-in) to switch back to.
            hasPreviousDevice = true
        }
        handleOutputTransition(transition)
        return transition
    }

    // MARK: - Automatic start/stop

    /// Re-reads the world (driver presence, default output, volume/mute,
    /// receiver selection) and starts or stops streaming accordingly. Called
    /// ~1 Hz from `refreshStats`, from every CoreAudio property listener, on
    /// every browse change, and after menu actions — so a stuck state
    /// self-heals on the next tick.
    func evaluate() {
        selection.tick(now: Self.uptime())
        publishSelection()

        // Resolve fresh every time: the AudioObjectID is not stable across
        // coreaudiod restarts.
        let deviceID = BridgeDevice.deviceID()
        driverInstalled = deviceID != nil
        refreshDeviceListeners(deviceID)

        guard let deviceID else {
            if mode == .streaming { stopStreaming() }
            defaultOutputIsOurs = false
            outputDeviceName = BridgeDevice.defaultOutputDeviceID().flatMap(BridgeDevice.deviceName)
            refreshMic()
            remoteStateChanged()
            return
        }

        let defaultID = BridgeDevice.defaultOutputDeviceID()
        defaultOutputIsOurs = defaultID == deviceID

        // Keep "previous device" meaningful: whenever the user routes the
        // output to something that is not ours, that becomes the device to
        // switch back to. A switch to ours is a takeover (claim).
        let defaultInfo = defaultID.flatMap(BridgeDevice.outputDeviceInfo)
        outputDeviceName = defaultInfo?.name
        observeOutput(defaultInfo)

        updateVolume(deviceID: deviceID)

        // A release with nowhere to switch to keeps the output but pauses.
        let shouldStream = defaultOutputIsOurs && !releasedHold
        let target = selection.target
        switch (shouldStream, target, mode) {
        case (true, let target?, .waiting):
            startStreaming(target: target, deviceID: deviceID)
        case (true, let target?, .streaming) where target != activeTarget:
            // Receiver changed mid-stream (menu pick, manual edit): only the
            // connection is replaced, the tap keeps running.
            setActiveTarget(target)
        case (false, _, .streaming), (_, nil, .streaming):
            stopStreaming()
        default:
            break
        }
        updateInternetPath(snapshot: nil)
        refreshMic()
        remoteStateChanged()
    }

    /// The logical target (receiver) changed: a fresh failover for it, then
    /// the concrete endpoint goes to the UDP sender.
    private func setActiveTarget(_ target: ReceiverTarget?) {
        activeTarget = target
        activeReceiver = target?.displayName ?? ""
        if target != failoverTarget {
            failoverTarget = target
            failover = makeFailover(for: target)
            lastReconnects = udpSender.linkSnapshot().reconnects
        }
        applyConcreteTarget()
    }

    /// Points the UDP sender at the failover's current path.
    func applyConcreteTarget() {
        let concrete = resolveConcreteTarget()
        guard concrete != concreteTarget else { return }
        concreteTarget = concrete
        endpointName = concrete?.displayName ?? ""
        udpSender.setTarget(concrete)
    }

    var linkSnapshot: UDPSender.LinkSnapshot { udpSender.linkSnapshot() }

    func setLivenessTimeout(_ seconds: TimeInterval) {
        udpSender.setLivenessTimeout(seconds)
    }

    private func startStreaming(target: ReceiverTarget, deviceID: AudioObjectID) {
        // Hold the system awake for the whole run: this is an LSUIElement app
        // with no window, so without an activity assertion App Nap coalesces
        // the 2.5 ms drain timer into seconds-long silences and the tap ring
        // overflows (measured: 26 kB/s out of an expected 194 kB/s).
        streamingActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Streaming audio to iPhone")

        // Process taps are gated by the "System Audio Recording" TCC service: the
        // system prompt appears when the tap/IO starts. A denial shows up either as
        // an error from start, or as zero-filled buffers — detected by the converter
        // after 3 s and reported through `captureWarning`.
        do {
            try tap.start()
        } catch {
            failureMessage = "Could not start the audio tap: \(error.localizedDescription)"
            if let activity = streamingActivity {
                ProcessInfo.processInfo.endActivity(activity)
                streamingActivity = nil
            }
            return
        }

        tapSampleRate = tap.sampleRate
        converter.audibility.reset()
        captureWarning = nil
        failureMessage = nil
        frameStats.reset()
        // Both callbacks run on the converter queue: they are @Sendable, capture
        // only Sendable state (no self), and never touch UI state directly.
        usageMeter.reset()
        sessionMegabytes = 0
        megabytesPerHour = 0
        let packer = RedundancyPackerBox(sourceTag: SourceIdentity.tag, profileGate: profileGate)
        converter.onFrame = { [udpSender, frameStats] packet in
            // Primary datagram first (Opus: carrying the previous 4 frames),
            // then any redundancy-only datagram (PCM16's delayed copy, see
            // AudioRedundancy); every datagram stays ≤ 1200 B (no IP
            // fragmentation).
            for datagram in packer.pack(packet) {
                udpSender.send(datagram)
            }
            frameStats.record(sequence: packet.sequence)
        }
        converter.onCaptureStalled = { [captureWarningMailbox] in
            captureWarningMailbox.post(captureDeniedMessage)
        }
        setActiveTarget(target)
        updateVolume(deviceID: deviceID)
        converter.start(ring: tap.ring, tapSampleRate: tap.sampleRate)
        mode = .streaming
    }

    private func stopStreaming() {
        // The converter is the ring's consumer side: stop (and drain) it on its
        // queue BEFORE the tap goes away. The ring reset for the next run happens
        // on that same queue in FrameConverter.start.
        converter.stop()
        udpSender.cancel()
        activeTarget = nil
        activeReceiver = ""
        failover = nil
        failoverTarget = nil
        concreteTarget = nil
        endpointName = ""
        link = nil
        tap.stop()
        if let activity = streamingActivity {
            ProcessInfo.processInfo.endActivity(activity)
            streamingActivity = nil
        }
        tapSampleRate = nil
        packetsPerSecond = 0
        kilobytesPerSecond = 0
        currentSequence = 0
        captureWarning = nil
        mode = .waiting
    }

    // MARK: - Volume

    /// Reads the virtual device's volume/mute, publishes it, and feeds the
    /// converter's gain (mute → zeros). The volume keys and the menu-bar
    /// slider change the device control, the listener calls `evaluate`, and
    /// the new gain applies from the next drain tick.
    func updateVolume(deviceID: AudioObjectID) {
        let volume = BridgeDevice.volumeScalar(deviceID) ?? 1
        let muted = BridgeDevice.isMuted(deviceID) ?? false
        deviceVolume = volume
        deviceMuted = muted
        converter.volumeGate.value = muted ? 0 : volume
    }

    // MARK: - Listeners

    /// Registers the CoreAudio listeners: default-output changes on the system
    /// object, and running-somewhere / volume / mute on our device. Re-binds
    /// them whenever the device's AudioObjectID changes.
    private func refreshDeviceListeners(_ deviceID: AudioObjectID?) {
        guard deviceID != observedDeviceID else { return }
        deviceEvents.removeAllRegistrations()
        observedDeviceID = deviceID

        let event = Self.makeDeviceEventHandler(controller: self)
        _ = deviceEvents.add(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            scope: kAudioObjectPropertyScopeGlobal,
            onEvent: event)
        guard let deviceID else { return }
        _ = deviceEvents.add(
            objectID: deviceID,
            selector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            scope: kAudioObjectPropertyScopeGlobal,
            onEvent: event)
        _ = deviceEvents.add(
            objectID: deviceID,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: kAudioObjectPropertyScopeOutput,
            onEvent: event)
        _ = deviceEvents.add(
            objectID: deviceID,
            selector: kAudioDevicePropertyMute,
            scope: kAudioObjectPropertyScopeOutput,
            onEvent: event)
    }

    // MARK: - Nonisolated callback factories

    /// CoreAudio listener callback: runs on the listener queue, captures only
    /// a weak reference to the (Sendable, main-actor) controller and hops to
    /// the main actor.
    nonisolated private static func makeDeviceEventHandler(
        controller: SenderController
    ) -> @Sendable () -> Void {
        { [weak controller] in
            Task { @MainActor in controller?.evaluate() }
        }
    }

    /// Bonjour browser with callbacks that hop to the main actor in FIFO
    /// order (`DispatchQueue.main`), so an older result set can never
    /// overwrite a newer one.
    nonisolated private static func makeBrowser(controller: SenderController) -> ReceiverBrowser {
        ReceiverBrowser(
            onResults: { [weak controller] names in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { controller?.receiversChanged(names) }
                }
            },
            onStatus: { [weak controller] status in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { controller?.browserStatusChanged(status) }
                }
            })
    }

    // MARK: - Stats

    /// Pulls counter snapshots and background warnings for the UI, re-evaluates
    /// the streaming state, and appends a telemetry line — call ~1 Hz.
    func refreshStats() {
        evaluate()
        packetsPerSecond = frameStats.takePerSecondCount()
        currentSequence = frameStats.sequence
        if let warning = captureWarningMailbox.take() {
            captureWarning = warning
        }
        let snapshot = udpSender.linkSnapshot()
        if link != snapshot.link {
            link = snapshot.link
        }
        updateInternetPath(snapshot: snapshot)
        refreshInternetHousekeeping()
        logStats(link: udpSender.linkSnapshot())
    }

    /// Appends one JSON line of sender telemetry to
    /// `~/Library/Logs/MacAudioBridge/sender-stats.jsonl` — call ~1 Hz, in
    /// both waiting and streaming modes. Only atomic ring/sender counters come
    /// off the hot paths; encoding happens here, the file write on the writer's
    /// utility queue.
    private func logStats(link snapshot: UDPSender.LinkSnapshot) {
        let effectiveVolume = deviceMuted ? 0.0 : Double(deviceVolume)
        let ring = tap.ring
        let writeCalls = ring.writeCallCount
        let capturedSamples = ring.storedSampleCount + ring.droppedSampleCount
        let droppedSamples = ring.droppedSampleCount
        let sent = udpSender.takeSentCounts()
        kilobytesPerSecond = mode == .streaming ? Double(sent.bytes) / 1000 : 0
        if mode == .streaming {
            usageMeter.record(datagrams: sent.datagrams, payloadBytes: sent.bytes, path: streamPath)
            sessionMegabytes = usageMeter.totalMegabytes
            megabytesPerHour = usageMeter.megabytesPerHour
        }
        let encoder = converter.encoderStats.take()
        let codecBitrate: Int
        switch encoder.codec {
        case .opus?:
            codecBitrate = streamProfile.effectiveQuality(lan: quality, internet: internetQuality).opusBitrate ?? 0
        case .pcm16?: codecBitrate = StreamQuality.pcm.payloadBitrate
        case nil: codecBitrate = 0
        }
        let line = SenderStatsLine(
            mode: mode == .streaming ? "streaming" : "waiting",
            defaultOutputIsOurs: defaultOutputIsOurs,
            volume: effectiveVolume,
            timestamp: Date().timeIntervalSince1970,
            ioCallbacks: writeCalls - lastRingWriteCalls,
            samplesCaptured: capturedSamples - lastRingCapturedSamples,
            ringDroppedSamples: droppedSamples - lastRingDroppedSamples,
            ringFillSamples: ring.availableToRead,
            packetsSent: sent.datagrams,
            bytesSent: sent.bytes,
            maxTickMs: converter.takeMaxTickIntervalMilliseconds(),
            appNapActivityHeld: streamingActivity != nil,
            receiver: (snapshot.target ?? selection.target)?.displayName ?? "",
            keepaliveAgeMs: snapshot.keepaliveAge.map { ($0 * 1000).rounded() } ?? -1,
            connectionState: snapshot.connectionState,
            link: snapshot.link?.rawValue ?? "",
            reconnects: snapshot.reconnects,
            codec: encoder.codec.map(StreamQuality.statsName) ?? "",
            bitrate: codecBitrate,
            avgPayloadBytes: (encoder.averagePayloadBytes * 10).rounded() / 10,
            encodeMsP99: (encoder.encodeMsP99 * 1000).rounded() / 1000,
            path: mode == .streaming ? streamPath.displayName : "",
            profile: streamProfile.statsName,
            endpoint: endpointName,
            bytesTotal: usageMeter.totalBytes,
            mbPerHour: usageMeter.megabytesPerHour)
        lastRingWriteCalls = writeCalls
        lastRingCapturedSamples = capturedSamples
        lastRingDroppedSamples = droppedSamples
        if let data = try? statsEncoder.encode(line) {
            statsWriter.append(data)
        }
    }
}
