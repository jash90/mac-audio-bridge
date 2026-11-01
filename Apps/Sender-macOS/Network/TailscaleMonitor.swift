import BridgeCore
import Foundation
import os

/// Polls `tailscale status --json` off the main actor (every 10 s while
/// active, plus on demand) and reports the parsed peers. Tolerates the CLI
/// missing, Tailscale stopped or logged out, and a hung CLI (killed after
/// 5 s). Never logs in or changes anything: read-only status.
///
/// State is confined to `queue`; results go out through the `@Sendable`
/// callback (the owner hops to the main actor).
final class TailscaleMonitor: @unchecked Sendable {
    enum State: Equatable, Sendable {
        case unknown
        /// No Tailscale CLI found.
        case notInstalled
        /// Installed but not connected ("Stopped", "NeedsLogin", an error).
        case notRunning(String)
        case running
    }

    private static let pollInterval: DispatchTimeInterval = .seconds(10)
    private static let processTimeout: TimeInterval = 5
    /// CLI locations: the standalone / Homebrew CLI, then the app bundle's
    /// binary (which acts as the CLI when given arguments).
    private static let candidates = [
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ]

    private let queue = DispatchQueue(label: "dev.jash90.MacAudioBridge.tailscale", qos: .utility)
    private let logger = Logger(subsystem: "dev.jash90.MacAudioBridge", category: "tailscale")
    private let onUpdate: @Sendable (State, TailscaleStatus?) -> Void

    // Confined to `queue`:
    private var timer: DispatchSourceTimer?
    private var inFlight = false

    init(onUpdate: @escaping @Sendable (State, TailscaleStatus?) -> Void) {
        self.onUpdate = onUpdate
    }

    deinit {
        timer?.cancel()
    }

    /// Polls every 10 s while active (immediately on activation).
    func setActive(_ active: Bool) {
        queue.async { [self] in
            if active {
                guard timer == nil else { return }
                let source = DispatchSource.makeTimerSource(queue: queue)
                source.schedule(deadline: .now(), repeating: Self.pollInterval, leeway: .seconds(1))
                source.setEventHandler(handler: Self.makePollHandler(monitor: self))
                source.resume()
                timer = source
            } else {
                timer?.cancel()
                timer = nil
            }
        }
    }

    func pollNow() {
        queue.async { [self] in
            poll()
        }
    }

    // MARK: - Queue-confined

    private func poll() {
        guard !inFlight else { return }
        guard let path = Self.candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            onUpdate(.notInstalled, nil)
            return
        }
        inFlight = true
        defer { inFlight = false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["status", "--json"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            logger.error("tailscale status failed to start: \(error.localizedDescription, privacy: .public)")
            onUpdate(.notRunning("CLI failed to start"), nil)
            return
        }
        let killer = DispatchWorkItem { [process] in
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.processTimeout, execute: killer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        guard let status = TailscaleStatus.parse(data) else {
            onUpdate(.notRunning("Tailscale is not running"), nil)
            return
        }
        onUpdate(status.isRunning ? .running : .notRunning(status.backendState), status)
    }

    nonisolated private static func makePollHandler(monitor: TailscaleMonitor) -> @Sendable () -> Void {
        { [weak monitor] in
            monitor?.poll()
        }
    }
}
