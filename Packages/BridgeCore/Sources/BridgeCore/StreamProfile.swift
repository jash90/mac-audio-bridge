import Foundation

/// Transport profile of the audio stream. `.lan` is the M2.8 + Opus layout
/// tuned for Wi-Fi; `.wan` is used whenever the audio path leaves the LAN
/// (a tailnet / public remote address, or the phone reports an expensive —
/// cellular — path): one 20 ms Opus frame per datagram at the user's
/// `InternetQuality`, two low-rate redundant copies, a deeper jitter buffer
/// and a relaxed keepalive.
///
/// The sender decides and marks every datagram with its profile
/// (`AudioDatagram.profile`); the receiver follows the mark (jitter-buffer
/// floor, keepalive cadence), so both ends switch on the same datagram and
/// no restart is needed. A switch keeps the frame sequence continuous: the
/// buffer is retuned in place (`JitterBuffer.retune`), never reset.
///
/// WAN layout (docs/research/compression.md, "best implementation" B + C):
/// one datagram per 20 ms as before, now carrying ONE 20 ms Opus frame
/// (instead of four 5 ms frames — at ≤ 96 kbit/s 5 ms frames cost a whole
/// bitrate step) plus copies of the previous two frames from a second
/// encoder at 24 kbit/s (instead of full-rate copies, which were 71 % of the
/// bytes). Per-datagram cost over Tailscale ≈ 88 B (inner IPv4/UDP 28 +
/// WireGuard 32 + outer IPv4/UDP 28) on top of our 24 B header and 3 B per
/// entry:
///
///     InternetQuality     datagram   MB/h (Tailscale)   loss run covered   added latency
///     High     Opus 128     473 B        101                40 ms              0
///     Standard Opus  96     393 B         87                40 ms              0
///     Saver    Opus  64     313 B         72                40 ms              0
///     Floor    Opus  48     273 B         65                40 ms              0
///
/// The 20 ms frame waits as long as the old 4 × 5 ms group did, so the
/// latency is unchanged; the 120–200 ms WAN buffer floor dominates anyway.
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

    /// What is encoded on this profile: the LAN pick on the LAN, the
    /// Internet quality's Opus rung (20 ms frames, low-rate copies) on WAN.
    public func encoding(lan: StreamQuality, internet: InternetQuality) -> StreamEncoding {
        switch self {
        case .lan: .lan(lan)
        case .wan: .wan(internet)
        }
    }

    /// The quality actually encoded (see `encoding(lan:internet:)`).
    public func effectiveQuality(lan: StreamQuality, internet: InternetQuality) -> StreamQuality {
        encoding(lan: lan, internet: internet).quality
    }

    /// Why the stream runs another quality than the LAN pick (nil = it runs
    /// the pick): on WAN the Internet quality applies.
    public func qualityNote(lan: StreamQuality, internet: InternetQuality) -> String? {
        guard self == .wan else { return nil }
        return "Over the Internet: \(internet.displayName) — \(internet.quality.displayName), ≈ \(internet.expectedMegabytesPerHour) MB/h"
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
        // A copy trails its frame by up to 8 slots and the copy's 20 ms
        // frame spans 4 more: only frames newer than that prove it lost.
        config.lossHorizonFrames = DatagramLayout.wan.maxOffset + StreamEncoding.wanFrameSlots + 2
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

/// The Internet profile's quality ladder (docs/research/compression.md §5),
/// picked separately from the LAN quality and persisted on the Mac. Every
/// rung sends 20 ms Opus frames with two 24 kbit/s copies.
public enum InternetQuality: String, CaseIterable, Sendable, Codable {
    /// Opus 128, ≈ 101 MB/h over Tailscale.
    case high
    /// Opus 96, ≈ 87 MB/h (the default).
    case standard
    /// Opus 64, ≈ 72 MB/h.
    case saver
    /// Opus 48, ≈ 65 MB/h: the lowest rung that still sounds pleasant.
    case floor

    public static let `default` = InternetQuality.standard

    /// The Opus setting encoded at this rung.
    public var quality: StreamQuality {
        switch self {
        case .high: .opus128
        case .standard: .opus96
        case .saver: .opus64
        case .floor: .opus48
        }
    }

    public var displayName: String {
        switch self {
        case .high: "High"
        case .standard: "Standard"
        case .saver: "Saver"
        case .floor: "Floor"
        }
    }

    /// Expected data use over Tailscale (direct), whole MB per hour, from
    /// the real packer (`StreamDataRate.estimate`).
    public var expectedMegabytesPerHour: Int {
        Self.expectedRates[self] ?? 0
    }

    /// "Standard — Opus 96 kbit/s · ≈ 87 MB/h".
    public var menuName: String {
        "\(displayName) — \(quality.displayName) · ≈ \(expectedMegabytesPerHour) MB/h"
    }

    private static let expectedRates: [InternetQuality: Int] = Dictionary(
        uniqueKeysWithValues: allCases.map { rung in
            let estimate = StreamDataRate.estimate(.wan(rung), profile: .wan, path: .tailscaleDirect)
            return (rung, Int(estimate.megabytesPerHour.rounded()))
        })
}

/// What the sender encodes for one profile: the codec setting, the Opus
/// frame duration (in 5 ms slots) and the bitrate of the redundant copies.
public struct StreamEncoding: Equatable, Sendable {
    /// 20 ms Opus frames on WAN.
    public static let wanFrameSlots = 4
    /// Bitrate of the WAN redundant copies (the study's 24 kbit/s: they
    /// recover a loss almost as well as a full-rate copy, for a quarter of
    /// the bytes).
    public static let wanCopyBitrate = 24_000

    public var quality: StreamQuality
    /// 5 ms slots per Opus frame (1 or `wanFrameSlots`); PCM16 is always 1.
    public var frameSlots: Int
    /// Bitrate of the second encoder whose packets fill the redundant
    /// copies; nil = copies repeat the primary.
    public var copyBitrate: Int?

    public init(quality: StreamQuality, frameSlots: Int = 1, copyBitrate: Int? = nil) {
        precondition([1, 2, 4].contains(frameSlots), "frame duration must be 1, 2 or 4 slots")
        self.quality = quality
        self.frameSlots = quality.codec == .opus ? frameSlots : 1
        self.copyBitrate = quality.codec == .opus ? copyBitrate : nil
    }

    /// LAN: the pick at 5 ms, full-rate copies.
    public static func lan(_ quality: StreamQuality) -> StreamEncoding {
        StreamEncoding(quality: quality)
    }

    /// WAN: the rung's Opus bitrate at 20 ms with 24 kbit/s copies.
    public static func wan(_ quality: InternetQuality) -> StreamEncoding {
        StreamEncoding(quality: quality.quality, frameSlots: wanFrameSlots, copyBitrate: wanCopyBitrate)
    }

    /// "Opus 96 kbit/s · 20 ms".
    public var displayName: String {
        frameSlots > 1
            ? "\(quality.displayName) · \(frameSlots * AudioFormat.frameDurationMs) ms" : quality.displayName
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

    /// Steady-state rate of `encoding` sent under `profile` on `path`,
    /// measured by running the real packer over CBR-sized frames.
    public static func estimate(_ encoding: StreamEncoding, profile: StreamProfile, path: StreamPath) -> Estimate {
        let quality = encoding.quality
        let slots = encoding.frameSlots
        let frameMs = AudioFormat.frameDurationMs * slots
        let payload = quality.opusBitrate.map { $0 / 8 * frameMs / 1000 } ?? AudioFormat.pcm16FrameBytes
        let copyPayload = encoding.copyBitrate.map { Data(count: $0 / 8 * frameMs / 1000) }
        var packer = RedundancyPacker()
        packer.profile = profile
        let warmUp = 64
        let measured = 400
        var datagrams = 0
        var bytes = 0
        var largest = 0
        for frame in 0..<(warmUp + measured) {
            let sequence = frame * slots
            let packet = AudioPacket(
                codec: quality.codec, sequence: UInt32(sequence),
                sampleTime: UInt64(sequence * AudioFormat.samplesPerFrame),
                payload: Data(count: payload), frameSlots: slots, copyPayload: copyPayload)
            let out = packer.pack(packet)
            guard frame >= warmUp else { continue }
            datagrams += out.count
            bytes += out.reduce(0) { $0 + $1.count }
            largest = max(largest, out.map(\.count).max() ?? 0)
        }
        let seconds = Double(measured * slots) * AudioFormat.frameDuration
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
