import AVFoundation
import BridgeCore
import Foundation
import os
import UIKit

/// One system audio event, parsed into Sendable values on the posting
/// thread before it hops to the main actor.
enum AudioSystemEvent: Sendable {
    case interruptionBegan(reason: UInt?)
    case interruptionEnded(shouldResume: Bool)
    case routeChanged(reason: UInt)
    case mediaServicesLost
    case mediaServicesReset
    case engineConfigurationChanged(engine: ObjectIdentifier?)
    case appBecameActive
}

/// Keeps audio playing no matter what the system does to the session.
///
/// The audio engine can be stopped behind the app's back at any time: an
/// interruption (call, Siri, another app, a launch while locked), a route
/// change (AirPods in or out) that changes the hardware format — the engine
/// then posts `AVAudioEngineConfigurationChange` and stays stopped — or a
/// media-services reset that invalidates every AV object. The network side
/// keeps filling the jitter buffer regardless, so a stopped engine shows up
/// as packets received and nothing played. This controller:
/// - activates the session at launch and whenever the app becomes active;
/// - restarts the engine after interruptions (on `.shouldResume`, or when
///   packets are arriving), after route and configuration changes, and
///   rebuilds it after a media-services reset;
/// - runs a watchdog (`PlaybackWatchdog`, 4 Hz) that restarts the engine when
///   packets arrived but nothing was played for 1 s, whatever the cause.
///
/// Framework callbacks are created in `nonisolated` factories, capture only
/// Sendable state and hop to the main actor, where all state lives. The
/// supervision loop is owned here, not by any view.
@MainActor
final class PlaybackController {
    /// Telemetry for the stats line and the UI.
    struct Snapshot: Sendable {
        var engineRunning: Bool
        var renderCallsPerSecond: Int
        var engineRestarts: Int
        var sessionSampleRate: Double
        var ioBufferMilliseconds: Double
        var routeChanges: Int
        var interruptions: Int
        var concealment: ConcealmentStats
    }

    private let jitterBuffer: JitterBuffer
    private let output: AudioOutput
    private let logger = Logger(subsystem: "dev.jash90.MacAudioBridge", category: "playback")
    private let observerTokens = ObserverTokens()
    private let clockStart = ContinuousClock.now
    private var watchdog = PlaybackWatchdog()
    private var superviseLoop: Task<Void, Never>?
    private var pendingRecovery: Task<Void, Never>?
    private var started = false
    private var hasStartedOnce = false
    private var isInterrupted = false

    private var engineRestarts = 0
    private var routeChanges = 0
    private var interruptions = 0
    private var renderCallsPerSecond = 0
    private var rateWindowStart: TimeInterval = 0
    private var rateWindowRenderCalls = 0
    private var lastReceived = 0
    private var lastArrivalAt: TimeInterval?

    /// Supervision cadence: 250 ms.
    private static let superviseInterval: Duration = .milliseconds(250)
    /// Delay before a recovery restart, coalescing bursts of notifications
    /// (a route change is usually followed by a configuration change): 50 ms.
    private static let recoveryDelay: Duration = .milliseconds(50)
    /// "Packets are arriving" for the interruption-ended decision: an arrival
    /// within the last 2 s.
    private static let recentArrivalWindow: TimeInterval = 2.0

    init(jitterBuffer: JitterBuffer) {
        self.jitterBuffer = jitterBuffer
        output = AudioOutput(jitterBuffer: jitterBuffer)
    }

    deinit {
        superviseLoop?.cancel()
        pendingRecovery?.cancel()
    }

    var isEngineRunning: Bool { output.isRunning }

    var partiallyPlayedFrames: Double { output.partiallyPlayedFrames }

    var snapshot: Snapshot {
        let session = AVAudioSession.sharedInstance()
        return Snapshot(
            engineRunning: output.isRunning,
            renderCallsPerSecond: renderCallsPerSecond,
            engineRestarts: engineRestarts,
            sessionSampleRate: session.sampleRate,
            ioBufferMilliseconds: session.ioBufferDuration * 1000,
            routeChanges: routeChanges,
            interruptions: interruptions,
            concealment: output.concealmentStats)
    }

    /// Installs the observers and the supervision loop (once) and starts the
    /// engine. Never throws: a failed start is logged and retried by the
    /// watchdog, the next foreground activation or the next system event.
    func start() {
        guard !started else { return }
        started = true
        observerTokens.tokens = Self.installObservers(
            appDidBecomeActive: UIApplication.didBecomeActiveNotification,
            deliver: Self.makeDeliver(to: self))
        startEngine(reason: "launch")
        startSuperviseLoop()
    }

    // MARK: - Events (main actor)

    private func handle(_ event: AudioSystemEvent) {
        switch event {
        case .interruptionBegan(let reason):
            interruptions += 1
            isInterrupted = true
            logger.notice(
                "interruption began (reason \(reason.map(String.init) ?? "-", privacy: .public)); engine running: \(self.output.isRunning)"
            )
        case .interruptionEnded(let shouldResume):
            isInterrupted = false
            let arriving = packetsArrivingRecently
            logger.notice(
                "interruption ended (shouldResume \(shouldResume), packets arriving \(arriving))")
            // Without either, the watchdog restarts the engine as soon as
            // packets arrive again.
            if shouldResume || arriving {
                scheduleRecovery(reason: "interruption ended")
            }
        case .routeChanged(let reason):
            routeChanges += 1
            logger.notice(
                "route change: \(Self.describeRouteChange(reason), privacy: .public) → \(Self.describeCurrentRoute(), privacy: .public)"
            )
            // Keep playing on whatever the new route is (restart if the
            // change stopped the engine; a format change also posts a
            // configuration change, handled below).
            scheduleRecovery(reason: "route change")
        case .mediaServicesLost:
            logger.error("media services were lost")
        case .mediaServicesReset:
            logger.error("media services were reset: rebuilding session and engine")
            output.rebuildEngine()
            scheduleRecovery(reason: "media services reset")
        case .engineConfigurationChanged(let engine):
            // Stale notifications from an engine replaced by a rebuild are
            // ignored; ours has stopped and uninitialized itself.
            guard engine == nil || engine == output.engineIdentifier else { return }
            logger.notice("engine configuration change → \(Self.describeCurrentRoute(), privacy: .public)")
            scheduleRecovery(reason: "engine configuration change")
        case .appBecameActive:
            if output.isRunning {
                do {
                    try output.activateSession()
                } catch {
                    logger.error("session activation on foreground failed: \(error.localizedDescription, privacy: .public)")
                }
            } else {
                scheduleRecovery(reason: "app became active")
            }
        }
    }

    /// Restarts the engine shortly if it is not running by then, coalescing
    /// notification bursts (route change + configuration change, or an
    /// interruption end + foreground activation). Every case where the
    /// system stops the IO leaves `isRunning` false — interruption,
    /// configuration change, a fresh engine after a media-services reset; a
    /// stopped IO that still reports running is caught by the watchdog.
    private func scheduleRecovery(reason: String) {
        guard pendingRecovery == nil else { return }
        pendingRecovery = Task { [weak self] in
            try? await Task.sleep(for: Self.recoveryDelay)
            guard let self else { return }
            self.pendingRecovery = nil
            if !self.output.isRunning {
                self.startEngine(reason: reason)
            }
        }
    }

    /// (Re)starts the engine; on failure logs and leaves the retry to the
    /// watchdog and the next system event.
    private func startEngine(reason: String) {
        do {
            let report = try output.start()
            if hasStartedOnce {
                engineRestarts += 1
            }
            hasStartedOnce = true
            isInterrupted = false
            logger.notice(
                """
                engine started (\(reason, privacy: .public)): session \(report.sessionSampleRate) Hz, \
                IO buffer \(report.ioBufferDuration * 1000, format: .fixed(precision: 2)) ms, \
                output latency \(report.outputLatency * 1000, format: .fixed(precision: 1)) ms, \
                hardware \(report.hardwareSampleRate) Hz × \(report.hardwareChannels), \
                \(report.direct ? "direct to output (no SRC)" : "via main mixer (sample-rate conversion)", privacy: .public); \
                restarts \(self.engineRestarts), route \(Self.describeCurrentRoute(), privacy: .public)
                """)
        } catch {
            logger.error(
                "engine start failed (\(reason, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Supervision loop

    private func startSuperviseLoop() {
        guard superviseLoop == nil else { return }
        rateWindowStart = elapsedSeconds()
        rateWindowRenderCalls = output.renderCallCount
        superviseLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.supervise()
                try? await Task.sleep(for: Self.superviseInterval)
            }
        }
    }

    /// One supervision tick: render-rate telemetry and the watchdog.
    private func supervise() {
        let now = elapsedSeconds()
        let stats = jitterBuffer.stats
        let renderCalls = output.renderCallCount

        let rateWindow = now - rateWindowStart
        if rateWindow >= 1.0 {
            renderCallsPerSecond = Int(
                (Double(renderCalls - rateWindowRenderCalls) / rateWindow).rounded())
            rateWindowStart = now
            rateWindowRenderCalls = renderCalls
        }
        if stats.received != lastReceived {
            lastReceived = stats.received
            lastArrivalAt = now
        }

        let verdict = watchdog.evaluate(
            now: now, received: stats.received, played: stats.played, renderCalls: renderCalls)
        guard case .restart(let cause) = verdict else { return }
        let causeText = cause == .renderStopped
            ? "render callback stopped" : "rendering but nothing playable"
        logger.warning(
            "watchdog: packets arriving, nothing played for 1 s (\(causeText, privacy: .public)); engine running: \(self.output.isRunning), interrupted: \(self.isInterrupted)"
        )
        watchdog.recordRestart(now: now)
        startEngine(reason: "watchdog: \(causeText)")
    }

    private var packetsArrivingRecently: Bool {
        guard let lastArrivalAt else { return false }
        return elapsedSeconds() - lastArrivalAt <= Self.recentArrivalWindow
    }

    private func elapsedSeconds() -> TimeInterval {
        let elapsed = ContinuousClock.now - clockStart
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
    }

    // MARK: - Nonisolated callback factories

    /// Registers the system observers. The closures are formed here, in a
    /// nonisolated context, so they carry no main-actor isolation (a
    /// main-actor closure invoked on a framework queue traps); they parse
    /// the notification into a Sendable event and hand it to `deliver`.
    nonisolated private static func installObservers(
        appDidBecomeActive: Notification.Name,
        deliver: @escaping @Sendable (AudioSystemEvent) -> Void
    ) -> [any NSObjectProtocol] {
        let names: [Notification.Name] = [
            AVAudioSession.interruptionNotification,
            AVAudioSession.routeChangeNotification,
            AVAudioSession.mediaServicesWereLostNotification,
            AVAudioSession.mediaServicesWereResetNotification,
            .AVAudioEngineConfigurationChange,
            appDidBecomeActive,
        ]
        let center = NotificationCenter.default
        return names.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { notification in
                guard let event = parse(notification, appDidBecomeActive: appDidBecomeActive)
                else { return }
                deliver(event)
            }
        }
    }

    /// Hops each event to the main queue (FIFO, so events keep their order)
    /// and into the controller's main-actor state.
    nonisolated private static func makeDeliver(
        to controller: PlaybackController
    ) -> @Sendable (AudioSystemEvent) -> Void {
        { [weak controller] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    controller?.handle(event)
                }
            }
        }
    }

    nonisolated private static func parse(
        _ notification: Notification,
        appDidBecomeActive: Notification.Name
    ) -> AudioSystemEvent? {
        let info = notification.userInfo
        switch notification.name {
        case AVAudioSession.interruptionNotification:
            guard let rawType = info?[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: rawType)
            else { return nil }
            switch type {
            case .began:
                return .interruptionBegan(reason: info?[AVAudioSessionInterruptionReasonKey] as? UInt)
            case .ended:
                let rawOptions = info?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
                return .interruptionEnded(shouldResume: options.contains(.shouldResume))
            @unknown default:
                return nil
            }
        case AVAudioSession.routeChangeNotification:
            return .routeChanged(reason: info?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0)
        case AVAudioSession.mediaServicesWereLostNotification:
            return .mediaServicesLost
        case AVAudioSession.mediaServicesWereResetNotification:
            return .mediaServicesReset
        case .AVAudioEngineConfigurationChange:
            return .engineConfigurationChanged(
                engine: (notification.object as AnyObject?).map { ObjectIdentifier($0) })
        case appDidBecomeActive:
            return .appBecameActive
        default:
            return nil
        }
    }

    // MARK: - Log helpers

    private static func describeRouteChange(_ rawReason: UInt) -> String {
        switch AVAudioSession.RouteChangeReason(rawValue: rawReason) {
        case .newDeviceAvailable: "new device available"
        case .oldDeviceUnavailable: "old device unavailable"
        case .categoryChange: "category change"
        case .override: "override"
        case .wakeFromSleep: "wake from sleep"
        case .noSuitableRouteForCategory: "no suitable route"
        case .routeConfigurationChange: "route configuration change"
        default: "reason \(rawReason)"
        }
    }

    private static func describeCurrentRoute() -> String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard !outputs.isEmpty else { return "no output" }
        return outputs.map { "\($0.portName) [\($0.portType.rawValue)]" }.joined(separator: ", ")
    }
}

/// Owns the block-observer tokens and unregisters them on deallocation. Only
/// touched from the main actor (assignment) and `deinit`.
private final class ObserverTokens: @unchecked Sendable {
    var tokens: [any NSObjectProtocol] = []

    deinit {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
