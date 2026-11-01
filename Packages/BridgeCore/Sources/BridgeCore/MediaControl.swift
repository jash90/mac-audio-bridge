import Foundation

// Playback control of the Mac from the iPhone (control protocol version 2).
//
// Phone → Mac: `ControlMessage.media(MediaCommand)` — play / pause / toggle /
// next / previous for whatever app is Now Playing on the Mac.
// Mac → phone: `ControlMessage.nowPlaying(NowPlayingInfo?)` — what plays on
// the Mac (nil: nothing), sent on change (throttled, `NowPlayingThrottle`)
// and right after a phone's hello.
//
// Both messages need version 2 on the peer. A Mac reports its version in
// `SourceStatus.protocolVersion` (absent = 1); the phone sends `media` only to
// a Mac that reported 2 or later, so a v1 Mac (it closes the connection on an
// envelope version it does not know) never receives one.

/// A playback command for the Mac's Now Playing app.
public enum MediaCommand: String, Codable, CaseIterable, Sendable {
    case play
    case pause
    case togglePlayPause
    case nextTrack
    case previousTrack
}

/// What plays on a Mac (the app that owns Now Playing there).
public struct NowPlayingInfo: Codable, Equatable, Sendable {
    public var title: String
    public var artist: String?
    public var album: String?
    /// The player's display name ("Music", "Spotify", "Google Chrome").
    public var app: String?
    public var isPlaying: Bool
    /// Track length, seconds (nil: unknown / live).
    public var duration: Double?
    /// Position when the message was built, seconds.
    public var elapsed: Double?
    /// Small JPEG (at most `NowPlayingInfo.maxArtworkBytes`).
    public var artwork: Data?
    /// The Mac can send playback commands right now (false: its method needs
    /// a permission, e.g. Accessibility for media keys). The phone then falls
    /// back to muting.
    public var canControl: Bool

    /// Keeps a `nowPlaying` frame far below `ControlProtocol.maxFrameBytes`
    /// (base64 grows by a third).
    public static let maxArtworkBytes = 24 * 1024

    public init(
        title: String, artist: String? = nil, album: String? = nil, app: String? = nil,
        isPlaying: Bool, duration: Double? = nil, elapsed: Double? = nil, artwork: Data? = nil,
        canControl: Bool = true
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.app = app
        self.isPlaying = isPlaying
        self.duration = duration
        self.elapsed = elapsed
        self.artwork = artwork
        self.canControl = canControl
    }

    /// Everything but the position, which moves on its own while playing.
    func sameTrackAndState(as other: NowPlayingInfo) -> Bool {
        var mine = self
        var theirs = other
        mine.elapsed = nil
        theirs.elapsed = nil
        return mine == theirs
    }
}

// MARK: - Mac side: throttling

/// Decides when the Mac sends `nowPlaying`: at once on a real change (track,
/// play state, artwork, a seek), at most once per `minInterval` (a burst
/// collapses into its last value, sent when the interval is over), never for
/// the position merely advancing.
public struct NowPlayingThrottle: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        case send(NowPlayingInfo?)
        /// Changed, but too soon: call `due(now:)` at this uptime.
        case deferred(until: TimeInterval)
        case unchanged
    }

    public let minInterval: TimeInterval
    /// A position this far from the extrapolated one is a seek.
    public let seekTolerance: TimeInterval

    private var lastSent: NowPlayingInfo??
    private var lastSentAt: TimeInterval = -.infinity
    private var pending: NowPlayingInfo??

    public init(minInterval: TimeInterval = 0.5, seekTolerance: TimeInterval = 2) {
        self.minInterval = minInterval
        self.seekTolerance = seekTolerance
    }

    /// A new observation of the Mac's Now Playing state.
    public mutating func offer(_ info: NowPlayingInfo?, now: TimeInterval) -> Decision {
        guard isChange(info, now: now) else {
            pending = nil
            return .unchanged
        }
        if now - lastSentAt >= minInterval {
            return .send(markSent(info, now: now))
        }
        pending = .some(info)
        return .deferred(until: lastSentAt + minInterval)
    }

    /// The deferred value once its time has come (nil: nothing to send yet).
    public mutating func due(now: TimeInterval) -> NowPlayingInfo?? {
        guard let value = pending, now - lastSentAt >= minInterval else { return nil }
        pending = nil
        return .some(markSent(value, now: now))
    }

    /// The last value sent (for a phone that just connected); `.none` before
    /// the first.
    public var current: NowPlayingInfo?? { pending ?? lastSent }

    private mutating func markSent(_ info: NowPlayingInfo?, now: TimeInterval) -> NowPlayingInfo? {
        lastSent = .some(info)
        lastSentAt = now
        pending = nil
        return info
    }

    private func isChange(_ info: NowPlayingInfo?, now: TimeInterval) -> Bool {
        guard let lastSent else { return true }
        switch (lastSent, info) {
        case (nil, nil): return false
        case (nil, _), (_, nil): return true
        case (let old?, let new?):
            guard old.sameTrackAndState(as: new) else { return true }
            guard let oldElapsed = old.elapsed, let newElapsed = new.elapsed else {
                return (old.elapsed == nil) != (new.elapsed == nil)
            }
            let predicted = oldElapsed + (old.isPlaying ? now - lastSentAt : 0)
            return abs(newElapsed - predicted) > seekTolerance
        }
    }
}

// MARK: - Mac side: mediaremote-adapter output

/// Parses the line-delimited JSON of `mediaremote-adapter.pl … stream`
/// (vendored in ThirdParty/mediaremote-adapter): every line is
/// `{"type":"data","diff":Bool,"payload":{…}}`; a non-diff payload replaces
/// the state, a diff payload updates it (a `null` value removes the key).
public struct MediaRemoteAdapterStream: Sendable {
    /// The merged state, decoded.
    public struct Snapshot: Equatable, Sendable {
        public var bundleIdentifier: String?
        public var title: String?
        public var artist: String?
        public var album: String?
        public var isPlaying: Bool
        public var duration: Double?
        /// Position at `timestamp`.
        public var elapsedTime: Double?
        public var timestamp: Date?
        /// Base64 artwork as the adapter sent it (decode lazily, on change).
        public var artworkBase64: String?

        /// Position at `now`, extrapolated while playing.
        public func elapsed(at now: Date) -> Double? {
            guard let elapsedTime else { return nil }
            guard isPlaying, let timestamp else { return elapsedTime }
            let position = elapsedTime + max(0, now.timeIntervalSince(timestamp))
            if let duration, duration > 0 { return min(position, duration) }
            return position
        }
    }

    private var state: [String: JSONValue] = [:]

    public init() {}

    /// Feeds one line; returns the new snapshot (nil: nothing plays, i.e. no
    /// title), or throws for a line that is not an adapter data message.
    public mutating func consume(line: Data) throws(ControlProtocolError) -> Snapshot? {
        guard let message = try? JSONDecoder().decode(Message.self, from: line),
            message.type == "data"
        else { throw .malformed }
        if message.diff {
            for (key, value) in message.payload {
                if case .null = value {
                    state[key] = nil
                } else {
                    state[key] = value
                }
            }
        } else {
            state = message.payload.filter { if case .null = $0.value { false } else { true } }
        }
        return snapshot
    }

    public var snapshot: Snapshot? {
        guard let title = state["title"]?.string, !title.isEmpty else { return nil }
        return Snapshot(
            bundleIdentifier: state["bundleIdentifier"]?.string,
            title: title,
            artist: state["artist"]?.string.flatMap { $0.isEmpty ? nil : $0 },
            album: state["album"]?.string.flatMap { $0.isEmpty ? nil : $0 },
            isPlaying: state["playing"]?.bool ?? false,
            duration: state["duration"]?.number,
            elapsedTime: state["elapsedTime"]?.number,
            timestamp: state["timestamp"]?.string.flatMap(Self.parseDate),
            artworkBase64: state["artworkData"]?.string)
    }

    private static func parseDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    private struct Message: Decodable {
        var type: String
        var diff: Bool
        var payload: [String: JSONValue]
    }

    enum JSONValue: Decodable, Equatable, Sendable {
        case null
        case bool(Bool)
        case number(Double)
        case string(String)
        case other

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else {
                self = .other
            }
        }

        var string: String? { if case .string(let value) = self { value } else { nil } }
        var number: Double? { if case .number(let value) = self { value } else { nil } }
        var bool: Bool? {
            switch self {
            case .bool(let value): value
            case .number(let value): value != 0
            default: nil
            }
        }
    }
}

// MARK: - Phone side: routing remote commands

/// Where a playback command on the phone (lock screen, Control Center,
/// AirPods, the in-app buttons) goes. The Mac's media control is used when
/// the active Mac supports it and reported what plays; otherwise play /
/// pause keep their earlier meaning (unmute / mute the active Mac) and next /
/// previous do nothing.
public enum MediaRoute: Equatable, Sendable {
    case mac(id: String, MediaCommand)
    case setMuted(id: String, Bool)
    case none
}

/// Phone-side Now Playing state of every connected Mac plus the routing
/// decision. Pure; the app feeds it `nowPlaying` messages and connection
/// losses.
public struct MediaControlRouter: Equatable, Sendable {
    public private(set) var nowPlaying: [String: NowPlayingInfo] = [:]

    public init() {}

    public mutating func nowPlayingReceived(id: String, _ info: NowPlayingInfo?) {
        nowPlaying[id] = info
    }

    /// The control connection went away: what it reported is stale.
    public mutating func forget(id: String) {
        nowPlaying[id] = nil
    }

    /// Whether `source` takes playback commands from the phone.
    public func canControl(_ source: SourceArbiter.Source?) -> Bool {
        guard let source, source.connected, let status = source.status,
            (status.protocolVersion ?? 1) >= 2,
            let info = nowPlaying[source.id]
        else { return false }
        return info.canControl
    }

    /// - Parameter active: the arbiter's active source (nil: none).
    public func route(_ command: MediaCommand, active: SourceArbiter.Source?) -> MediaRoute {
        guard let active else { return .none }
        if canControl(active) {
            return .mac(id: active.id, command)
        }
        guard let status = active.status else { return .none }
        switch command {
        case .play: return .setMuted(id: active.id, false)
        case .pause: return .setMuted(id: active.id, true)
        case .togglePlayPause: return .setMuted(id: active.id, !status.muted)
        case .nextTrack, .previousTrack: return .none
        }
    }
}
