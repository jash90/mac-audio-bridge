import Foundation

/// The phone's microphone stream ("Talk through iPhone"): 48 kHz mono,
/// 10 ms frames, phone → Mac on the existing UDP flow (the reply direction
/// of the Mac's audio stream, where the keepalives travel too), so it needs
/// no new port, discovery or firewall rule and works over Tailscale.
public enum MicFormat {
    /// Stream id in the mic datagram header (the Mac → phone playback stream
    /// is stream 0, carried by `AudioDatagram` version 4).
    public static let streamID: UInt8 = 1
    public static let sampleRate: Double = 48_000
    public static let frameDurationMs = 10
    public static var frameDuration: TimeInterval { Double(frameDurationMs) / 1000 }
    /// Mono samples per frame (480 at 10 ms).
    public static let samplesPerFrame = 480
    /// PCM16 mono frame payload (the fallback codec): 960 B.
    public static let pcm16FrameBytes = samplesPerFrame * MemoryLayout<Int16>.size
    /// Opus CBR bitrates per profile: 50 B / 40 B per 10 ms frame.
    public static let lanBitrate = 40_000
    public static let wanBitrate = 32_000

    public static func bitrate(for profile: StreamProfile) -> Int {
        profile == .wan ? wanBitrate : lanBitrate
    }

    /// Whole 10 ms frames covering `milliseconds` (rounded up, at least 1).
    public static func frames(milliseconds: Double) -> Int {
        max(1, Int((milliseconds / Double(frameDurationMs) - 1e-9).rounded(.up)))
    }
}

/// Per-datagram flags of a mic datagram.
public struct MicDatagramFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// The oldest primary starts a new stream (arm, codec change, encoder
    /// reset): the Mac resets its jitter buffer and decoder.
    public static let discontinuity = MicDatagramFlags(rawValue: 1 << 0)
    /// The phone's mute is on (the frames carry silence).
    public static let muted = MicDatagramFlags(rawValue: 1 << 1)
}

/// One mic datagram (phone → Mac): a 24-byte big-endian header and one or
/// more codec frames, the same entry layout as `AudioDatagram`.
///
///     offset  size  field
///        0      4   magic "MABA" (0x4D414241)
///        4      1   version (5: the version that adds stream ids)
///        5      1   stream id (`MicFormat.streamID` = 1)
///        6      1   codec (`AudioCodec` raw value)
///        7      1   bits 0–3: `MicDatagramFlags`; bits 4–6: primary
///                   count − 1 (1...8); bit 7: profile (0 = LAN, 1 = WAN)
///        8      4   reference sequence (the newest primary, wrapping)
///       12      8   reference sampleTime (48 kHz samples)
///       20      2   samples per frame (480)
///       22      1   entry count (≥ 1)
///       23      1   reserved (0)
///       24      …   entries: back offset k (1), length (2), payload
///
/// The playback stream (Mac → phone) stays `AudioDatagram` version 4, which
/// rejects version 5; the Mac's keepalive-reading socket tells the two
/// directions apart by the version byte, and keepalives by size and magic.
public struct MicDatagram: Sendable, Equatable {
    public static let headerSize = 24
    public static let magic: UInt32 = AudioDatagram.magic
    public static let version: UInt8 = 5
    public static let maxPrimaryCount = 8

    public var codec: AudioCodec
    public var flags: MicDatagramFlags
    public var sequence: UInt32
    public var sampleTime: UInt64
    public var samplesPerFrame: Int
    public var primaryCount: Int
    public var profile: StreamProfile
    public var entries: [AudioDatagram.Entry]

    public init(
        codec: AudioCodec, flags: MicDatagramFlags, sequence: UInt32, sampleTime: UInt64,
        samplesPerFrame: Int = MicFormat.samplesPerFrame, primaryCount: Int = 1,
        profile: StreamProfile = .lan, entries: [AudioDatagram.Entry]
    ) {
        self.codec = codec
        self.flags = flags
        self.sequence = sequence
        self.sampleTime = sampleTime
        self.samplesPerFrame = samplesPerFrame
        self.primaryCount = primaryCount
        self.profile = profile
        self.entries = entries
    }

    /// Whether `data` looks like a mic datagram (magic + version + stream
    /// id), without decoding it.
    public static func isMicDatagram(_ data: Data) -> Bool {
        guard data.count >= headerSize else { return false }
        let base = data.startIndex
        return data[base] == 0x4D && data[base + 1] == 0x41 && data[base + 2] == 0x42 && data[base + 3] == 0x41
            && data[base + 4] == version && data[base + 5] == MicFormat.streamID
    }

    /// The frames carried: primaries oldest first, then the redundant copies
    /// in entry order (as `AudioPacket`s; `.discontinuity` on the oldest
    /// primary when the datagram has it).
    public func packets() -> [AudioPacket] {
        let oldestPrimary = UInt8(primaryCount - 1)
        func packet(_ entry: AudioDatagram.Entry) -> AudioPacket {
            let offset = UInt32(entry.offset)
            return AudioPacket(
                codec: codec,
                flags: entry.offset == oldestPrimary && flags.contains(.discontinuity) ? .discontinuity : [],
                sequence: sequence &- offset,
                sampleTime: sampleTime &- UInt64(offset) * UInt64(samplesPerFrame),
                payload: entry.payload,
                isRedundant: Int(entry.offset) >= primaryCount)
        }
        let primaries = entries.filter { Int($0.offset) < primaryCount }.sorted { $0.offset > $1.offset }
        let copies = entries.filter { Int($0.offset) >= primaryCount }
        return primaries.map(packet) + copies.map(packet)
    }

    public var encodedSize: Int {
        AudioDatagram.encodedSize(payloadSizes: entries.map(\.payload.count))
    }

    public func encoded() -> Data {
        precondition(!entries.isEmpty && entries.count <= Int(UInt8.max), "1...255 entries")
        precondition((1...Self.maxPrimaryCount).contains(primaryCount), "1...8 primaries")
        var data = Data(capacity: encodedSize)
        func append32(_ value: UInt32) {
            for shift in stride(from: 24, through: 0, by: -8) { data.append(UInt8((value >> UInt32(shift)) & 0xFF)) }
        }
        append32(Self.magic)
        data.append(Self.version)
        data.append(MicFormat.streamID)
        data.append(codec.rawValue)
        data.append((flags.rawValue & 0x0F) | (UInt8(primaryCount - 1) << 4) | (profile == .wan ? 0x80 : 0))
        append32(sequence)
        append32(UInt32(truncatingIfNeeded: sampleTime >> 32))
        append32(UInt32(truncatingIfNeeded: sampleTime))
        data.append(UInt8((samplesPerFrame >> 8) & 0xFF))
        data.append(UInt8(samplesPerFrame & 0xFF))
        data.append(UInt8(entries.count))
        data.append(0)
        for entry in entries {
            precondition(entry.payload.count <= Int(UInt16.max), "entry payload too large")
            data.append(entry.offset)
            data.append(UInt8((entry.payload.count >> 8) & 0xFF))
            data.append(UInt8(entry.payload.count & 0xFF))
            data.append(entry.payload)
        }
        return data
    }

    /// Decodes a mic datagram; entry payloads are slices of `data`.
    public static func decode(_ data: Data) throws(AudioPacketError) -> MicDatagram {
        guard data.count >= headerSize else { throw .tooShort }
        let base = data.startIndex
        func byte(_ offset: Int) -> UInt8 { data[base + offset] }
        func read32(_ offset: Int) -> UInt32 {
            UInt32(byte(offset)) << 24 | UInt32(byte(offset + 1)) << 16
                | UInt32(byte(offset + 2)) << 8 | UInt32(byte(offset + 3))
        }
        guard read32(0) == magic else { throw .badMagic }
        guard byte(4) == version else { throw .unsupportedVersion(byte(4)) }
        guard byte(5) == MicFormat.streamID else { throw .malformedEntries }
        guard let codec = AudioCodec(rawValue: byte(6)) else { throw .unknownCodec(byte(6)) }
        let flagsByte = byte(7)
        let samplesPerFrame = Int(byte(20)) << 8 | Int(byte(21))
        let entryCount = Int(byte(22))
        guard entryCount > 0, samplesPerFrame > 0 else { throw .malformedEntries }
        var entries: [AudioDatagram.Entry] = []
        entries.reserveCapacity(entryCount)
        var cursor = headerSize
        var seen = Set<UInt8>()
        for _ in 0..<entryCount {
            guard data.count - cursor >= AudioDatagram.entryHeaderSize else { throw .malformedEntries }
            let offset = byte(cursor)
            let length = Int(byte(cursor + 1)) << 8 | Int(byte(cursor + 2))
            cursor += AudioDatagram.entryHeaderSize
            guard data.count - cursor >= length, seen.insert(offset).inserted else { throw .malformedEntries }
            entries.append(AudioDatagram.Entry(offset: offset, payload: data[(base + cursor)..<(base + cursor + length)]))
            cursor += length
        }
        guard cursor == data.count else { throw .malformedEntries }
        return MicDatagram(
            codec: codec, flags: MicDatagramFlags(rawValue: flagsByte & 0x0F), sequence: read32(8),
            sampleTime: UInt64(read32(12)) << 32 | UInt64(read32(16)), samplesPerFrame: samplesPerFrame,
            primaryCount: Int((flagsByte & 0x70) >> 4) + 1,
            profile: flagsByte & 0x80 != 0 ? .wan : .lan, entries: entries)
    }
}

/// Groups mic frames into datagrams with redundant copies.
///
/// - LAN: one 10 ms frame per datagram (100 pps) plus copies of the three
///   previous frames, so any run of up to three lost datagrams (30 ms) is
///   recovered: 24 + 4 × (3 + 50) = 236 B at 40 kbit/s.
/// - WAN: two frames per datagram (50 pps) plus copies of the four before
///   them (two datagrams' worth): 24 + 6 × 43 = 282 B at 32 kbit/s.
/// - PCM16 (fallback when Opus cannot be created): one 960 B frame per
///   datagram, no copies (two would not fit in 1200 B).
///
/// Not thread-safe; owned by the phone's mic send queue.
public struct MicPacker: Sendable {
    public static let lanCopyOffsets = [1, 2, 3]
    public static let wanFramesPerDatagram = 2
    public static let wanCopyOffsets = [2, 3, 4, 5]
    /// The farthest copy, in frames (the jitter buffer's loss horizon).
    public static let maxCopyOffset = 5

    private var history: [AudioPacket] = []
    private var pending: [AudioPacket] = []
    private var flags: MicDatagramFlags = []
    public var profile: StreamProfile = .lan
    public var maxDatagramBytes = AudioFormat.maxDatagramBytes

    public init() {
        history.reserveCapacity(Self.maxCopyOffset + 2)
        pending.reserveCapacity(Self.wanFramesPerDatagram)
    }

    public mutating func reset() {
        history.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
    }

    /// The datagrams to send for `frame` (empty while a WAN pair fills).
    /// `muted` marks the datagram (the frames carry silence).
    public mutating func pack(_ frame: AudioPacket, muted: Bool = false) -> [Data] {
        let perDatagram = frame.codec == .opus && profile == .wan ? Self.wanFramesPerDatagram : 1
        var out: [Data] = []
        if !pending.isEmpty,
            pending.count >= perDatagram || pending[0].codec != frame.codec || frame.flags.contains(.discontinuity)
        {
            out += emit()
        }
        if frame.flags.contains(.discontinuity) {
            history.removeAll(keepingCapacity: true)
        }
        flags = muted ? .muted : []
        pending.append(frame)
        if pending.count >= perDatagram {
            out += emit()
        }
        return out
    }

    private mutating func emit() -> [Data] {
        let primaries = pending
        pending.removeAll(keepingCapacity: true)
        let reference = primaries[primaries.count - 1]
        var entries = primaries.reversed().map {
            AudioDatagram.Entry(offset: UInt8(reference.sequence &- $0.sequence), payload: $0.payload)
        }
        var size = AudioDatagram.encodedSize(payloadSizes: entries.map(\.payload.count))
        if reference.codec == .opus {
            let offsets = primaries.count > 1 ? Self.wanCopyOffsets : Self.lanCopyOffsets
            for copy in history.reversed() where copy.codec == reference.codec {
                let distance = Int(reference.sequence &- copy.sequence)
                guard offsets.contains(distance) else { continue }
                let added = AudioDatagram.entryHeaderSize + copy.payload.count
                guard size + added <= maxDatagramBytes else { break }
                entries.append(AudioDatagram.Entry(offset: UInt8(distance), payload: copy.payload))
                size += added
            }
        }
        var datagramFlags = flags
        if primaries[0].flags.contains(.discontinuity) {
            datagramFlags.insert(.discontinuity)
        }
        let datagram = MicDatagram(
            codec: reference.codec, flags: datagramFlags, sequence: reference.sequence,
            sampleTime: reference.sampleTime, primaryCount: primaries.count,
            profile: primaries.count > 1 ? .wan : profile, entries: entries)
        history.append(contentsOf: primaries)
        if history.count > Self.maxCopyOffset {
            history.removeFirst(history.count - Self.maxCopyOffset)
        }
        return [datagram.encoded()]
    }
}

extension JitterBufferConfig {
    /// The Mac's mic jitter buffer: 10 ms frames, a small adaptive target
    /// (p99 delay of the last 10 s + 10 ms, 40–120 ms on the LAN; 80–300 ms
    /// on the WAN profile), no frame-level latency trim (the mic reader's
    /// sample-level drift correction keeps the fill on the target instead),
    /// a loss horizon past the farthest redundant copy.
    public static func mic(_ profile: StreamProfile) -> JitterBufferConfig {
        var config = JitterBufferConfig()
        config.frameDuration = MicFormat.frameDuration
        switch profile {
        case .lan:
            config.minTargetFrames = MicFormat.frames(milliseconds: 40)
            config.maxTargetFrames = MicFormat.frames(milliseconds: 120)
            config.delayWindowSeconds = 10
            config.safetyMargin = 0.010
            config.overflowFrames = config.maxTargetFrames + MicFormat.frames(milliseconds: 60)
        case .wan:
            config.minTargetFrames = MicFormat.frames(milliseconds: 80)
            config.maxTargetFrames = MicFormat.frames(milliseconds: 300)
            config.delayWindowSeconds = 20
            config.safetyMargin = 0.020
            config.overflowFrames = config.maxTargetFrames + MicFormat.frames(milliseconds: 100)
        }
        config.delayQuantile = 0.99
        config.latencyTrimSlackFrames = nil
        config.lossHorizonFrames = MicPacker.maxCopyOffset + 2
        return config
    }
}

/// When the Mac asks the phone for its mic: while an app (Meet, Teams,
/// QuickTime…) has "iPhone Mic (Mac Audio Bridge)" open, plus a grace after
/// it closes (apps reopen the device when the user changes the device
/// picker), so a quick close/reopen does not restart the phone's stream.
public struct MicDemand: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        /// Send `micStart`, run the feeder.
        case start
        /// Send `micStop`, stop the feeder.
        case stop
    }

    public static let defaultStopGrace: TimeInterval = 2

    public let stopGrace: TimeInterval
    /// The phone was asked to send (between `.start` and `.stop`).
    public private(set) var active = false
    /// The device is open by some app right now.
    public private(set) var inUse = false
    private var idleSince: TimeInterval?

    public init(stopGrace: TimeInterval = MicDemand.defaultStopGrace) {
        self.stopGrace = stopGrace
    }

    /// The mic device's `DeviceIsRunningSomewhere` changed (or was polled).
    public mutating func update(inUse running: Bool, now: TimeInterval) -> Action? {
        inUse = running
        if running {
            idleSince = nil
            guard !active else { return nil }
            active = true
            return .start
        }
        guard active else { return nil }
        if idleSince == nil { idleSince = now }
        return tick(now: now)
    }

    /// Ends the grace once it has run out.
    public mutating func tick(now: TimeInterval) -> Action? {
        guard active, !inUse, let since = idleSince, now - since >= stopGrace else { return nil }
        active = false
        idleSince = nil
        return .stop
    }
}
