import Foundation

/// Detects a playout path that has silently stopped consuming audio: packets
/// keep arriving, but no frame has been played for `stallSeconds`. That is
/// the signature of an audio engine that was stopped behind the app's back
/// (interruption, route or configuration change, media-services reset) —
/// the network side keeps filling the jitter buffer while nothing pulls it.
///
/// Pure value type with injected time and counters (cumulative `received` /
/// `played` from `JitterBufferStats`, `renderCalls` from the render
/// callback), so the policy is unit-testable. Call `evaluate` periodically
/// (every 250 ms is plenty); after acting on `.restart`, call
/// `recordRestart` so the next attempt backs off.
///
/// A stall needs continuous evidence: it starts at the first evaluation in
/// which packets arrived but none was played, and ends as soon as a frame is
/// played or an evaluation sees no arrivals at all. Legitimate prebuffering
/// (at most the target depth, ≤ 400 ms in the safe mode) therefore never
/// reaches the 1 s threshold. Repeated restarts that do not bring playback
/// back are spaced out exponentially (1, 2, 4, … s, capped), so a session
/// that cannot be activated (a phone call in progress, a background start
/// the system refuses) is retried without spinning.
public struct PlaybackWatchdog: Sendable {
    public struct Config: Sendable, Equatable {
        /// Packets arriving with no frame played for this long is a stall.
        public var stallSeconds: TimeInterval = 1.0
        /// Minimum spacing after the first restart; doubles per consecutive
        /// restart that did not bring playback back.
        public var initialBackoffSeconds: TimeInterval = 1.0
        /// Upper bound of the restart spacing.
        public var maxBackoffSeconds: TimeInterval = 30.0

        public init() {}
    }

    /// Why the playout path is considered stalled.
    public enum StallReason: Sendable, Equatable {
        /// The render callback is not being called: the engine is stopped.
        case renderStopped
        /// The render callback runs, but no packet reaches playout (e.g. every
        /// arrival is classified as late after a sender restart).
        case nothingPlayable
    }

    public enum Verdict: Sendable, Equatable {
        /// Frames are being played, or no packets are arriving.
        case healthy
        /// Packets arrive but nothing has played for less than the threshold.
        case suspect
        /// Stalled, but the previous restart is too recent to try again.
        case backingOff
        /// Stalled past the threshold: restart the playout path.
        case restart(StallReason)
    }

    public let config: Config
    private var lastReceived: Int?
    private var lastPlayed = 0
    private var lastRenderCalls = 0
    /// Render calls seen during the current stall.
    private var renderCallsDuringStall = 0
    private var stalledSince: TimeInterval?
    private var nextRestartAllowedAt: TimeInterval = -.infinity
    /// Restarts since playback last made progress; drives the backoff.
    public private(set) var consecutiveRestarts = 0

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Feeds the current cumulative counters observed at `now` (seconds on a
    /// monotonic clock) and returns what the caller should do.
    public mutating func evaluate(
        now: TimeInterval,
        received: Int,
        played: Int,
        renderCalls: Int
    ) -> Verdict {
        guard let previousReceived = lastReceived,
            received >= previousReceived, played >= lastPlayed, renderCalls >= lastRenderCalls
        else {
            // First sample, or the counters were reset: take a new baseline.
            lastReceived = received
            lastPlayed = played
            lastRenderCalls = renderCalls
            stalledSince = nil
            return .healthy
        }
        let arrived = received > previousReceived
        let progressed = played > lastPlayed
        let rendered = renderCalls - lastRenderCalls
        lastReceived = received
        lastPlayed = played
        lastRenderCalls = renderCalls

        if progressed {
            stalledSince = nil
            consecutiveRestarts = 0
            return .healthy
        }
        guard arrived else {
            // Nothing arriving and nothing playing: idle, not stalled.
            stalledSince = nil
            return .healthy
        }
        guard let since = stalledSince else {
            stalledSince = now
            renderCallsDuringStall = rendered
            return .suspect
        }
        renderCallsDuringStall += rendered
        guard now - since >= config.stallSeconds else { return .suspect }
        guard now >= nextRestartAllowedAt else { return .backingOff }
        return .restart(renderCallsDuringStall > 0 ? .nothingPlayable : .renderStopped)
    }

    /// Records that the caller restarted (or tried to restart) the playout
    /// path at `now`: the stall clock starts over and the next restart is
    /// allowed only after the current backoff.
    public mutating func recordRestart(now: TimeInterval) {
        let backoff = min(
            config.initialBackoffSeconds * pow(2, Double(consecutiveRestarts)),
            config.maxBackoffSeconds)
        consecutiveRestarts += 1
        nextRestartAllowedAt = now + backoff
        stalledSince = nil
    }
}
