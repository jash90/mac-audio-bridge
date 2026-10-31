import Foundation

/// Which audio sources the phone's receiver lets through (see `SourceGate`).
public enum SourceGateMode: Equatable, Sendable {
    /// Only this source tag.
    case locked(UInt32)
    /// Nothing is active: adopt the first stream whose tag is not excluded
    /// (sources the phone released or disconnected).
    case adoptAny(excluding: Set<UInt32>)
}

/// Phone-side arbitration between Macs: the receiver plays exactly one
/// source. Pure state machine — the app feeds it Bonjour presence, control
/// connection state, the Macs' messages and user taps, and carries out the
/// returned `Effect`s (control messages) and `gateMode` (audio filter).
///
/// Rules ("the newest explicit action wins", in the order events reach the
/// phone):
/// - `userConnect(A)`: A becomes active and is sent `connect`; the previous
///   active source and every other source reporting it streams to this phone
///   are sent `release(byName: A)`.
/// - `claimReceived(B)` (B's user selected our output on the Mac): the same,
///   without `connect` (B already streams).
/// - `userDisconnect(A)`: nothing active, A is sent `disconnect`.
/// - A status saying a source streams to us while another one is active (or
///   it was released) gets that source a `release` — once per streaming run.
/// - A status saying a source streams to us while nothing is active adopts
///   it (a Mac that was already streaming when the phone app started).
/// - The active source stopping on its own (its status turns not-streaming
///   after it streamed) or going offline leaves nothing active; the last
///   used source is kept for one-tap `reconnectLast`.
/// - Audio from a tag the gate adopted (`audioAdopted`) makes that source
///   active when its status does not contradict it; an unknown tag (a Mac
///   without a control connection) is kept locked until `audioStopped`.
public struct SourceArbiter: Equatable, Sendable {
    public struct Source: Equatable, Sendable, Identifiable {
        public let id: String
        public var name: String
        public var tag: UInt32
        /// Listed by the Bonjour browser.
        public var visible: Bool
        /// The control connection is up (hello sent).
        public var connected: Bool
        /// The latest status, nil until one arrives (and after going offline).
        public var status: SourceStatus?
        /// A `release`/`disconnect` was sent and the source has not reported
        /// stopping yet (suppresses repeated releases).
        public var releaseRequested: Bool
        /// Reported streaming to us since it became active.
        public var streamedSinceActivation: Bool

        public var isOnline: Bool { visible || connected }
        public var isStreamingToUs: Bool { status?.streamingToYou == true }

        init(id: String, name: String) {
            self.id = id
            self.name = name
            tag = SourceTag.make(sourceID: id)
            visible = false
            connected = false
            status = nil
            releaseRequested = false
            streamedSinceActivation = false
        }
    }

    public enum Effect: Equatable, Sendable {
        case send(to: String, ControlMessage)
    }

    public private(set) var sources: [String: Source] = [:]
    public private(set) var activeID: String?
    public private(set) var lastUsedID: String?
    /// A stream the gate adopted whose tag matches no known source.
    public private(set) var adoptedUnknownTag: UInt32?
    /// Tags of sources the phone released or disconnected; not adopted
    /// again until claimed or connected.
    public private(set) var excludedTags: Set<UInt32> = []

    /// - Parameter lastUsed: the persisted last used source, listed (offline)
    ///   so it can be offered for reconnect before it is discovered.
    public init(lastUsed: (id: String, name: String)? = nil) {
        if let lastUsed {
            sources[lastUsed.id] = Source(id: lastUsed.id, name: lastUsed.name)
            lastUsedID = lastUsed.id
        }
    }

    public var active: Source? { activeID.flatMap { sources[$0] } }
    public var lastUsed: Source? { lastUsedID.flatMap { sources[$0] } }

    /// Sources for the list: online ones plus the last used, by name.
    public var listed: [Source] {
        sources.values
            .filter { $0.isOnline || $0.id == lastUsedID || $0.id == activeID }
            .sorted { ($0.name.localizedLowercase, $0.id) < ($1.name.localizedLowercase, $1.id) }
    }

    /// What the receiver's audio gate must let through.
    public var gateMode: SourceGateMode {
        if let active { return .locked(active.tag) }
        if let adoptedUnknownTag { return .locked(adoptedUnknownTag) }
        return .adoptAny(excluding: excludedTags)
    }

    // MARK: - Presence

    public mutating func sourceSeen(id: String, name: String) {
        var source = sources[id] ?? Source(id: id, name: name)
        source.visible = true
        if source.status == nil { source.name = name }
        sources[id] = source
    }

    public mutating func sourceVanished(id: String) {
        sources[id]?.visible = false
        refreshPresence(id)
    }

    public mutating func controlConnected(id: String) {
        sources[id]?.connected = true
        // A new connection: the previous release request may have been lost.
        sources[id]?.releaseRequested = false
    }

    public mutating func controlDisconnected(id: String) {
        sources[id]?.connected = false
        refreshPresence(id)
    }

    /// Offline (neither browsed nor connected): forget its status, end it as
    /// the active source, drop it unless it is the last used one.
    private mutating func refreshPresence(_ id: String) {
        guard let source = sources[id], !source.isOnline else { return }
        sources[id]?.status = nil
        sources[id]?.releaseRequested = false
        if activeID == id {
            activeID = nil
        }
        if lastUsedID != id {
            sources[id] = nil
        }
    }

    // MARK: - Messages from Macs

    public mutating func statusReceived(id: String, _ status: SourceStatus) -> [Effect] {
        guard var source = sources[id] else { return [] }
        source.name = status.name
        source.tag = status.sourceTag
        source.status = status
        sources[id] = source

        guard status.streamingToYou else {
            sources[id]?.releaseRequested = false
            if activeID == id, source.streamedSinceActivation {
                // Stopped on the Mac side (output switched away).
                activeID = nil
            }
            return []
        }
        if activeID == id {
            sources[id]?.streamedSinceActivation = true
            return []
        }
        if activeID == nil, !excludedTags.contains(source.tag) {
            // Already streaming when we learnt about it: adopt.
            let effects = activate(id, sendConnect: false)
            sources[id]?.streamedSinceActivation = true
            return effects
        }
        // Someone else is active, or we released this one: ask it (once
        // per streaming run) to stop.
        guard !source.releaseRequested else { return [] }
        sources[id]?.releaseRequested = true
        let byName = active?.name
        return [.send(to: id, byName.map { .release(byName: $0) } ?? .disconnect)]
    }

    public mutating func claimReceived(id: String) -> [Effect] {
        guard sources[id] != nil else { return [] }
        return activate(id, sendConnect: false)
    }

    // MARK: - Audio gate

    /// The gate (in `.adoptAny`) let a new stream through.
    public mutating func audioAdopted(tag: UInt32) {
        guard activeID == nil, !excludedTags.contains(tag) else { return }
        if let source = sources.values.first(where: { $0.tag == tag }) {
            // A stale datagram of a source that just reported stopping must
            // not make it active again.
            if let status = source.status, !status.streamingToYou { return }
            _ = activateQuietly(source.id)
            sources[source.id]?.streamedSinceActivation = source.status != nil
        } else {
            adoptedUnknownTag = tag
        }
    }

    /// The adopted unknown stream went silent: open the gate again.
    public mutating func audioStopped(tag: UInt32) {
        if adoptedUnknownTag == tag {
            adoptedUnknownTag = nil
        }
    }

    // MARK: - User actions

    /// Needs the control connection: `connect` must reach the Mac.
    public mutating func userConnect(id: String) -> [Effect] {
        guard let source = sources[id], source.connected else { return [] }
        return activate(id, sendConnect: true)
    }

    public mutating func userDisconnect(id: String) -> [Effect] {
        guard let source = sources[id] else { return [] }
        if activeID == id {
            activeID = nil
        }
        excludedTags.insert(source.tag)
        sources[id]?.releaseRequested = true
        sources[id]?.streamedSinceActivation = false
        return [.send(to: id, .disconnect)]
    }

    /// One-tap reconnect to the last used source, when it is connected.
    public mutating func reconnectLast() -> [Effect] {
        guard let lastUsedID else { return [] }
        return userConnect(id: lastUsedID)
    }

    // MARK: - Activation

    private mutating func activate(_ id: String, sendConnect: Bool) -> [Effect] {
        let previous = activeID
        guard let name = activateQuietly(id) else { return [] }
        var effects: [Effect] = []
        for other in sources.values.sorted(by: { $0.id < $1.id }) where other.id != id {
            let wasActive = other.id == previous
            guard other.connected, wasActive || other.isStreamingToUs else { continue }
            effects.append(.send(to: other.id, .release(byName: name)))
            sources[other.id]?.releaseRequested = true
            sources[other.id]?.streamedSinceActivation = false
            excludedTags.insert(other.tag)
        }
        if sendConnect {
            effects.append(.send(to: id, .connect))
        }
        return effects
    }

    /// Makes `id` active and last used; returns its name.
    private mutating func activateQuietly(_ id: String) -> String? {
        guard let source = sources[id] else { return nil }
        // Only a status received from now on counts: one in flight may
        // predate the action that made it active.
        sources[id]?.streamedSinceActivation = false
        activeID = id
        lastUsedID = id
        adoptedUnknownTag = nil
        excludedTags.remove(source.tag)
        sources[id]?.releaseRequested = false
        return source.name
    }
}

/// The receiver-side audio filter: decides, per datagram on the network
/// queue, whether it belongs to the source being played. Switching to a new
/// tag requires a datagram carrying a primary frame, which the receiver then
/// marks as a discontinuity — the jitter buffer resets and the reader
/// crossfades (the M2.8 fade), so a source switch never clicks.
public struct SourceGate: Equatable, Sendable {
    public enum Admission: Equatable, Sendable {
        case drop
        /// Let through. `newStream`: the first datagram of a different
        /// stream (mark it a discontinuity, which resets the buffer).
        /// `adopted`: the gate picked the stream itself in `.adoptAny`
        /// (report it to the arbiter).
        case accept(newStream: Bool, adopted: Bool)
    }

    public private(set) var mode: SourceGateMode
    /// Tag of the stream currently let through.
    public private(set) var currentTag: UInt32?

    public init(mode: SourceGateMode = .adoptAny(excluding: [])) {
        self.mode = mode
    }

    public mutating func setMode(_ newMode: SourceGateMode) {
        mode = newMode
    }

    public mutating func admit(tag: UInt32, hasPrimary: Bool) -> Admission {
        let isNew = currentTag != tag
        switch mode {
        case .locked(let allowed):
            guard tag == allowed, !isNew || hasPrimary else { return .drop }
            currentTag = tag
            return .accept(newStream: isNew, adopted: false)
        case .adoptAny(let excluded):
            guard !excluded.contains(tag), !isNew || hasPrimary else { return .drop }
            // Lock onto the first stream; the arbiter confirms or reopens.
            mode = .locked(tag)
            currentTag = tag
            return .accept(newStream: isNew, adopted: true)
        }
    }
}
