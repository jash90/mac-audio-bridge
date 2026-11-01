import BridgeCore
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

/// Reads what plays on this Mac. Since macOS 15.4 MediaRemote only answers
/// Now Playing queries from entitled processes, so this runs the vendored
/// mediaremote-adapter (ThirdParty/mediaremote-adapter, BSD-3-Clause): the
/// entitled `/usr/bin/perl` loads `MediaRemoteAdapter.framework` (embedded in
/// the app, not linked) and streams JSON lines on stdout. No permission is
/// needed. The child is restarted with a backoff when it exits.
///
/// State is confined to `queue`; samples go out through the `@Sendable`
/// callback (the owner hops to the main actor). Artwork is shrunk to a small
/// JPEG here, off the main thread, and only when it changes.
final class NowPlayingMonitor: @unchecked Sendable {
    struct Sample: Sendable {
        /// nil: nothing plays (no player reports a title).
        var snapshot: MediaRemoteAdapterStream.Snapshot?
        /// JPEG of at most `NowPlayingInfo.maxArtworkBytes`.
        var artwork: Data?
    }

    enum Event: Sendable {
        case sample(Sample)
        /// The adapter is missing from the bundle or keeps failing.
        case unavailable(String)
    }

    private static let perlPath = "/usr/bin/perl"
    private static let backoff: [TimeInterval] = [1, 2, 5, 15, 60]
    private static let artworkPixels = 200

    private let queue = DispatchQueue(label: "dev.jash90.MacAudioBridge.now-playing")
    private let logger = Logger(subsystem: "dev.jash90.MacAudioBridge", category: "now-playing")
    private let onEvent: @Sendable (Event) -> Void

    // Confined to `queue`:
    private var process: Process?
    private var generation: UInt64 = 0
    private var isRunning = false
    private var lineBuffer = Data()
    private var stream = MediaRemoteAdapterStream()
    private var failures = 0
    private var startedAt = Date.distantPast
    private var artworkSource: String?
    private var artworkJPEG: Data?

    init(onEvent: @escaping @Sendable (Event) -> Void) {
        self.onEvent = onEvent
    }

    func start() {
        queue.async { [self] in
            guard !isRunning else { return }
            isRunning = true
            launchOnQueue()
        }
    }

    /// Synchronous, so the child is gone before the app quits.
    func stop() {
        queue.sync { [self] in
            isRunning = false
            generation &+= 1
            process?.terminate()
            process = nil
        }
    }

    // MARK: - Queue-confined

    private func launchOnQueue() {
        guard isRunning else { return }
        guard let script = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
            let framework = Bundle.main.privateFrameworksURL?
                .appendingPathComponent("MediaRemoteAdapter.framework"),
            FileManager.default.fileExists(atPath: framework.path)
        else {
            onEvent(.unavailable("mediaremote-adapter is missing from the app bundle"))
            return
        }
        generation &+= 1
        lineBuffer.removeAll()
        stream = MediaRemoteAdapterStream()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: Self.perlPath)
        child.arguments = [script.path, framework.path, "stream", "--debounce=100"]
        let output = Pipe()
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        child.standardInput = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = Self.makeReadHandler(
            monitor: self, generation: generation)
        child.terminationHandler = Self.makeTerminationHandler(monitor: self, generation: generation)
        do {
            try child.run()
        } catch {
            logger.error("Could not start the adapter: \(error.localizedDescription, privacy: .public)")
            scheduleRestart(generation: generation)
            return
        }
        process = child
        startedAt = Date()
    }

    private func handleOutput(_ data: Data, generation: UInt64) {
        guard generation == self.generation else { return }
        lineBuffer.append(data)
        var sample: Sample?
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let line = lineBuffer[lineBuffer.startIndex..<newline]
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            do {
                let snapshot = try stream.consume(line: Data(line))
                sample = Sample(snapshot: snapshot, artwork: artwork(for: snapshot))
            } catch {
                logger.debug("Skipped an adapter line")
            }
        }
        if let sample {
            // A healthy stream resets the backoff.
            failures = 0
            onEvent(.sample(sample))
        }
    }

    private func handleTermination(status: Int32, generation: UInt64) {
        guard generation == self.generation else { return }
        process = nil
        // Whatever it reported is no longer known.
        onEvent(.sample(Sample(snapshot: nil, artwork: nil)))
        guard isRunning else { return }
        logger.notice("Adapter exited with status \(status)")
        if Date().timeIntervalSince(startedAt) > 60 { failures = 0 }
        failures += 1
        if failures >= Self.backoff.count {
            onEvent(.unavailable("Now Playing info is unavailable (adapter exited \(status))"))
        }
        scheduleRestart(generation: generation)
    }

    private func scheduleRestart(generation: UInt64) {
        let delay = Self.backoff[min(failures, Self.backoff.count - 1)]
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            guard isRunning, generation == self.generation else { return }
            launchOnQueue()
        }
    }

    /// The shrunk artwork, recomputed only when the adapter's data changes.
    private func artwork(for snapshot: MediaRemoteAdapterStream.Snapshot?) -> Data? {
        let source = snapshot?.artworkBase64
        if source != artworkSource {
            artworkSource = source
            artworkJPEG = source.flatMap { Data(base64Encoded: $0) }.flatMap(Self.thumbnail)
        }
        return artworkJPEG
    }

    private static func thumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var pixels = artworkPixels
        while pixels >= 64 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output, UTType.jpeg.identifier as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(
                destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            if output.length <= NowPlayingInfo.maxArtworkBytes { return output as Data }
            pixels /= 2
        }
        return nil
    }

    // MARK: - Nonisolated factories (Foundation calls them on its own threads)

    nonisolated private static func makeReadHandler(
        monitor: NowPlayingMonitor, generation: UInt64
    ) -> @Sendable (FileHandle) -> Void {
        { [weak monitor] handle in
            let data = handle.availableData
            guard let monitor else { return }
            if data.isEmpty {
                // End of file: the child is gone (termination handles it).
                handle.readabilityHandler = nil
                return
            }
            monitor.queue.async {
                monitor.handleOutput(data, generation: generation)
            }
        }
    }

    nonisolated private static func makeTerminationHandler(
        monitor: NowPlayingMonitor, generation: UInt64
    ) -> @Sendable (Process) -> Void {
        { [weak monitor] child in
            let status = child.terminationStatus
            guard let monitor else { return }
            monitor.queue.async {
                monitor.handleTermination(status: status, generation: generation)
            }
        }
    }
}
