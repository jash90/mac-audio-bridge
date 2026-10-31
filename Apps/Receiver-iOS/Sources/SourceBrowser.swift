import BridgeCore
import Foundation
import Network
import dnssd
import os

/// Keeps a live list of Macs advertising `_macaudiosrc._tcp` (TXT `v`, `id`).
/// Owned by `SourcesModel` for the app's lifetime; restarts itself after a
/// failure. State is confined to `queue`; results go out through `@Sendable`
/// callbacks that the owner hops to the main actor.
final class SourceBrowser: @unchecked Sendable {
    struct Found: Sendable, Equatable {
        /// The Mac's persisted source UUID (TXT `id`).
        let id: String
        /// Bonjour instance name (the Mac's computer name).
        let name: String
        let endpoint: NWEndpoint
    }

    enum Status: Equatable, Sendable {
        case starting
        case browsing
        case localNetworkDenied
        case failed(String)
    }

    private static let restartDelay: TimeInterval = 2

    private let queue = DispatchQueue(label: "dev.jash90.MacAudioBridge.source-browser")
    private let logger = Logger(subsystem: "dev.jash90.MacAudioBridge", category: "source-browser")
    private let onResults: @Sendable ([Found]) -> Void
    private let onStatus: @Sendable (Status) -> Void

    // Confined to `queue`:
    private var browser: NWBrowser?
    private var generation: UInt64 = 0

    init(
        onResults: @escaping @Sendable ([Found]) -> Void,
        onStatus: @escaping @Sendable (Status) -> Void
    ) {
        self.onResults = onResults
        self.onStatus = onStatus
    }

    func start() {
        queue.async { [self] in
            startOnQueue()
        }
    }

    // MARK: - Queue-confined

    private func startOnQueue() {
        browser?.cancel()
        generation &+= 1
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: ControlProtocol.serviceType, domain: ControlProtocol.domain)
        let newBrowser = NWBrowser(for: descriptor, using: NWParameters())
        newBrowser.stateUpdateHandler = Self.makeStateHandler(browser: self, generation: generation)
        newBrowser.browseResultsChangedHandler = Self.makeResultsHandler(browser: self, generation: generation)
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
            onStatus(Self.isPolicyDenied(error) ? .localNetworkDenied : .failed(error.localizedDescription))
        case .failed(let error):
            logger.error("Source browser failed: \(error.localizedDescription, privacy: .public)")
            onStatus(Self.isPolicyDenied(error) ? .localNetworkDenied : .failed(error.localizedDescription))
            onResults([])
            browser?.cancel()
            browser = nil
            queue.asyncAfter(deadline: .now() + Self.restartDelay) { [self] in
                guard generation == self.generation, browser == nil else { return }
                startOnQueue()
            }
        default:
            break
        }
    }

    private func handleResults(_ results: Set<NWBrowser.Result>, generation: UInt64) {
        guard generation == self.generation else { return }
        var found: [String: Found] = [:]
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint,
                case .bonjour(let txt) = result.metadata,
                let id = txt[ControlProtocol.idKey], !id.isEmpty,
                ControlProtocol.isCompatible(txtVersion: txt[ControlProtocol.versionKey])
            else { continue }
            // A Mac seen on several interfaces is one source.
            if found[id] == nil {
                found[id] = Found(id: id, name: name, endpoint: result.endpoint)
            }
        }
        onResults(found.values.sorted { $0.id < $1.id })
    }

    // MARK: - Nonisolated factories

    nonisolated private static func makeStateHandler(
        browser: SourceBrowser, generation: UInt64
    ) -> @Sendable (NWBrowser.State) -> Void {
        { [weak browser] state in
            browser?.handleState(state, generation: generation)
        }
    }

    nonisolated private static func makeResultsHandler(
        browser: SourceBrowser, generation: UInt64
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
