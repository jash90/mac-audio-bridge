import Foundation

/// Audio codecs carried in the `AudioPacket` header.
public enum AudioCodec: UInt8, Sendable {
    /// Uncompressed 16-bit PCM samples in the payload.
    case pcm16 = 0
    /// One Opus-encoded frame.
    case opus = 1
}

/// Per-packet flags carried in the `AudioPacket` header.
public struct AudioPacketFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// The sender's stream restarted (device change, reconnect). The receiver
    /// must reset its jitter buffer before buffering this packet.
    public static let discontinuity = AudioPacketFlags(rawValue: 1 << 0)
}

/// Errors thrown while decoding a packet from the wire.
public enum AudioPacketError: Error, Equatable {
    /// Fewer than `AudioPacket.headerSize` bytes.
    case tooShort
    /// The leading magic value does not match `AudioPacket.magic`.
    case badMagic
    /// A protocol version this build cannot parse.
    case unsupportedVersion(UInt8)
    /// A codec identifier outside the known `AudioCodec` cases.
    case unknownCodec(UInt8)
}

/// One audio frame on the wire: a fixed 20-byte big-endian header followed by
/// the codec payload.
///
/// Header layout:
///
///     offset  size  field
///        0      4   magic "MABA" (0x4D414241)
///        4      1   version
///        5      1   codec (AudioCodec raw value)
///        6      1   flags (AudioPacketFlags raw value)
///        7      1   reserved, written as 0, ignored on receive
///        8      4   sequence (wrapping)
///       12      8   sampleTime (first sample of this frame in the sender's stream)
///       20      n   payload
///
public struct AudioPacket: Sendable, Equatable {
    /// Wire header size in bytes.
    public static let headerSize = 20
    /// Leading magic value, ASCII "MABA".
    public static let magic: UInt32 = 0x4D41_4241
    /// Current protocol version.
    public static let version: UInt8 = 1

    public var codec: AudioCodec
    public var flags: AudioPacketFlags
    /// Wrapping frame sequence number.
    public var sequence: UInt32
    /// Index of the first sample of this frame in the sender's stream.
    public var sampleTime: UInt64
    public var payload: Data

    public init(
        codec: AudioCodec,
        flags: AudioPacketFlags = [],
        sequence: UInt32,
        sampleTime: UInt64,
        payload: Data
    ) {
        self.codec = codec
        self.flags = flags
        self.sequence = sequence
        self.sampleTime = sampleTime
        self.payload = payload
    }

    /// Big-endian wire encoding: the 20-byte header followed by the payload.
    public func encoded() -> Data {
        var data = Data(capacity: Self.headerSize + payload.count)
        data.append(UInt8((Self.magic >> 24) & 0xFF))
        data.append(UInt8((Self.magic >> 16) & 0xFF))
        data.append(UInt8((Self.magic >> 8) & 0xFF))
        data.append(UInt8(Self.magic & 0xFF))
        data.append(Self.version)
        data.append(codec.rawValue)
        data.append(flags.rawValue)
        data.append(0) // reserved
        data.append(UInt8((sequence >> 24) & 0xFF))
        data.append(UInt8((sequence >> 16) & 0xFF))
        data.append(UInt8((sequence >> 8) & 0xFF))
        data.append(UInt8(sequence & 0xFF))
        data.append(UInt8((sampleTime >> 56) & 0xFF))
        data.append(UInt8((sampleTime >> 48) & 0xFF))
        data.append(UInt8((sampleTime >> 40) & 0xFF))
        data.append(UInt8((sampleTime >> 32) & 0xFF))
        data.append(UInt8((sampleTime >> 24) & 0xFF))
        data.append(UInt8((sampleTime >> 16) & 0xFF))
        data.append(UInt8((sampleTime >> 8) & 0xFF))
        data.append(UInt8(sampleTime & 0xFF))
        data.append(payload)
        return data
    }

    /// Decodes a packet from `data`. Accepts `Data` slices whose `startIndex`
    /// is not zero.
    public static func decode(_ data: Data) throws(AudioPacketError) -> AudioPacket {
        guard data.count >= headerSize else { throw AudioPacketError.tooShort }
        let base = data.startIndex
        func byte(_ offset: Int) -> UInt8 { data[base + offset] }

        let decodedMagic = UInt32(byte(0)) << 24
            | UInt32(byte(1)) << 16
            | UInt32(byte(2)) << 8
            | UInt32(byte(3))
        guard decodedMagic == magic else { throw AudioPacketError.badMagic }

        let version = byte(4)
        guard version == Self.version else {
            throw AudioPacketError.unsupportedVersion(version)
        }

        let codecValue = byte(5)
        guard let codec = AudioCodec(rawValue: codecValue) else {
            throw AudioPacketError.unknownCodec(codecValue)
        }

        let flags = AudioPacketFlags(rawValue: byte(6))
        // byte(7) is reserved and ignored on receive.

        let sequence = UInt32(byte(8)) << 24
            | UInt32(byte(9)) << 16
            | UInt32(byte(10)) << 8
            | UInt32(byte(11))
        let sampleTime = UInt64(byte(12)) << 56
            | UInt64(byte(13)) << 48
            | UInt64(byte(14)) << 40
            | UInt64(byte(15)) << 32
            | UInt64(byte(16)) << 24
            | UInt64(byte(17)) << 16
            | UInt64(byte(18)) << 8
            | UInt64(byte(19))
        let payload = Data(data.suffix(from: base + headerSize))

        return AudioPacket(
            codec: codec,
            flags: flags,
            sequence: sequence,
            sampleTime: sampleTime,
            payload: payload
        )
    }
}

/// RFC 1982 serial-number arithmetic for `UInt32` sequences: true when `a`
/// follows `b`, correct across the `UInt32.max -> 0` wrap-around.
public func sequenceIsAfter(_ a: UInt32, _ b: UInt32) -> Bool {
    a != b && Int32(bitPattern: a &- b) > 0
}
