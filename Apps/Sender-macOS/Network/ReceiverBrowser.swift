import BridgeCore
import Foundation
import Network
import dnssd
import os

/// Keeps a live list of iOS receivers advertising `_macaudiobridge._udp` in
/// the local domain. Runs from launch for the whole app lifetime (owned by
/// `SenderController`, never by a view) and restarts itself after a failure.
/// All browser state is confined to `queue`; results are delivered through
/// `@Sendable` callbacks that the owner hops to the main actor.
final class ReceiverBrowser: @unchecked Sendable {
    enum Status: Equatable, Sendable {
        case starting
        case browsing
        /// macOS Local Network privacy blocks Bonjour for this app.
        case localNetworkDenied
        case failed(String)
    }

    private static let restartDelay: DispatchTimeInterval = .seconds(2)

    private let queue = DispatchQueue(label: "dev.jash90.MacAudioBridge.receiver-browser")
    private let logger = Logger(subsystem: "dev.jash90.MacAudioBridge", category: "receiver-browser")
    private let onResults: @Sendable ([String]) -> Void
    private let onStatus: @Sendable (Status) -> Void

    // Confined to `queue`:
    private var browser: NWBrowser?
    private var generation: UInt64 = 0

    init(
        onResults: @escaping @Sendable ([String]) -> Void,
        onStatus: @escaping @Sendable (Status) -> Void
    ) {
        self.onResults = onResults
        self.onStatus = onStatus
    }

    func start() {
        queue.async { [self] in
            startBrowserOnQueue()
        }
    }

    func stop() {
        queue.async { [self] in
            generation &+= 1
            browser?.cancel()
            browser = nil
        }
    }

    // MARK: - Queue-confined

    private func startBrowserOnQueue() {
        browser?.cancel()
        generation &+= 1
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: ReceiverService.type, domain: ReceiverService.domain)
        let newBrowser = NWBrowser(for: descriptor, using: NWParameters())
        newBrowser.stateUpdateHandler = Self.makeStateHandler(browser: self, generation: generation)
        newBrowser.browseResultsChangedHandler = Self.makeResultsHandler(
            browser: self, generation: generation)
        browser = newBrowser
        onStatus(.starting)
        newBrowser.start(queue: queue)
    }

    private func handleState(_ state: NWBrowser.State, generation: UInt64) {
        guard generation == self.generation else { return }
        switch state {
        case .ready:
            onStatus(.browsing)
        case .waiting(let error):
            logger.info("Browser waiting: \(error.localizedDescription, privacy: .public)")
            onStatus(Self.isPolicyDenied(error) ? .localNetworkDenied : .failed(error.localizedDescription))
        case .failed(let error):
            logger.error("Browser failed: \(error.localizedDescription, privacy: .public)")
            onStatus(Self.isPolicyDenied(error) ? .localNetworkDenied : .failed(error.localizedDescription))
            onResults([])
            browser?.cancel()
            browser = nil
            queue.asyncAfter(deadline: .now() + Self.restartDelay) { [self] in
                guard generation == self.generation, browser == nil else { return }
                startBrowserOnQueue()
            }
        default:
            break
        }
    }

    private func handleResults(_ results: Set<NWBrowser.Result>, generation: UInt64) {
        guard generation == self.generation else { return }
        var names = Set<String>()
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            var version: String?
            if case .bonjour(let txt) = result.metadata {
                version = txt[ReceiverService.versionKey]
            }
            guard ReceiverService.isCompatible(version: version) else { continue }
            names.insert(name)
        }
        onResults(names.sorted())
    }

    // MARK: - Nonisolated factories (capture only Sendable state)

    nonisolated private static func makeStateHandler(
        browser: ReceiverBrowser, generation: UInt64
    ) -> @Sendable (NWBrowser.State) -> Void {
        { [weak browser] state in
            browser?.handleState(state, generation: generation)
        }
    }

    nonisolated private static func makeResultsHandler(
        browser: ReceiverBrowser, generation: UInt64
    ) -> @Sendable (Set<NWBrowser.Result>, Set<NWBrowser.Result.Change>) -> Void {
        { [weak browser] results, _ in
            browser?.handleResults(results, generation: generation)
        }
    }

    private static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error {
            return code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied)
        }
        return false
    }
}
