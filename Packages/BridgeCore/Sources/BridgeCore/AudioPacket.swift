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

/// Errors thrown while decoding a datagram from the wire.
public enum AudioPacketError: Error, Equatable {
    /// Fewer than `AudioPacket.headerSize` bytes.
    case tooShort
    /// The leading magic value does not match `AudioPacket.magic`.
    case badMagic
    /// A protocol version this build cannot parse.
    case unsupportedVersion(UInt8)
    /// A codec identifier outside the known `AudioCodec` cases.
    case unknownCodec(UInt8)
    /// The frame entries do not match the datagram length (truncated entry,
    /// trailing bytes, or a repeated offset).
    case malformedEntries
    /// `AudioPacket.decode` was given a redundancy-only datagram.
    case noPrimaryFrame
}

/// One audio frame: what the jitter buffer stores and plays. On the wire it
/// travels as an entry of an `AudioDatagram` — as the datagram's primary
/// frame, or as a redundant copy inside a later datagram.
public struct AudioPacket: Sendable, Equatable {
    /// Wire header size in bytes (see `AudioDatagram`).
    public static let headerSize = AudioDatagram.headerSize
    /// Leading magic value, ASCII "MABA".
    public static let magic: UInt32 = AudioDatagram.magic
    /// Current protocol version.
    public static let version: UInt8 = AudioDatagram.version

    public var codec: AudioCodec
    public var flags: AudioPacketFlags
    /// Wrapping frame sequence number.
    public var sequence: UInt32
    /// Index of the first sample of this frame in the sender's stream.
    public var sampleTime: UInt64
    public var payload: Data
    /// True when this frame is a redundant copy (an entry with a non-zero
    /// offset), not the datagram's primary frame. The jitter buffer uses a
    /// redundant copy only to fill a slot whose primary never arrived.
    public var isRedundant: Bool

    public init(
        codec: AudioCodec,
        flags: AudioPacketFlags = [],
        sequence: UInt32,
        sampleTime: UInt64,
        payload: Data,
        isRedundant: Bool = false
    ) {
        self.codec = codec
        self.flags = flags
        self.sequence = sequence
        self.sampleTime = sampleTime
        self.payload = payload
        self.isRedundant = isRedundant
    }

    /// Wire encoding of a datagram that carries only this frame.
    public func encoded() -> Data {
        AudioDatagram(primary: self, redundant: []).encoded()
    }

    /// Decodes a datagram and returns its primary frame. Accepts `Data`
    /// slices whose `startIndex` is not zero.
    public static func decode(_ data: Data) throws(AudioPacketError) -> AudioPacket {
        let datagram = try AudioDatagram.decode(data)
        guard let primary = datagram.packets().first(where: { !$0.isRedundant }) else {
            throw AudioPacketError.noPrimaryFrame
        }
        return primary
    }
}

/// One UDP datagram: a fixed 20-byte big-endian header followed by one or
/// more codec frames. Codec-agnostic: every entry is an opaque frame of the
/// header's codec, so the same layout carries "current + previous N frames"
/// for a compact codec (several frames fit in one datagram) and a single
/// frame per datagram for PCM16 (a 5 ms PCM16 frame is 960 B, two do not fit
/// in `AudioFormat.maxDatagramBytes`).
///
///     offset  size  field
///        0      4   magic "MABA" (0x4D414241)
///        4      1   version (2)
///        5      1   codec (AudioCodec raw value)
///        6      1   flags (AudioPacketFlags raw value) — apply to the
///                   reference frame only
///        7      1   entry count (≥ 1)
///        8      4   reference sequence (wrapping)
///       12      8   reference sampleTime
///       20      …   entries, each:
///                     1  back offset k: this entry is frame
///                        (sequence − k), sampleTime − k × samplesPerFrame
///                     2  payload length (big-endian)
///                     n  payload
///
/// Offset 0 is the reference frame itself (the primary copy); offsets > 0
/// are redundant copies of earlier frames. A datagram may carry redundant
/// entries only (no offset 0) — e.g. PCM16's delayed copy.
public struct AudioDatagram: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        /// Frames back from the reference sequence (0 = the reference frame).
        public var offset: UInt8
        public var payload: Data

        public init(offset: UInt8, payload: Data) {
            self.offset = offset
            self.payload = payload
        }
    }

    /// Fixed header size in bytes.
    public static let headerSize = 20
    /// Per-entry header: offset (1) + length (2).
    public static let entryHeaderSize = 3
    /// Leading magic value, ASCII "MABA".
    public static let magic: UInt32 = 0x4D41_4241
    /// Version 2: 5 ms frames, multi-frame entries (version 1 was one 10 ms
    /// frame per datagram).
    public static let version: UInt8 = 2

    public var codec: AudioCodec
    public var flags: AudioPacketFlags
    public var sequence: UInt32
    public var sampleTime: UInt64
    public var entries: [Entry]

    public init(
        codec: AudioCodec,
        flags: AudioPacketFlags,
        sequence: UInt32,
        sampleTime: UInt64,
        entries: [Entry]
    ) {
        self.codec = codec
        self.flags = flags
        self.sequence = sequence
        self.sampleTime = sampleTime
        self.entries = entries
    }

    /// A datagram whose reference is `primary`, carrying `primary` at
    /// offset 0 followed by `redundant` (each must precede `primary` by
    /// 1...255 frames).
    public init(primary: AudioPacket, redundant: [AudioPacket]) {
        self.init(
            codec: primary.codec, flags: primary.flags, sequence: primary.sequence,
            sampleTime: primary.sampleTime,
            entries: [Entry(offset: 0, payload: primary.payload)]
                + redundant.map { Entry(offset: Self.offset(of: $0, from: primary.sequence), payload: $0.payload) })
    }

    /// Back offset of `packet` relative to `reference`.
    public static func offset(of packet: AudioPacket, from reference: UInt32) -> UInt8 {
        let distance = reference &- packet.sequence
        precondition(distance <= UInt32(UInt8.max), "redundant frame too far back")
        return UInt8(distance)
    }

    /// Encoded size of a datagram with entries of these payload sizes.
    public static func encodedSize(payloadSizes: some Sequence<Int>) -> Int {
        payloadSizes.reduce(headerSize) { $0 + entryHeaderSize + $1 }
    }

    /// The frames this datagram carries, primary first if present. Flags go
    /// to the offset-0 frame only.
    public func packets() -> [AudioPacket] {
        entries.map { entry in
            let offset = UInt32(entry.offset)
            return AudioPacket(
                codec: codec,
                flags: entry.offset == 0 ? flags : [],
                sequence: sequence &- offset,
                sampleTime: sampleTime &- UInt64(offset) * UInt64(AudioFormat.samplesPerFrame),
                payload: entry.payload,
                isRedundant: entry.offset != 0)
        }
    }

    /// Big-endian wire encoding.
    public func encoded() -> Data {
        precondition(!entries.isEmpty && entries.count <= Int(UInt8.max), "1...255 entries")
        var data = Data(capacity: Self.encodedSize(payloadSizes: entries.map(\.payload.count)))
        func append32(_ value: UInt32) {
            for shift in stride(from: 24, through: 0, by: -8) { data.append(UInt8((value >> UInt32(shift)) & 0xFF)) }
        }
        append32(Self.magic)
        data.append(Self.version)
        data.append(codec.rawValue)
        data.append(flags.rawValue)
        data.append(UInt8(entries.count))
        append32(sequence)
        append32(UInt32(truncatingIfNeeded: sampleTime >> 32))
        append32(UInt32(truncatingIfNeeded: sampleTime))
        for entry in entries {
            precondition(entry.payload.count <= Int(UInt16.max), "entry payload too large")
            data.append(entry.offset)
            data.append(UInt8((entry.payload.count >> 8) & 0xFF))
            data.append(UInt8(entry.payload.count & 0xFF))
            data.append(entry.payload)
        }
        return data
    }

    /// Decodes a datagram. Accepts `Data` slices whose `startIndex` is not
    /// zero; entry payloads are slices of `data` (no copy).
    public static func decode(_ data: Data) throws(AudioPacketError) -> AudioDatagram {
        guard data.count >= headerSize else { throw AudioPacketError.tooShort }
        let base = data.startIndex
        func byte(_ offset: Int) -> UInt8 { data[base + offset] }
        func read32(_ offset: Int) -> UInt32 {
            UInt32(byte(offset)) << 24 | UInt32(byte(offset + 1)) << 16
                | UInt32(byte(offset + 2)) << 8 | UInt32(byte(offset + 3))
        }

        guard read32(0) == magic else { throw AudioPacketError.badMagic }
        let version = byte(4)
        guard version == Self.version else { throw AudioPacketError.unsupportedVersion(version) }
        let codecValue = byte(5)
        guard let codec = AudioCodec(rawValue: codecValue) else {
            throw AudioPacketError.unknownCodec(codecValue)
        }
        let flags = AudioPacketFlags(rawValue: byte(6))
        let entryCount = Int(byte(7))
        let sequence = read32(8)
        let sampleTime = UInt64(read32(12)) << 32 | UInt64(read32(16))

        guard entryCount > 0 else { throw AudioPacketError.malformedEntries }
        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)
        var cursor = headerSize
        var seenOffsets = Set<UInt8>()
        for _ in 0..<entryCount {
            guard data.count - cursor >= entryHeaderSize else { throw AudioPacketError.malformedEntries }
            let offset = byte(cursor)
            let length = Int(byte(cursor + 1)) << 8 | Int(byte(cursor + 2))
            cursor += entryHeaderSize
            guard data.count - cursor >= length, seenOffsets.insert(offset).inserted else {
                throw AudioPacketError.malformedEntries
            }
            entries.append(Entry(offset: offset, payload: data[(base + cursor)..<(base + cursor + length)]))
            cursor += length
        }
        guard cursor == data.count else { throw AudioPacketError.malformedEntries }
        return AudioDatagram(
            codec: codec, flags: flags, sequence: sequence, sampleTime: sampleTime, entries: entries)
    }
}

/// Loss recovery by redundancy (single toggle).
///
/// Every frame is sent again, as a redundant entry, `offsets` frames later.
/// One redundant copy `k` frames back recovers any run of up to `k`
/// consecutive lost datagrams, as long as the jitter buffer still holds the
/// slot when the copy arrives (it arrives k × 5 ms after the primary).
/// The packer is codec-agnostic: entries are packed greedily into datagrams
/// of at most `AudioFormat.maxDatagramBytes`, so a compact codec gets
/// "current + previous N frames" in one datagram while PCM16 (960 B per
/// frame) sends the copy as a second datagram — a delayed duplicate, about
/// 3.3 Mbit/s in total.
public enum AudioRedundancy {
    /// Master switch for sending redundant copies.
    public static let enabled = true
    /// Frames back at which each frame is repeated: 3 × 5 ms = 15 ms, which
    /// recovers runs of up to three lost datagrams while needing only 15 ms of
    /// extra cushion for the copy to arrive in time.
    public static let offsets: [Int] = [3]
}

/// Turns a stream of frames into datagrams with redundant copies (see
/// `AudioRedundancy`). Not thread-safe; owned by one queue.
public struct RedundancyPacker: Sendable {
    private let offsets: [Int]
    private let maxDatagramBytes: Int
    /// The last `maxOffset` frames, newest last (cleared at a discontinuity:
    /// frames of a previous run are never repeated into a new one).
    private var history: [AudioPacket] = []
    private let historyDepth: Int

    public init(
        offsets: [Int] = AudioRedundancy.enabled ? AudioRedundancy.offsets : [],
        maxDatagramBytes: Int = AudioFormat.maxDatagramBytes
    ) {
        precondition(offsets.allSatisfy { (1...255).contains($0) }, "offsets in 1...255")
        self.offsets = offsets.sorted()
        self.maxDatagramBytes = maxDatagramBytes
        historyDepth = offsets.max() ?? 0
        history.reserveCapacity(historyDepth + 1)
    }

    public mutating func reset() {
        history.removeAll(keepingCapacity: true)
    }

    /// The datagrams to send for `frame`, in send order: the primary first
    /// (with as many redundant entries as fit), then redundancy-only
    /// datagrams for the copies that did not fit.
    public mutating func pack(_ frame: AudioPacket) -> [Data] {
        if frame.flags.contains(.discontinuity) {
            reset()
        }
        var redundant: [AudioPacket] = []
        for offset in offsets where offset <= history.count {
            let candidate = history[history.count - offset]
            if candidate.sequence == frame.sequence &- UInt32(offset) {
                redundant.append(candidate)
            }
        }

        var datagrams: [Data] = []
        var current = AudioDatagram(primary: frame, redundant: [])
        var size = AudioDatagram.encodedSize(payloadSizes: [frame.payload.count])
        for copy in redundant {
            let entry = AudioDatagram.Entry(
                offset: AudioDatagram.offset(of: copy, from: frame.sequence), payload: copy.payload)
            let added = AudioDatagram.entryHeaderSize + copy.payload.count
            if size + added > maxDatagramBytes, !current.entries.isEmpty {
                datagrams.append(current.encoded())
                current = AudioDatagram(
                    codec: frame.codec, flags: [], sequence: frame.sequence,
                    sampleTime: frame.sampleTime, entries: [])
                size = AudioDatagram.headerSize
            }
            current.entries.append(entry)
            size += added
        }
        datagrams.append(current.encoded())

        if historyDepth > 0 {
            if history.count == historyDepth {
                history.removeFirst()
            }
            history.append(frame)
        }
        return datagrams
    }
}

/// RFC 1982 serial-number arithmetic for `UInt32` sequences: true when `a`
/// follows `b`, correct across the `UInt32.max -> 0` wrap-around.
public func sequenceIsAfter(_ a: UInt32, _ b: UInt32) -> Bool {
    a != b && Int32(bitPattern: a &- b) > 0
}
