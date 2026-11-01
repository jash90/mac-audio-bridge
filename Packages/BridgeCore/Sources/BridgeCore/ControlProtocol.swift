import Foundation

/// Remote control between the iPhone (client) and each Mac (server).
///
/// Every Mac advertises itself as a source over Bonjour (`serviceType`, TXT
/// `v` = `txtVersion`, `id` = the Mac's persisted source UUID) and accepts TCP
/// connections from phones. Both directions carry frames:
///
///     offset  size  field
///        0      4   payload length n (big-endian, 1...maxFrameBytes)
///        4      n   UTF-8 JSON envelope {"v": 1, "type": "...", ...}
///
/// The envelope's `v` is the version that introduced the message
/// (`ControlMessage.requiredVersion`): version 1 messages still go out as
/// `v: 1`, so a Mac on version 1 keeps working with a newer phone. A frame
/// outside `minimumVersion...version` is rejected with `versionMismatch`
/// (the peer is told to update). Version 2 adds `media` / `nowPlaying`
/// (see MediaControl.swift) and `SourceStatus.protocolVersion`; version 3
/// adds the Internet-mode fields of hello / status (optional, so their
/// envelopes stay `v: 1`). A malformed frame
/// is skipped (the length prefix keeps the stream in step); only an oversized
/// or empty length is fatal, because the stream can no longer be trusted.
///
/// Trust: no authentication of our own (personal MVP). Both ends drop peers
/// whose address is neither local nor on the Tailscale tailnet
/// (`NetworkAddress.isTrustedForControl`): anyone on the same LAN, and any
/// device of the user's own tailnet (Tailscale authenticates its peers), can
/// control a Mac's stream; everything else is refused.
///
/// Internet mode (version 3): the Mac listens on `preferredPort` so a phone
/// can reach it by address (tailnet IP / MagicDNS name) without Bonjour;
/// hello and status carry each side's tailnet addresses, learnt while both
/// are on the same LAN and used for the failover.
public enum ControlProtocol {
    public static let serviceType = "_macaudiosrc._tcp"
    public static let domain = "local."
    /// TXT keys / values.
    public static let versionKey = "v"
    public static let idKey = "id"
    /// Bonjour TXT version (2: the control listener prefers `preferredPort`
    /// and speaks Internet mode).
    public static let txtVersion = "2"
    /// Newest envelope version this build speaks (2: `media` / `nowPlaying`
    /// and `SourceStatus.protocolVersion`; 3: tailnet addresses, network and
    /// path, profile and data usage in hello / status).
    public static let version = 3
    /// Oldest envelope version still accepted.
    public static let minimumVersion = 1
    /// First version with playback control (`media` / `nowPlaying`): the
    /// phone sends `media` only to a Mac reporting at least this.
    public static let mediaVersion = 2
    /// TCP port the Mac's control listener binds first (any free port if
    /// taken; Bonjour carries the real one).
    public static let preferredPort: UInt16 = 49_001
    public static let lengthPrefixBytes = 4
    /// Largest accepted payload; real frames are a few hundred bytes.
    public static let maxFrameBytes = 64 * 1024

    /// Whether a discovered source speaks our protocol. A missing version is
    /// accepted: the TXT record can arrive after the service itself.
    public static func isCompatible(txtVersion version: String?) -> Bool {
        guard let version else { return true }
        return version == txtVersion
    }
}

public enum ControlProtocolError: Error, Equatable, Sendable {
    /// The length prefix exceeds `ControlProtocol.maxFrameBytes` (fatal).
    case frameTooLarge(Int)
    /// A zero-length frame (fatal).
    case emptyFrame
    /// The envelope's version is outside `ControlProtocol.minimumVersion...version`.
    case versionMismatch(Int)
    /// Not a JSON envelope, an unknown type, or a missing field.
    case malformed
}

/// The phone introduces itself right after connecting (and again when its
/// Bonjour name changes).
public struct PhoneHello: Codable, Equatable, Sendable {
    /// Stable per install.
    public var phoneID: String
    /// Shown in the Mac's menu ("Controlled from iPhone …").
    public var phoneName: String
    /// The phone's `_macaudiobridge._udp` service name: where the Mac streams.
    public var receiverService: String
    /// The phone's tailnet addresses (IPv4 first): where the Mac streams
    /// when Bonjour cannot see the phone. Nil/empty = no Tailscale.
    public var tailnetAddresses: [String]?
    /// The phone's current network ("wifi", "cellular", "wired", "other").
    public var network: String?
    /// The phone's path is expensive (cellular, personal hotspot): the Mac
    /// uses the WAN profile.
    public var expensivePath: Bool?

    public init(
        phoneID: String, phoneName: String, receiverService: String,
        tailnetAddresses: [String]? = nil, network: String? = nil, expensivePath: Bool? = nil
    ) {
        self.phoneID = phoneID
        self.phoneName = phoneName
        self.receiverService = receiverService
        self.tailnetAddresses = tailnetAddresses
        self.network = network
        self.expensivePath = expensivePath
    }
}

/// What a Mac reports to each connected phone (on change and every 2 s).
public struct SourceStatus: Codable, Equatable, Sendable {
    public var sourceID: String
    /// The Mac's computer name.
    public var name: String
    /// Tag carried in this Mac's audio datagrams.
    public var sourceTag: UInt32
    public var driverInstalled: Bool
    /// "iPhone (Mac Audio Bridge)" is the default output.
    public var outputIsOurs: Bool
    /// Streaming to the phone this status is sent to.
    public var streamingToYou: Bool
    /// Receiver streamed to (any phone), nil when not streaming.
    public var streamingTo: String?
    /// Something is playing: non-silent audio while streaming, or our
    /// device running somewhere.
    public var audioPlaying: Bool
    /// Name of the current default output device.
    public var outputDeviceName: String?
    /// Virtual-device volume, 0...1.
    public var volume: Float
    public var muted: Bool
    public var quality: StreamQuality
    /// Name of the Mac that took the phone over from this one (nil = none).
    public var usedBy: String?
    /// Problem worth showing on the phone (driver missing, capture denied).
    public var problem: String?
    /// The Mac's `ControlProtocol.version` (absent from version 1 Macs).
    public var protocolVersion: Int?
    /// The Mac's tailnet addresses (IPv4 first); the phone keeps them to
    /// reach the Mac over Tailscale.
    public var tailnetAddresses: [String]?
    /// Path of the audio stream to this phone (nil = not streaming to it).
    public var path: StreamPath?
    /// Profile of that stream.
    public var profile: StreamProfile?
    /// Why the stream's quality differs from `quality` (WAN cap).
    public var qualityNote: String?
    /// Wire bytes sent to this phone in the current streaming session.
    public var sessionBytes: Int?
    /// ≈ MB per hour at the current rate.
    public var megabytesPerHour: Double?

    public init(
        sourceID: String, name: String, sourceTag: UInt32, driverInstalled: Bool,
        outputIsOurs: Bool, streamingToYou: Bool, streamingTo: String?, audioPlaying: Bool,
        outputDeviceName: String?, volume: Float, muted: Bool, quality: StreamQuality,
        usedBy: String?, problem: String?, protocolVersion: Int? = ControlProtocol.version,
        tailnetAddresses: [String]? = nil, path: StreamPath? = nil,
        profile: StreamProfile? = nil, qualityNote: String? = nil, sessionBytes: Int? = nil,
        megabytesPerHour: Double? = nil
    ) {
        self.tailnetAddresses = tailnetAddresses
        self.path = path
        self.profile = profile
        self.qualityNote = qualityNote
        self.sessionBytes = sessionBytes
        self.megabytesPerHour = megabytesPerHour
        self.sourceID = sourceID
        self.name = name
        self.sourceTag = sourceTag
        self.driverInstalled = driverInstalled
        self.outputIsOurs = outputIsOurs
        self.streamingToYou = streamingToYou
        self.streamingTo = streamingTo
        self.audioPlaying = audioPlaying
        self.outputDeviceName = outputDeviceName
        self.volume = volume
        self.muted = muted
        self.quality = quality
        self.usedBy = usedBy
        self.problem = problem
        self.protocolVersion = protocolVersion
    }
}

extension StreamQuality: Codable {}

public enum ControlMessage: Equatable, Sendable {
    // Phone → Mac
    case hello(PhoneHello)
    /// "Use this Mac": remember the current output, switch to ours, stream
    /// to this phone.
    case connect
    /// Stop streaming to this phone and restore the remembered output.
    case disconnect
    /// Like `disconnect`, because another Mac (named) took the phone over.
    case release(byName: String)
    case setVolume(Float)
    case setMuted(Bool)
    case setQuality(StreamQuality)
    /// Version 2: a playback command for the Mac's Now Playing app.
    case media(MediaCommand)
    // Mac → phone
    case status(SourceStatus)
    /// The Mac's user just selected our output (an explicit Mac-side action):
    /// the phone makes this Mac active and releases the others.
    case claim
    /// Version 2: what plays on the Mac (nil: nothing).
    case nowPlaying(NowPlayingInfo?)

    /// The envelope version that introduced this message.
    public var requiredVersion: Int {
        switch self {
        case .media, .nowPlaying: ControlProtocol.mediaVersion
        default: 1
        }
    }

    var type: String {
        switch self {
        case .hello: "hello"
        case .connect: "connect"
        case .disconnect: "disconnect"
        case .release: "release"
        case .setVolume: "setVolume"
        case .setMuted: "setMuted"
        case .setQuality: "setQuality"
        case .status: "status"
        case .claim: "claim"
        case .media: "media"
        case .nowPlaying: "nowPlaying"
        }
    }

    /// The envelope; one optional field per payload kind.
    private struct Envelope: Codable {
        var v: Int
        var type: String
        var hello: PhoneHello?
        var byName: String?
        var volume: Float?
        var muted: Bool?
        var quality: StreamQuality?
        var status: SourceStatus?
        var media: MediaCommand?
        var nowPlaying: NowPlayingInfo?
    }

    /// Only the version, decoded first so a newer envelope reports
    /// `versionMismatch` rather than `malformed`.
    private struct VersionProbe: Decodable {
        var v: Int
    }

    /// The JSON payload of one frame (no length prefix).
    public func payload() -> Data {
        var envelope = Envelope(v: requiredVersion, type: type)
        switch self {
        case .hello(let hello): envelope.hello = hello
        case .release(let name): envelope.byName = name
        case .setVolume(let volume): envelope.volume = volume
        case .setMuted(let muted): envelope.muted = muted
        case .setQuality(let quality): envelope.quality = quality
        case .status(let status): envelope.status = status
        case .media(let command): envelope.media = command
        case .nowPlaying(let info): envelope.nowPlaying = info
        case .connect, .disconnect, .claim: break
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Encoding plain value types cannot fail.
        return (try? encoder.encode(envelope)) ?? Data()
    }

    /// One complete wire frame: length prefix + payload.
    public func frame() -> Data {
        let body = payload()
        var data = Data(capacity: ControlProtocol.lengthPrefixBytes + body.count)
        let length = UInt32(body.count)
        for shift in stride(from: 24, through: 0, by: -8) {
            data.append(UInt8((length >> UInt32(shift)) & 0xFF))
        }
        data.append(body)
        return data
    }

    /// Decodes one frame payload (as produced by `ControlFrameDecoder`).
    public static func decode(payload: Data) throws(ControlProtocolError) -> ControlMessage {
        let decoder = JSONDecoder()
        guard let probe = try? decoder.decode(VersionProbe.self, from: payload) else {
            throw .malformed
        }
        guard (ControlProtocol.minimumVersion...ControlProtocol.version).contains(probe.v) else { throw .versionMismatch(probe.v) }
        guard let envelope = try? decoder.decode(Envelope.self, from: payload) else {
            throw .malformed
        }
        switch envelope.type {
        case "hello":
            guard let hello = envelope.hello else { throw .malformed }
            return .hello(hello)
        case "connect": return .connect
        case "disconnect": return .disconnect
        case "release":
            guard let name = envelope.byName else { throw .malformed }
            return .release(byName: name)
        case "setVolume":
            guard let volume = envelope.volume, volume.isFinite else { throw .malformed }
            return .setVolume(min(max(volume, 0), 1))
        case "setMuted":
            guard let muted = envelope.muted else { throw .malformed }
            return .setMuted(muted)
        case "setQuality":
            guard let quality = envelope.quality else { throw .malformed }
            return .setQuality(quality)
        case "status":
            guard let status = envelope.status else { throw .malformed }
            return .status(status)
        case "claim": return .claim
        case "media":
            guard let command = envelope.media else { throw .malformed }
            return .media(command)
        case "nowPlaying":
            return .nowPlaying(envelope.nowPlaying)
        default:
            throw .malformed
        }
    }
}

/// Splits a TCP byte stream into frame payloads. Not thread-safe; one per
/// connection, owned by its queue.
public struct ControlFrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    /// Appends received bytes and returns every complete payload. Throws on
    /// a length that can never be valid; the connection must then be closed.
    public mutating func append(_ data: Data) throws(ControlProtocolError) -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while buffer.count >= ControlProtocol.lengthPrefixBytes {
            let base = buffer.startIndex
            var length = 0
            for index in 0..<ControlProtocol.lengthPrefixBytes {
                length = length << 8 | Int(buffer[base + index])
            }
            guard length > 0 else { throw .emptyFrame }
            guard length <= ControlProtocol.maxFrameBytes else { throw .frameTooLarge(length) }
            let total = ControlProtocol.lengthPrefixBytes + length
            guard buffer.count >= total else { break }
            frames.append(Data(buffer[(base + ControlProtocol.lengthPrefixBytes)..<(base + total)]))
            buffer.removeSubrange(base..<(base + total))
        }
        return frames
    }

    /// Bytes waiting for the rest of their frame.
    public var pendingBytes: Int { buffer.count }
}

/// The 32-bit tag a Mac stamps into its audio datagrams, derived from its
/// source UUID (FNV-1a), so the phone can tell two Macs' streams apart
/// whatever their addresses. Never 0 (0 = untagged).
public enum SourceTag {
    public static func make(sourceID: String) -> UInt32 {
        var hash: UInt32 = 0x811C_9DC5
        for byte in sourceID.lowercased().utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return hash == 0 ? 1 : hash
    }
}

/// Which peer addresses count as "local network" for the control channel.
public enum LocalNetworkAddress {
    /// Private (RFC 1918), link-local and loopback IPv4.
    public static func isLocal(ipv4 bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        switch (bytes[0], bytes[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, let second): return (16...31).contains(second)
        default: return false
        }
    }

    /// Loopback, link-local (fe80::/10), unique-local (fc00::/7) and
    /// IPv4-mapped local IPv6.
    public static func isLocal(ipv6 bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
        if bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 { return true }
        if bytes[0] & 0xFE == 0xFC { return true }
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
            return isLocal(ipv4: Array(bytes[12..<16]))
        }
        return false
    }
}
