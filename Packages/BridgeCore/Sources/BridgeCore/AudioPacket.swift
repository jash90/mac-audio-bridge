import Foundation

/// Audio codecs carried in the `AudioPacket` header.
public enum AudioCodec: UInt8, Sendable {
    /// Uncompressed 16-bit PCM samples in the payload.
    case pcm16 = 0
    /// One Opus packet (one CELT frame, CBR: 5 ms on the LAN, 20 ms on the
    /// Internet profile — see the entry's frame duration) per entry; entries
    /// are length-prefixed by the datagram layout.
    case opus = 1
}

/// Per-frame flags carried in the `AudioDatagram` header (4 bits on the wire).
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
    /// 5 ms sequence slots this frame covers (1; 4 for a 20 ms Opus frame,
    /// which occupies `sequence ..< sequence + 4`).
    public var frameSlots: Int
    /// Sender side: what the redundant copies of this frame carry instead of
    /// `payload` (the low-rate encoding of the same audio); nil = copies
    /// repeat `payload`.
    public var copyPayload: Data?
    /// Receiver side: this redundant copy carries a low-rate encoding.
    public var isLowRateCopy: Bool

    public init(
        codec: AudioCodec,
        flags: AudioPacketFlags = [],
        sequence: UInt32,
        sampleTime: UInt64,
        payload: Data,
        isRedundant: Bool = false,
        frameSlots: Int = 1,
        copyPayload: Data? = nil,
        isLowRateCopy: Bool = false
    ) {
        self.codec = codec
        self.flags = flags
        self.sequence = sequence
        self.sampleTime = sampleTime
        self.payload = payload
        self.isRedundant = isRedundant
        self.frameSlots = frameSlots
        self.copyPayload = copyPayload
        self.isLowRateCopy = isLowRateCopy
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

/// One UDP datagram: a fixed 24-byte big-endian header followed by one or
/// more codec frames. Codec-agnostic: every entry is an opaque frame of the
/// header's codec, so the same layout carries "current + previous N frames"
/// for a compact codec (several frames fit in one datagram) and a single
/// frame per datagram for PCM16 (a 5 ms PCM16 frame is 960 B, two do not fit
/// in `AudioFormat.maxDatagramBytes`).
///
///     offset  size  field
///        0      4   magic "MABA" (0x4D414241)
///        4      1   version (6)
///        5      1   codec (AudioCodec raw value)
///        6      1   bits 0–3: frame flags (AudioPacketFlags) of the oldest
///                   primary frame; bits 4–6: primary count − 1 (1...8);
///                   bit 7: profile (0 = LAN, 1 = WAN, see StreamProfile)
///        7      1   entry count (≥ 1)
///        8      4   reference sequence (wrapping) — the newest frame
///       12      8   reference sampleTime
///       20      4   source tag (`SourceTag` of the sending Mac; 0 =
///                   untagged) — the receiver plays one source at a time
///       24      …   entries, each:
///                     1  back offset k (in 5 ms slots): this entry is
///                        frame (sequence − k), sampleTime − k × samplesPerFrame
///                     2  big-endian: bits 0–10 payload length; bits 13–14
///                        frame duration, log2 of its 5 ms slots (0 = 5 ms,
///                        1 = 10 ms, 2 = 20 ms); bit 15 low-rate copy (the
///                        entry is a copy from the sender's second, low-rate
///                        encoder); bits 11–12 zero
///                     n  payload
///
/// Sequence numbers and offsets always count 5 ms slots: a 20 ms Opus frame
/// is frame `sequence` and covers slots `sequence ..< sequence + 4`, so the
/// receiver's jitter buffer and the LAN ↔ WAN switch keep one continuous
/// sequence space. Offsets below the primary count are the datagram's
/// primary frames (both production layouts carry one, offset 0); larger
/// offsets are redundant copies of earlier frames. A datagram may carry
/// redundant entries only (no offset below the primary count) — e.g.
/// PCM16's delayed copy.
///
/// Version 6 (this one) adds the per-entry frame duration and low-rate flag
/// to version 4 (the mic stream uses version 5, see `MicDatagram`).
public struct AudioDatagram: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        /// Frames back from the reference sequence (0 = the reference frame).
        public var offset: UInt8
        public var payload: Data
        /// 5 ms slots the frame covers (1, 2 or 4).
        public var frameSlots: Int
        /// A copy from the sender's low-rate encoder.
        public var lowRate: Bool

        public init(offset: UInt8, payload: Data, frameSlots: Int = 1, lowRate: Bool = false) {
            self.offset = offset
            self.payload = payload
            self.frameSlots = frameSlots
            self.lowRate = lowRate
        }

        /// A primary entry for `packet`.
        public static func primary(_ packet: AudioPacket, reference: UInt32) -> Entry {
            Entry(
                offset: AudioDatagram.offset(of: packet, from: reference), payload: packet.payload,
                frameSlots: packet.frameSlots)
        }

        /// A redundant-copy entry for `packet`: its low-rate payload when it
        /// has one.
        public static func copy(_ packet: AudioPacket, reference: UInt32) -> Entry {
            Entry(
                offset: AudioDatagram.offset(of: packet, from: reference),
                payload: packet.copyPayload ?? packet.payload, frameSlots: packet.frameSlots,
                lowRate: packet.copyPayload != nil || packet.isLowRateCopy)
        }
    }

    /// Fixed header size in bytes.
    public static let headerSize = 24
    /// Per-entry header: offset (1) + length (2).
    public static let entryHeaderSize = 3
    /// Leading magic value, ASCII "MABA".
    public static let magic: UInt32 = 0x4D41_4241
    /// Version 6: version 4 (5 ms slots, multi-frame entries, source tag,
    /// several primaries, the profile bit) plus each entry's frame duration
    /// and low-rate flag. Version 5 is the mic stream's.
    public static let version: UInt8 = 6
    /// Largest entry payload the length field can carry (11 bits).
    public static let maxEntryPayloadBytes = 0x07FF
    private static let lengthMask: UInt16 = 0x07FF
    private static let slotsShift: UInt16 = 13
    private static let slotsMask: UInt16 = 0x6000
    private static let lowRateBit: UInt16 = 0x8000
    private static let reservedMask: UInt16 = 0x1800
    /// Most primary frames one datagram can carry (3 header bits).
    public static let maxPrimaryCount = 8

    private static let frameFlagsMask: UInt8 = 0x0F
    private static let primaryCountShift: UInt8 = 4
    private static let primaryCountMask: UInt8 = 0x70
    private static let profileBit: UInt8 = 0x80

    public var codec: AudioCodec
    /// Flags of the oldest primary frame (offset `primaryCount − 1`).
    public var flags: AudioPacketFlags
    public var sequence: UInt32
    public var sampleTime: UInt64
    /// Tag of the sending Mac (`SourceTag.make(sourceID:)`), 0 = untagged.
    public var source: UInt32
    /// Entries with an offset below this are primaries (1...8).
    public var primaryCount: Int
    public var profile: StreamProfile
    public var entries: [Entry]

    public init(
        codec: AudioCodec,
        flags: AudioPacketFlags,
        sequence: UInt32,
        sampleTime: UInt64,
        source: UInt32 = 0,
        primaryCount: Int = 1,
        profile: StreamProfile = .lan,
        entries: [Entry]
    ) {
        self.codec = codec
        self.flags = flags
        self.sequence = sequence
        self.sampleTime = sampleTime
        self.source = source
        self.primaryCount = primaryCount
        self.profile = profile
        self.entries = entries
    }

    /// Whether the datagram carries at least one primary frame.
    public var hasPrimary: Bool {
        entries.contains { Int($0.offset) < primaryCount }
    }

    /// A datagram whose reference is `primary`, carrying `primary` at
    /// offset 0 followed by `redundant` (each must precede `primary` by
    /// 1...255 frames).
    public init(primary: AudioPacket, redundant: [AudioPacket], source: UInt32 = 0) {
        self.init(primaries: [primary], redundant: redundant, source: source)
    }

    /// A datagram carrying consecutive `primaries` (oldest first; the
    /// newest is the reference) followed by `redundant` copies of earlier
    /// frames. Flags come from the oldest primary.
    public init(
        primaries: [AudioPacket], redundant: [AudioPacket], source: UInt32 = 0, profile: StreamProfile = .lan
    ) {
        precondition((1...Self.maxPrimaryCount).contains(primaries.count), "1...8 primaries")
        let reference = primaries[primaries.count - 1]
        self.init(
            codec: reference.codec, flags: primaries[0].flags, sequence: reference.sequence,
            sampleTime: reference.sampleTime, source: source, primaryCount: primaries.count,
            profile: profile,
            entries: primaries.reversed().map { Entry.primary($0, reference: reference.sequence) }
                + redundant.map { Entry.copy($0, reference: reference.sequence) })
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

    /// The frames this datagram carries: primaries oldest first (send
    /// order), then the redundant copies in entry order. Flags go to the
    /// oldest primary only.
    public func packets() -> [AudioPacket] {
        let oldestPrimary = UInt8(primaryCount - 1)
        func packet(_ entry: Entry) -> AudioPacket {
            let offset = UInt32(entry.offset)
            return AudioPacket(
                codec: codec,
                flags: entry.offset == oldestPrimary ? flags : [],
                sequence: sequence &- offset,
                sampleTime: sampleTime &- UInt64(offset) * UInt64(AudioFormat.samplesPerFrame),
                payload: entry.payload,
                isRedundant: Int(entry.offset) >= primaryCount,
                frameSlots: entry.frameSlots,
                isLowRateCopy: entry.lowRate && Int(entry.offset) >= primaryCount)
        }
        let primaries = entries.filter { Int($0.offset) < primaryCount }.sorted { $0.offset > $1.offset }
        let copies = entries.filter { Int($0.offset) >= primaryCount }
        return primaries.map(packet) + copies.map(packet)
    }

    /// Big-endian wire encoding.
    public func encoded() -> Data {
        precondition(!entries.isEmpty && entries.count <= Int(UInt8.max), "1...255 entries")
        precondition((1...Self.maxPrimaryCount).contains(primaryCount), "1...8 primaries")
        var data = Data(capacity: Self.encodedSize(payloadSizes: entries.map(\.payload.count)))
        func append32(_ value: UInt32) {
            for shift in stride(from: 24, through: 0, by: -8) { data.append(UInt8((value >> UInt32(shift)) & 0xFF)) }
        }
        append32(Self.magic)
        data.append(Self.version)
        data.append(codec.rawValue)
        data.append(
            (flags.rawValue & Self.frameFlagsMask)
                | (UInt8(primaryCount - 1) << Self.primaryCountShift)
                | (profile == .wan ? Self.profileBit : 0))
        data.append(UInt8(entries.count))
        append32(sequence)
        append32(UInt32(truncatingIfNeeded: sampleTime >> 32))
        append32(UInt32(truncatingIfNeeded: sampleTime))
        append32(source)
        for entry in entries {
            precondition(entry.payload.count <= Self.maxEntryPayloadBytes, "entry payload too large")
            let slotsCode = UInt16(entry.frameSlots.trailingZeroBitCount)
            precondition(
                [1, 2, 4].contains(entry.frameSlots), "frame duration must be 1, 2 or 4 slots")
            let field = UInt16(entry.payload.count) | slotsCode << Self.slotsShift
                | (entry.lowRate ? Self.lowRateBit : 0)
            data.append(entry.offset)
            data.append(UInt8(field >> 8))
            data.append(UInt8(field & 0xFF))
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
        let flagsByte = byte(6)
        let flags = AudioPacketFlags(rawValue: flagsByte & frameFlagsMask)
        let primaryCount = Int((flagsByte & primaryCountMask) >> primaryCountShift) + 1
        let profile: StreamProfile = flagsByte & profileBit != 0 ? .wan : .lan
        let entryCount = Int(byte(7))
        let sequence = read32(8)
        let sampleTime = UInt64(read32(12)) << 32 | UInt64(read32(16))
        let source = read32(20)

        guard entryCount > 0 else { throw AudioPacketError.malformedEntries }
        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)
        var cursor = headerSize
        var seenOffsets = Set<UInt8>()
        for _ in 0..<entryCount {
            guard data.count - cursor >= entryHeaderSize else { throw AudioPacketError.malformedEntries }
            let offset = byte(cursor)
            let field = UInt16(byte(cursor + 1)) << 8 | UInt16(byte(cursor + 2))
            let length = Int(field & lengthMask)
            let slotsCode = (field & slotsMask) >> slotsShift
            cursor += entryHeaderSize
            guard field & reservedMask == 0, slotsCode <= 2,
                data.count - cursor >= length, seenOffsets.insert(offset).inserted
            else {
                throw AudioPacketError.malformedEntries
            }
            entries.append(
                Entry(
                    offset: offset, payload: data[(base + cursor)..<(base + cursor + length)],
                    frameSlots: 1 << Int(slotsCode), lowRate: field & lowRateBit != 0))
            cursor += length
        }
        guard cursor == data.count else { throw AudioPacketError.malformedEntries }
        return AudioDatagram(
            codec: codec, flags: flags, sequence: sequence, sampleTime: sampleTime, source: source,
            primaryCount: primaryCount, profile: profile, entries: entries)
    }
}

/// Loss recovery by redundancy (single toggle).
///
/// Every frame is sent again, as a redundant entry, at fixed frame offsets
/// later; the offsets depend on the frame's codec. A copy `k` frames back
/// recovers any run of up to `k` consecutive lost datagrams, as long as the
/// jitter buffer still holds the slot when the copy arrives (k × 5 ms after
/// the primary). The packer is codec-agnostic: entries are packed greedily
/// into datagrams of at most `AudioFormat.maxDatagramBytes`, so a compact
/// codec gets "current + previous N frames" in one datagram while PCM16
/// (960 B per frame) sends the copy as a second datagram — a delayed
/// duplicate, about 3.3 Mbit/s in total.
public enum AudioRedundancy {
    /// Master switch for sending redundant copies.
    public static let enabled = true
    /// PCM16: one copy 3 × 5 ms = 15 ms later (only one 960 B frame fits a
    /// datagram), recovering runs of up to three lost datagrams.
    public static let pcmOffsets: [Int] = [3]
    /// Opus: every datagram carries the previous N = 4 frames (offsets
    /// 1...4), so each frame travels in five datagrams and any loss run of
    /// up to 4 datagrams (20 ms) is recovered, the first copy arriving only
    /// 5 ms after the primary. CBR keeps the size fixed: 24 + 5 × (3 + 120) =
    /// 639 B at 192 kbit/s (≈ 1.07 Mbit/s with UDP/IP headers), 439 B at
    /// 128 kbit/s — both far below the 1200 B budget, which would allow
    /// N = 8 at 192 kbit/s; 4 balances burst coverage against airtime.
    public static let opusOffsets: [Int] = [1, 2, 3, 4]

    /// Offsets at which a frame of `codec` is repeated.
    public static func offsets(for codec: AudioCodec) -> [Int] {
        switch codec {
        case .pcm16: pcmOffsets
        case .opus: opusOffsets
        }
    }

    /// The farthest offset of any codec (LAN layout): how long a redundant
    /// copy can trail its primary.
    public static var maxOffset: Int {
        (pcmOffsets + opusOffsets).max() ?? 0
    }
}

/// How frames are grouped into datagrams and repeated (see `StreamProfile`).
public struct DatagramLayout: Equatable, Sendable {
    /// Consecutive primary frames per datagram.
    public var framesPerDatagram: Int
    /// Redundant-copy offsets, relative to the datagram's newest frame.
    public var pcmOffsets: [Int]
    public var opusOffsets: [Int]

    public init(framesPerDatagram: Int, pcmOffsets: [Int], opusOffsets: [Int]) {
        precondition((1...AudioDatagram.maxPrimaryCount).contains(framesPerDatagram), "1...8 frames")
        precondition(
            (pcmOffsets + opusOffsets).allSatisfy { (1...255).contains($0) }, "offsets in 1...255")
        precondition(opusOffsets.allSatisfy { $0 >= framesPerDatagram }, "copies must precede the primaries")
        self.framesPerDatagram = framesPerDatagram
        self.pcmOffsets = pcmOffsets.sorted()
        self.opusOffsets = opusOffsets.sorted()
    }

    /// One frame per datagram, the `AudioRedundancy` copies (none when
    /// redundancy is disabled).
    public static let lan = DatagramLayout(
        framesPerDatagram: 1,
        pcmOffsets: AudioRedundancy.enabled ? AudioRedundancy.pcmOffsets : [],
        opusOffsets: AudioRedundancy.enabled ? AudioRedundancy.opusOffsets : [])

    /// One 20 ms Opus frame per datagram (one datagram per 20 ms, as
    /// before), each datagram repeating the previous two frames (offsets 4
    /// and 8 slots) as low-rate copies (`StreamEncoding.copyBitrate`): N = 2
    /// redundancy, loss runs of two datagrams (40 ms) recovered, 24 + 3 + 240
    /// + 2 × (3 + 60) = 393 B at Opus 96. A 5 ms frame on WAN (the remainder
    /// of a 20 ms group cut short by a switch) gets the same two offsets.
    public static let wan = DatagramLayout(
        framesPerDatagram: 1, pcmOffsets: AudioRedundancy.pcmOffsets,
        opusOffsets: AudioRedundancy.enabled ? [4, 8] : [])

    func offsets(for codec: AudioCodec) -> [Int] {
        switch codec {
        case .pcm16: pcmOffsets
        case .opus: opusOffsets
        }
    }

    public var maxOffset: Int {
        (pcmOffsets + opusOffsets).max() ?? 0
    }
}

/// Turns a stream of frames into datagrams with redundant copies (see
/// `AudioRedundancy`, `DatagramLayout`). Every datagram's entries share its
/// header codec: when the stream switches codec, copies of the frames
/// before the switch go out in their own redundancy-only datagram of their
/// codec. With a multi-frame layout, Opus frames are held until the group
/// is complete; a codec switch, a discontinuity or a profile change sends
/// the incomplete group first, so frames always leave in sequence order.
/// Not thread-safe; owned by one queue.
public struct RedundancyPacker: Sendable {
    private var lanLayout: DatagramLayout
    private var wanLayout: DatagramLayout
    private let maxDatagramBytes: Int
    /// Frames already sent as primaries, newest last (cleared at a
    /// discontinuity: frames of a previous run are never repeated into a new
    /// one).
    private var history: [AudioPacket] = []
    /// Opus frames waiting for their group to fill.
    private var pending: [AudioPacket] = []
    /// Stamped into every datagram's header (`AudioDatagram.source`).
    public var sourceTag: UInt32 = 0
    /// The profile marked in every datagram; it picks the layout. Changing
    /// it takes effect from the next frame (use `setProfile` to also get the
    /// held frames out at once).
    public var profile: StreamProfile = .lan

    /// The production packer: `DatagramLayout.lan` / `.wan` per profile.
    public init(maxDatagramBytes: Int = AudioFormat.maxDatagramBytes) {
        self.init(lan: .lan, wan: .wan, maxDatagramBytes: maxDatagramBytes)
    }

    /// A single-frame packer that repeats frames of every codec at `offsets`.
    public init(offsets: [Int], maxDatagramBytes: Int = AudioFormat.maxDatagramBytes) {
        self.init(pcmOffsets: offsets, opusOffsets: offsets, maxDatagramBytes: maxDatagramBytes)
    }

    public init(pcmOffsets: [Int], opusOffsets: [Int], maxDatagramBytes: Int = AudioFormat.maxDatagramBytes) {
        let layout = DatagramLayout(framesPerDatagram: 1, pcmOffsets: pcmOffsets, opusOffsets: opusOffsets)
        self.init(lan: layout, wan: layout, maxDatagramBytes: maxDatagramBytes)
    }

    public init(lan: DatagramLayout, wan: DatagramLayout, maxDatagramBytes: Int = AudioFormat.maxDatagramBytes) {
        lanLayout = lan
        wanLayout = wan
        self.maxDatagramBytes = maxDatagramBytes
        history.reserveCapacity(historyDepth + 1)
        pending.reserveCapacity(AudioDatagram.maxPrimaryCount)
    }

    private var historyDepth: Int {
        max(lanLayout.maxOffset, wanLayout.maxOffset)
    }

    private var layout: DatagramLayout {
        profile == .wan ? wanLayout : lanLayout
    }

    /// The layout for `frame`: the profile's, except that a multi-slot
    /// (20 ms) frame always takes the WAN copy offsets — the encoder and the
    /// profile mark switch on separate atomics, so the first 20 ms frame can
    /// reach a packer that still marks LAN.
    private func layout(for frame: AudioPacket) -> DatagramLayout {
        frame.frameSlots > 1 ? wanLayout : layout
    }

    public mutating func reset() {
        history.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
    }

    /// Frames held for an incomplete group.
    public var pendingCount: Int { pending.count }

    /// Switches the profile; returns the held frames' datagram (sent under
    /// the old profile) if any.
    public mutating func setProfile(_ newProfile: StreamProfile) -> [Data] {
        guard newProfile != profile else { return [] }
        let out = flush()
        profile = newProfile
        return out
    }

    /// Sends the held frames now (an incomplete group).
    public mutating func flush() -> [Data] {
        guard !pending.isEmpty else { return [] }
        let group = pending
        pending.removeAll(keepingCapacity: true)
        return emit(group, layout: layout)
    }

    /// The datagrams to send for `frame`, in send order: the primaries first
    /// (with as many same-codec redundant entries as fit, nearest first),
    /// then redundancy-only datagrams for the copies that did not fit or
    /// belong to another codec. Empty while a group is still filling.
    public mutating func pack(_ frame: AudioPacket) -> [Data] {
        var out: [Data] = []
        let layout = layout(for: frame)
        let grouped = layout.framesPerDatagram > 1 && frame.codec == .opus && frame.frameSlots == 1
        if !pending.isEmpty,
            !grouped || frame.codec != pending[0].codec || frame.flags.contains(.discontinuity)
        {
            out += flush()
        }
        if frame.flags.contains(.discontinuity) {
            history.removeAll(keepingCapacity: true)
        }
        if grouped {
            pending.append(frame)
            if pending.count >= layout.framesPerDatagram {
                out += flush()
            }
        } else {
            out += emit([frame], layout: layout)
        }
        return out
    }

    /// Datagrams for consecutive `primaries` (oldest first) plus the copies
    /// due with them; then records the primaries in the history.
    private mutating func emit(_ primaries: [AudioPacket], layout: DatagramLayout) -> [Data] {
        let reference = primaries[primaries.count - 1]
        let primaryCount = primaries.count
        // Nearest first: history is newest last.
        var redundant: [AudioPacket] = []
        for candidate in history.reversed() {
            let distance = reference.sequence &- candidate.sequence
            if distance <= UInt32(UInt8.max), Int(distance) >= primaryCount,
                layout.offsets(for: candidate.codec).contains(Int(distance))
            {
                redundant.append(candidate)
            }
        }

        var datagrams: [Data] = []
        var current = AudioDatagram(primaries: primaries, redundant: [], source: sourceTag, profile: profile)
        var size = AudioDatagram.encodedSize(payloadSizes: primaries.map(\.payload.count))
        for copy in redundant {
            let entry = AudioDatagram.Entry.copy(copy, reference: reference.sequence)
            let added = AudioDatagram.entryHeaderSize + entry.payload.count
            if copy.codec != current.codec || size + added > maxDatagramBytes, !current.entries.isEmpty {
                datagrams.append(current.encoded())
                current = AudioDatagram(
                    codec: copy.codec, flags: [], sequence: reference.sequence,
                    sampleTime: reference.sampleTime, source: sourceTag, primaryCount: primaryCount,
                    profile: profile, entries: [])
                size = AudioDatagram.headerSize
            }
            current.entries.append(entry)
            size += added
        }
        datagrams.append(current.encoded())

        let depth = historyDepth
        if depth > 0 {
            history.append(contentsOf: primaries)
            if history.count > depth {
                history.removeFirst(history.count - depth)
            }
        }
        return datagrams
    }
}

/// RFC 1982 serial-number arithmetic for `UInt32` sequences: true when `a`
/// follows `b`, correct across the `UInt32.max -> 0` wrap-around.
public func sequenceIsAfter(_ a: UInt32, _ b: UInt32) -> Bool {
    a != b && Int32(bitPattern: a &- b) > 0
}
