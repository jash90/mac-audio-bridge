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
}

/// Owns tap → frame converter → UDP sender and drives them from the virtual
/// device's state: streaming runs while "iPhone (Mac Audio Bridge)" is the
/// default output AND a receiver address is set, and stops (releasing the tap)
/// the moment the user switches the output away. All state lives on the main
/// actor; CoreAudio listeners hop over from their own queue via a `@Sendable`
/// callback.
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
    @Published private(set) var failureMessage: String?
    /// The address currently streaming to (set when a run starts).
    @Published private(set) var activeHost = ""

    private var receiverHost = "" {
        didSet { evaluate() }
    }

    private let tap = DeviceAudioTap()
    private let converter = FrameConverter()
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
    private var previousDeviceID: AudioObjectID?

    var isStreaming: Bool { mode == .streaming }
    /// Device volume as a whole percent for the menu.
    var volumePercent: Int { Int((deviceVolume * 100).rounded()) }
    /// True while no receiver address is configured (drives the waiting text).
    var receiverHostIsEmpty: Bool { receiverHost.isEmpty }

    /// The receiver address, kept in sync with the menu's text field.
    func setHost(_ host: String) {
        receiverHost = host.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Output-device actions

    /// Makes "iPhone (Mac Audio Bridge)" the default output, remembering the
    /// device used before so `switchBackToPreviousOutput` can restore it.
    func useIPhoneAsOutput() {
        guard let deviceID = BridgeDevice.deviceID(),
            let currentDefault = BridgeDevice.defaultOutputDeviceID(),
            currentDefault != deviceID
        else { return }
        previousDeviceID = currentDefault
        previousDeviceName = BridgeDevice.deviceName(currentDefault)
        hasPreviousDevice = true
        _ = BridgeDevice.setDefaultOutputDevice(deviceID)
        evaluate()
    }

    /// Restores the output device used before ours was selected.
    func switchBackToPreviousOutput() {
        guard let previous = previousDeviceID else { return }
        _ = BridgeDevice.setDefaultOutputDevice(previous)
        evaluate()
    }

    // MARK: - Automatic start/stop

    /// Re-reads the world (driver presence, default output, volume/mute) and
    /// starts or stops streaming accordingly. Called ~1 Hz from `refreshStats`,
    /// from every CoreAudio property listener, and after host/button changes —
    /// so a stuck state self-heals on the next tick.
    func evaluate() {
        // Resolve fresh every time: the AudioObjectID is not stable across
        // coreaudiod restarts.
        let deviceID = BridgeDevice.deviceID()
        driverInstalled = deviceID != nil
        refreshDeviceListeners(deviceID)

        guard let deviceID else {
            if mode == .streaming { stopStreaming() }
            defaultOutputIsOurs = false
            return
        }

        let defaultID = BridgeDevice.defaultOutputDeviceID()
        defaultOutputIsOurs = defaultID == deviceID

        // Keep "previous device" meaningful: whenever the user routes the
        // output to something that is not ours, that becomes the device to
        // switch back to.
        if let defaultID, defaultID != deviceID, defaultID != previousDeviceID {
            previousDeviceID = defaultID
            previousDeviceName = BridgeDevice.deviceName(defaultID)
            hasPreviousDevice = true
        }

        updateVolume(deviceID: deviceID)

        let shouldStream = defaultOutputIsOurs && !receiverHost.isEmpty
        switch (shouldStream, mode) {
        case (true, .waiting):
            startStreaming(host: receiverHost, deviceID: deviceID)
        case (false, .streaming):
            stopStreaming()
        default:
            break
        }
    }

    private func startStreaming(host: String, deviceID: AudioObjectID) {
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

        activeHost = host
        tapSampleRate = tap.sampleRate
        captureWarning = nil
        failureMessage = nil
        frameStats.reset()
        // Both callbacks run on the converter queue: they are @Sendable, capture
        // only Sendable state (no self), and never touch UI state directly.
        converter.onFrame = { [udpSender, frameStats] packet in
            udpSender.send(packet.encoded())
            frameStats.record(sequence: packet.sequence)
        }
        converter.onCaptureStalled = { [captureWarningMailbox] in
            captureWarningMailbox.post(captureDeniedMessage)
        }
        udpSender.setHost(host)
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
        tap.stop()
        if let activity = streamingActivity {
            ProcessInfo.processInfo.endActivity(activity)
            streamingActivity = nil
        }
        activeHost = ""
        tapSampleRate = nil
        packetsPerSecond = 0
        currentSequence = 0
        captureWarning = nil
        mode = .waiting
    }

    // MARK: - Volume

    /// Reads the virtual device's volume/mute, publishes it, and feeds the
    /// converter's gain (mute → zeros). The volume keys and the menu-bar
    /// slider change the device control, the listener calls `evaluate`, and
    /// the new gain applies from the next drain tick.
    private func updateVolume(deviceID: AudioObjectID) {
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

        // @Sendable closures do not inherit main-actor isolation; each hops to
        // the main actor itself.
        let event: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.evaluate() }
        }
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
        logStats()
    }

    /// Appends one JSON line of sender telemetry to
    /// `~/Library/Logs/MacAudioBridge/sender-stats.jsonl` — call ~1 Hz, in
    /// both waiting and streaming modes. Only atomic ring/sender counters come
    /// off the hot paths; encoding happens here, the file write on the writer's
    /// utility queue.
    private func logStats() {
        let effectiveVolume = deviceMuted ? 0.0 : Double(deviceVolume)
        let ring = tap.ring
        let writeCalls = ring.writeCallCount
        let capturedSamples = ring.storedSampleCount + ring.droppedSampleCount
        let droppedSamples = ring.droppedSampleCount
        let sent = udpSender.takeSentCounts()
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
            appNapActivityHeld: streamingActivity != nil)
        lastRingWriteCalls = writeCalls
        lastRingCapturedSamples = capturedSamples
        lastRingDroppedSamples = droppedSamples
        if let data = try? statsEncoder.encode(line) {
            statsWriter.append(data)
        }
    }
}
