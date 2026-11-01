import Foundation

/// Transport profile of the audio stream. `.lan` is the M2.8 + Opus layout
/// tuned for Wi-Fi; `.wan` is used whenever the audio path leaves the LAN
/// (a tailnet / public remote address, or the phone reports an expensive —
/// cellular — path): fewer, bigger datagrams, Opus 128, bounded redundancy,
/// a deeper jitter buffer and a relaxed keepalive.
///
/// The sender decides and marks every datagram with its profile
/// (`AudioDatagram.profile`); the receiver follows the mark (jitter-buffer
/// floor, keepalive cadence), so both ends switch on the same datagram and
/// no restart is needed. A switch keeps the frame sequence continuous: the
/// buffer is retuned in place (`JitterBuffer.retune`), never reset.
///
/// WAN layout, chosen by overhead vs latency (Opus 128 = 80 B per 5 ms
/// frame; per-datagram cost over Tailscale ≈ 88 B: inner IPv4/UDP 28 +
/// WireGuard 32 + outer IPv4/UDP 28, plus our 24 B header and 3 B per
/// entry), each frame sent three times (primary + 2 copies):
///
///     frames/datagram   datagram   wire B/s   MB/h   loss run covered   added latency
///          1 (5 ms)       273 B     72 200    260         10 ms              0
///          2 (10 ms)      522 B     61 000    220         20 ms             +5 ms
///          4 (20 ms)     1020 B     55 400    199         40 ms            +15 ms
///
/// 4 frames per datagram (one datagram per 20 ms, the VoIP ptime) with the
/// previous two datagrams' frames repeated (offsets 4...11) is the only
/// layout that meets ≤ ~200 MB/h with N = 2 redundancy, still fits the 1200 B
/// budget (Tailscale MTU 1280) and covers the longest loss runs; its 15 ms
/// is small next to the 120–200 ms WAN buffer floor.
public enum StreamProfile: UInt8, Sendable, Equatable, Codable, CaseIterable {
    case lan = 0
    case wan = 1

    public var displayName: String {
        switch self {
        case .lan: "Local network"
        case .wan: "Internet profile"
        }
    }

    /// Stats name ("lan" / "wan").
    public var statsName: String {
        switch self {
        case .lan: "lan"
        case .wan: "wan"
        }
    }

    /// Datagram layout for frames of `codec` (PCM16 frames never group:
    /// one 960 B frame per datagram).
    public func layout(for codec: AudioCodec) -> DatagramLayout {
        switch (self, codec) {
        case (.wan, .opus): .wan
        default: .lan
        }
    }

    /// What is actually encoded for a requested quality: on WAN at most
    /// Opus 128 (a lower Opus pick would be kept), never PCM.
    public func effectiveQuality(_ requested: StreamQuality) -> StreamQuality {
        switch self {
        case .lan: requested
        case .wan: .opus128
        }
    }

    /// Why the effective quality differs from the requested one (nil = same).
    public func qualityNote(requested: StreamQuality) -> String? {
        let effective = effectiveQuality(requested)
        guard effective != requested else { return nil }
        if requested == .pcm {
            return "PCM is not used over the Internet — streaming \(effective.displayName)"
        }
        return "Over the Internet: \(effective.displayName) to save data"
    }

    /// Receiver keepalive cadence: 20 ms on the LAN keeps the phone's Wi-Fi
    /// radio out of power save; over the Internet that would cost ~19 MB/h
    /// of upload, so 200 ms (the deeper buffer absorbs the bursts).
    public var keepaliveInterval: TimeInterval {
        switch self {
        case .lan: 0.020
        case .wan: 0.200
        }
    }

    /// Sender liveness timeout: no keepalive for this long recreates the
    /// connection (and lets the failover pick another path).
    public var livenessTimeout: TimeInterval {
        switch self {
        case .lan: ReceiverLiveness.defaultTimeout
        case .wan: 5
        }
    }

    /// Jitter-buffer configuration for a latency mode on this profile.
    public func jitterConfig(_ mode: JitterLatencyMode) -> JitterBufferConfig {
        var config = JitterBufferConfig.latency(mode)
        guard self == .wan else { return config }
        let minMs: Double
        let maxMs: Double
        switch mode {
        case .low:
            minMs = 120
            maxMs = 400
            config.delayWindowSeconds = 20
        case .balanced:
            minMs = 140
            maxMs = 600
        case .safe:
            minMs = 200
            maxMs = 900
        }
        config.minTargetFrames = AudioFormat.frames(milliseconds: minMs)
        config.maxTargetFrames = AudioFormat.frames(milliseconds: maxMs)
        config.overflowFrames = config.maxTargetFrames + AudioFormat.frames(milliseconds: 60)
        // A datagram delivers 4 frames at once: the depth swings by 20 ms
        // per arrival, which must not look like excess latency to trim.
        config.latencyTrimSlackFrames = AudioFormat.frames(milliseconds: 40)
        config.lossHorizonFrames = DatagramLayout.wan.maxOffset + 2
        return config
    }

    /// The sender's decision. WAN when the phone reports an expensive
    /// (cellular) path, when the resolved remote address is not on the LAN
    /// (tailnet or public), or — before resolution — when the target is a
    /// host name (MagicDNS names are tailnet peers).
    public static func decide(
        remoteKind: NetworkAddressKind?, targetIsHostName: Bool, phoneOnExpensivePath: Bool
    ) -> StreamProfile {
        if phoneOnExpensivePath { return .wan }
        switch remoteKind {
        case .tailnet?, .other?: return .wan
        case .lan?, .loopback?: return .lan
        case nil: return targetIsHostName ? .wan : .lan
        }
    }
}

/// Where the audio actually travels, for the UI and the stats lines.
public enum StreamPath: String, Sendable, Equatable, Codable {
    case local
    case tailscaleDirect
    case tailscaleRelay
    /// Over the tailnet, direct vs relay not known (yet).
    case tailscale
    case internet

    public var displayName: String {
        switch self {
        case .local: "Wi-Fi"
        case .tailscaleDirect: "Tailscale direct"
        case .tailscaleRelay: "Tailscale relay"
        case .tailscale: "Tailscale"
        case .internet: "Internet"
        }
    }

    public var isTailscale: Bool {
        switch self {
        case .tailscaleDirect, .tailscaleRelay, .tailscale: true
        case .local, .internet: false
        }
    }

    /// From the remote address's kind and, for a tailnet address, the
    /// Tailscale peer's path.
    public static func classify(remoteKind: NetworkAddressKind?, tailscalePath: TailscaleStatus.Path?) -> StreamPath {
        switch remoteKind {
        case .tailnet?:
            switch tailscalePath {
            case .direct?: return .tailscaleDirect
            case .relay?: return .tailscaleRelay
            case .unknown?, nil: return .tailscale
            }
        case .other?: return .internet
        case .lan?, .loopback?, nil: return .local
        }
    }
}

/// Bytes on the wire: the per-datagram header overhead on each path, the
/// steady-state rate of each profile, and a rolling "≈ MB/h" meter.
public enum StreamDataRate {
    /// IPv4 + UDP.
    public static let ipUDPBytes = 28
    /// WireGuard data message: 16 B header + 16 B Poly1305 tag.
    public static let wireGuardBytes = 32
    /// DERP relays wrap WireGuard in TLS over TCP: ≈ 5 B TLS record + 16 B
    /// tag + 20 B TCP header (an estimate; coalescing lowers it).
    public static let derpBytes = 41

    /// Header bytes per datagram on `path`, on top of the UDP payload.
    public static func overheadPerDatagram(_ path: StreamPath) -> Int {
        switch path {
        case .local, .internet: ipUDPBytes
        case .tailscaleDirect, .tailscale: ipUDPBytes + wireGuardBytes + ipUDPBytes
        case .tailscaleRelay: ipUDPBytes + wireGuardBytes + derpBytes + ipUDPBytes
        }
    }

    public struct Estimate: Equatable, Sendable {
        public var datagramsPerSecond: Double
        /// UDP payload bytes per second (what the app hands the socket).
        public var payloadBytesPerSecond: Double
        /// Including the per-datagram overhead of the path.
        public var wireBytesPerSecond: Double
        public var largestDatagram: Int

        public var megabytesPerHour: Double { wireBytesPerSecond * 3600 / 1_000_000 }
        public var kilobitsPerSecond: Double { wireBytesPerSecond * 8 / 1000 }
    }

    /// Steady-state rate of `quality` (as encoded on `profile`) on `path`,
    /// measured by running the real packer over CBR-sized frames.
    public static func estimate(quality requested: StreamQuality, profile: StreamProfile, path: StreamPath) -> Estimate {
        let quality = profile.effectiveQuality(requested)
        let payload = quality.opusBitrate.map { $0 / 8 * AudioFormat.frameDurationMs / 1000 }
            ?? AudioFormat.pcm16FrameBytes
        var packer = RedundancyPacker()
        packer.profile = profile
        let warmUp = 64
        let measured = 400
        var datagrams = 0
        var bytes = 0
        var largest = 0
        for frame in 0..<(warmUp + measured) {
            let packet = AudioPacket(
                codec: quality.codec, sequence: UInt32(frame),
                sampleTime: UInt64(frame * AudioFormat.samplesPerFrame),
                payload: Data(count: payload))
            let out = packer.pack(packet)
            guard frame >= warmUp else { continue }
            datagrams += out.count
            bytes += out.reduce(0) { $0 + $1.count }
            largest = max(largest, out.map(\.count).max() ?? 0)
        }
        let seconds = Double(measured) * AudioFormat.frameDuration
        let perSecond = Double(datagrams) / seconds
        let payloadRate = Double(bytes) / seconds
        return Estimate(
            datagramsPerSecond: perSecond,
            payloadBytesPerSecond: payloadRate,
            wireBytesPerSecond: payloadRate + perSecond * Double(overheadPerDatagram(path)),
            largestDatagram: largest)
    }
}

/// Session byte counter with a rolling rate: feed it once per second with
/// the datagrams and payload bytes of that second.
public struct DataUsageMeter: Equatable, Sendable {
    public static let defaultWindow = 10

    /// Wire bytes (payload + path overhead) since `reset`.
    public private(set) var totalBytes: Int = 0
    private var recent: [Int] = []
    private let window: Int

    public init(window: Int = DataUsageMeter.defaultWindow) {
        self.window = max(window, 1)
    }

    public mutating func reset() {
        totalBytes = 0
        recent.removeAll()
    }

    /// One second's traffic on `path`.
    public mutating func record(datagrams: Int, payloadBytes: Int, path: StreamPath) {
        let wire = payloadBytes + datagrams * StreamDataRate.overheadPerDatagram(path)
        totalBytes += wire
        recent.append(wire)
        if recent.count > window {
            recent.removeFirst(recent.count - window)
        }
    }

    /// ≈ MB per hour at the rate of the last `window` seconds.
    public var megabytesPerHour: Double {
        guard !recent.isEmpty else { return 0 }
        let perSecond = Double(recent.reduce(0, +)) / Double(recent.count)
        return (perSecond * 3600 / 1_000_000 * 10).rounded() / 10
    }

    public var totalMegabytes: Double {
        (Double(totalBytes) / 1_000_000 * 10).rounded() / 10
    }
}

/// The receiver's 16-byte keepalive ("MABK" + flags + zeros), sent back to
/// the sender on the audio path (its liveness signal).
public enum ReceiverKeepalive {
    public static let length = 16
    public static let magic: [UInt8] = [0x4D, 0x41, 0x42, 0x4B]

    public struct Flags: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        /// The phone's network path is expensive (cellular / hotspot).
        public static let expensivePath = Flags(rawValue: 1 << 0)
    }

    public static func encode(_ flags: Flags) -> Data {
        var data = Data(count: length)
        for (index, byte) in magic.enumerated() {
            data[index] = byte
        }
        data[magic.count] = flags.rawValue
        return data
    }

    /// The flags of a keepalive; nil when `data` is not one.
    public static func decode(_ data: Data) -> Flags? {
        guard data.count == length, data.prefix(magic.count).elementsEqual(magic) else { return nil }
        return Flags(rawValue: data[data.startIndex + magic.count])
    }
}

/// Receiver side: follows the profile marked in the datagrams, but only from
/// the newest datagram seen — reordered stragglers of the previous profile
/// (the old path is slower or faster than the new one) must not flip it
/// back and forth.
public struct ProfileFollower: Equatable, Sendable {
    public private(set) var profile: StreamProfile = .lan
    private var newestSequence: UInt32?

    public init() {}

    /// A new stream (another source, or a discontinuity): sequences restart.
    public mutating func reset() {
        newestSequence = nil
    }

    /// Feeds one datagram's mark; returns the new profile when it changed.
    public mutating func observe(_ marked: StreamProfile, sequence: UInt32) -> StreamProfile? {
        if let newest = newestSequence, !sequenceIsAfter(sequence, newest) {
            return nil
        }
        newestSequence = sequence
        guard marked != profile else { return nil }
        profile = marked
        return marked
    }
}
