import AppKit
import BridgeCore
import Foundation

/// Playback control of this Mac from the phone (Mac side): carries out
/// `media` commands (`MediaCommandSender`) and reports what plays
/// (`NowPlayingMonitor`) as `NowPlayingInfo`, throttled by
/// `NowPlayingThrottle`, through the `broadcast` closure (the controller sends
/// it to every phone). The menu observes the published state.
@MainActor
final class MacMediaControl: ObservableObject {
    /// What plays on this Mac (nil: nothing, or not known).
    @Published private(set) var nowPlaying: NowPlayingInfo?
    @Published private(set) var method: MediaCommandMethod
    /// Why Now Playing info is not available (nil: it is).
    @Published private(set) var infoProblem: String?

    private var throttle = NowPlayingThrottle()
    private var monitor: NowPlayingMonitor?
    private var latest: NowPlayingMonitor.Sample?
    private var appNames: [String: String] = [:]
    private var broadcast: ((NowPlayingInfo?) -> Void)?
    private var flushTask: Task<Void, Never>?
    private var methodLoop: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?

    init() {
        method = MediaCommandSender.method
    }

    /// Starts reading Now Playing; `broadcast` gets every value to send.
    func start(broadcast: @escaping (NowPlayingInfo?) -> Void) {
        guard monitor == nil else { return }
        self.broadcast = broadcast
        let monitor = Self.makeMonitor(control: self)
        self.monitor = monitor
        monitor.start()
        terminationObserver = Self.observeTermination(monitor: monitor)
        // The fallback's permission can be granted at any time.
        methodLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.refreshMethod()
            }
        }
    }

    /// The value a phone that just connected should get first (`.none`:
    /// nothing observed yet).
    var currentForNewPhone: NowPlayingInfo?? { throttle.current }

    func perform(_ command: MediaCommand) {
        MediaCommandSender.send(command, isPlaying: latest?.snapshot?.isPlaying)
        refreshMethod()
    }

    func requestAccessibility() {
        MediaCommandSender.requestAccessibility()
    }

    // MARK: - Private

    private func refreshMethod() {
        let current = MediaCommandSender.method
        guard current != method else { return }
        method = current
        republish()
    }

    private func handle(_ event: NowPlayingMonitor.Event) {
        switch event {
        case .sample(let sample):
            latest = sample
            if infoProblem != nil { infoProblem = nil }
        case .unavailable(let reason):
            latest = nil
            infoProblem = reason
        }
        republish()
    }

    private func republish() {
        let info = latest?.snapshot.map(makeInfo)
        if nowPlaying != info { nowPlaying = info }
        switch throttle.offer(info, now: ProcessInfo.processInfo.systemUptime) {
        case .send(let value):
            broadcast?(value)
        case .deferred(let until):
            scheduleFlush(at: until)
        case .unchanged:
            break
        }
    }

    private func scheduleFlush(at uptime: TimeInterval) {
        guard flushTask == nil else { return }
        let delay = max(0, uptime - ProcessInfo.processInfo.systemUptime)
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            self.flushTask = nil
            if let value = self.throttle.due(now: ProcessInfo.processInfo.systemUptime) {
                self.broadcast?(value)
            }
        }
    }

    private func makeInfo(_ snapshot: MediaRemoteAdapterStream.Snapshot) -> NowPlayingInfo {
        NowPlayingInfo(
            title: snapshot.title ?? "",
            artist: snapshot.artist,
            album: snapshot.album,
            app: snapshot.bundleIdentifier.flatMap(appName),
            isPlaying: snapshot.isPlaying,
            duration: snapshot.duration.flatMap { $0 > 0 ? $0 : nil },
            elapsed: snapshot.elapsed(at: Date()),
            artwork: latest?.artwork,
            canControl: method.canControl)
    }

    /// "Spotify" for com.spotify.client (cached).
    private func appName(_ bundleID: String) -> String? {
        if let cached = appNames[bundleID] { return cached }
        let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map {
                FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
            }
        if let name { appNames[bundleID] = name }
        return name
    }

    // MARK: - Nonisolated factories (callbacks arrive on other threads)

    nonisolated private static func makeMonitor(control: MacMediaControl) -> NowPlayingMonitor {
        NowPlayingMonitor { [weak control] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { control?.handle(event) }
            }
        }
    }

    /// Stops the adapter child before the app exits.
    nonisolated private static func observeTermination(monitor: NowPlayingMonitor) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            monitor.stop()
        }
    }
}
