import Foundation

/// The parts of `tailscale status --json` the Mac uses: its own tailnet
/// addresses and the peers (iOS peers become receiver candidates "via
/// Tailscale"). Pure parsing; running the CLI is the app's job.
///
/// Path to a peer: `CurAddr` is the direct UDP endpoint (NAT traversal
/// succeeded); an empty `CurAddr` on an active peer means traffic goes
/// through the DERP relay named in `Relay` (TCP/HTTPS — more latency and
/// jitter). An inactive peer has no current path.
public struct TailscaleStatus: Equatable, Sendable {
    public struct Peer: Equatable, Sendable, Identifiable {
        public var id: String
        /// First label of the MagicDNS name ("iphone171"), else the host name.
        public var name: String
        /// Full MagicDNS name without the trailing dot.
        public var dnsName: String
        public var os: String
        public var addresses: [String]
        public var online: Bool
        public var active: Bool
        /// Direct endpoint ("192.168.10.131:41641"), "" when none.
        public var currentAddress: String
        /// Home / current DERP region ("waw").
        public var relay: String

        public var isIOS: Bool { os.lowercased() == "ios" }

        public var path: Path {
            if !currentAddress.isEmpty { return .direct }
            return active ? .relay : .unknown
        }

        /// The address to stream to: IPv4 first.
        public var preferredAddress: String? { addresses.first }
    }

    public enum Path: String, Sendable, Equatable {
        case direct
        case relay
        /// No traffic recently: Tailscale has not picked a path yet.
        case unknown
    }

    /// "Running" when connected; "Stopped", "NeedsLogin", … otherwise.
    public var backendState: String
    public var selfAddresses: [String]
    public var selfName: String
    public var peers: [Peer]

    public var isRunning: Bool { backendState == "Running" }

    public var iosPeers: [Peer] { peers.filter(\.isIOS) }

    /// The peer owning `address` (one of its tailnet IPs).
    public func peer(owning address: String) -> Peer? {
        peers.first { $0.addresses.contains(address) }
    }

    public init(backendState: String, selfAddresses: [String], selfName: String, peers: [Peer]) {
        self.backendState = backendState
        self.selfAddresses = selfAddresses
        self.selfName = selfName
        self.peers = peers
    }

    private struct Raw: Decodable {
        var BackendState: String?
        var Self_: RawPeer?
        var Peer: [String: RawPeer]?

        enum CodingKeys: String, CodingKey {
            case BackendState
            case Self_ = "Self"
            case Peer
        }
    }

    private struct RawPeer: Decodable {
        var ID: String?
        var HostName: String?
        var DNSName: String?
        var OS: String?
        var TailscaleIPs: [String]?
        var Online: Bool?
        var Active: Bool?
        var CurAddr: String?
        var Relay: String?
    }

    /// Parses the CLI's JSON; nil when it is not a status document.
    public static func parse(_ data: Data) -> TailscaleStatus? {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data), let state = raw.BackendState else {
            return nil
        }
        let peers = (raw.Peer ?? [:])
            .map { key, value in makePeer(key: key, value) }
            .sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
        return TailscaleStatus(
            backendState: state,
            selfAddresses: InterfaceAddresses.ordered(raw.Self_?.TailscaleIPs ?? []),
            selfName: raw.Self_.map { shortName($0) } ?? "",
            peers: peers)
    }

    private static func makePeer(key: String, _ raw: RawPeer) -> Peer {
        Peer(
            id: raw.ID ?? key,
            name: shortName(raw),
            dnsName: (raw.DNSName ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ".")),
            os: raw.OS ?? "",
            addresses: InterfaceAddresses.ordered(raw.TailscaleIPs ?? []),
            online: raw.Online ?? false,
            active: raw.Active ?? false,
            currentAddress: raw.CurAddr ?? "",
            relay: raw.Relay ?? "")
    }

    /// "iphone171" from "iphone171.tail77985b.ts.net." (iOS reports the
    /// useless host name "localhost").
    private static func shortName(_ raw: RawPeer) -> String {
        if let dns = raw.DNSName, let label = dns.split(separator: ".").first, !label.isEmpty {
            return String(label)
        }
        return raw.HostName ?? "?"
    }
}
