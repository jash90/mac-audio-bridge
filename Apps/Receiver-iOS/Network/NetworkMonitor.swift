import Foundation
import Network

/// Watches the phone's network path (`NWPathMonitor`): which interface
/// carries traffic and whether it is expensive (cellular, a personal
/// hotspot). An expensive path selects the Mac's WAN profile even when the
/// Mac reaches the phone through a tailnet address it would otherwise treat
/// as the LAN. Updates go out through the `@Sendable` callback (the owner
/// hops to the main actor).
final class NetworkMonitor: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        /// "Wi-Fi", "Cellular", "Wired", "Other", "Offline".
        var network: String
        var isExpensive: Bool
    }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dev.jash90.MacAudioBridge.network-monitor", qos: .utility)
    private let onUpdate: @Sendable (Snapshot) -> Void

    init(onUpdate: @escaping @Sendable (Snapshot) -> Void) {
        self.onUpdate = onUpdate
    }

    deinit {
        monitor.cancel()
    }

    func start() {
        monitor.pathUpdateHandler = Self.makePathHandler(monitor: self)
        monitor.start(queue: queue)
    }

    private func handle(_ path: NWPath) {
        onUpdate(Self.snapshot(path))
    }

    nonisolated private static func makePathHandler(monitor: NetworkMonitor) -> @Sendable (NWPath) -> Void {
        { [weak monitor] path in
            monitor?.handle(path)
        }
    }

    /// With a VPN (Tailscale) up the path runs over the tunnel ("other"):
    /// the underlying interface is the first available physical one.
    nonisolated static func snapshot(_ path: NWPath) -> Snapshot {
        guard path.status == .satisfied else { return Snapshot(network: "Offline", isExpensive: false) }
        let physical = path.availableInterfaces.first { $0.type != .other && $0.type != .loopback }?.type
        let type: NWInterface.InterfaceType? = [.wifi, .cellular, .wiredEthernet]
            .first(where: path.usesInterfaceType) ?? physical
        let network: String
        switch type {
        case .wifi?: network = "Wi-Fi"
        case .cellular?: network = "Cellular"
        case .wiredEthernet?: network = "Wired"
        default: network = "Other"
        }
        return Snapshot(network: network, isExpensive: path.isExpensive || type == .cellular)
    }
}
