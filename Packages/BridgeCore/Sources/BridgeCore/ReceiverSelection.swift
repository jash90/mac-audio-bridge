import Foundation

/// Where the sender streams to.
public enum ReceiverTarget: Hashable, Sendable {
    /// A Bonjour receiver by service name; the system resolves (and on a new
    /// connection re-resolves) its current address.
    case service(String)
    /// A typed-in host, port `ReceiverService.preferredPort`.
    case host(String)

    /// Service name or host, for menus and stats.
    public var displayName: String {
        switch self {
        case .service(let name): name
        case .host(let host): host
        }
    }
}

/// Pure receiver-selection state machine for the sender. Inputs: the live
/// Bonjour browse results, the persisted selection, the manual host and a
/// monotonic clock. Output: `target` (nil = nothing to stream to) and
/// `status` for the menu.
///
/// Precedence: an explicitly chosen host (a typed address or a Tailscale
/// peer picked in the menu) wins; then a stored selection (while it is not
/// visible the status is `.looking`, never a fallback to something else);
/// with no stored selection, a single visible receiver is picked
/// automatically (and stays picked while visible, even if more appear); the
/// manual host is used only when no service is selected that way.
///
/// Internet mode: a receiver whose tailnet addresses are known
/// (`remoteReachable`) stays a valid target while Bonjour cannot see it —
/// the sender's `PathFailover` then streams to its tailnet address. With
/// nothing visible and exactly one such receiver, it is picked
/// automatically.
///
/// A service target that vanishes from the browse results is kept for
/// `serviceLossGrace` seconds: a receiver app restart deregisters and
/// re-registers the same name within about a second, and keeping the target
/// means the stream (and the tap) keep running through it.
public struct ReceiverSelection: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// Nothing visible and no manual host.
        case noReceiver
        /// Several receivers visible, none selected.
        case chooseReceiver(count: Int)
        /// The stored selection is not visible (yet / any more).
        case looking(String)
        /// Streaming target chosen; `automatic` when picked as the only
        /// visible receiver.
        case target(ReceiverTarget, automatic: Bool)
    }

    public static let defaultServiceLossGrace: TimeInterval = 2

    public let serviceLossGrace: TimeInterval
    /// Visible receivers, sorted and de-duplicated (a service seen on several
    /// interfaces is one receiver).
    public private(set) var visibleServices: [String] = []
    public private(set) var storedSelection: String?
    public private(set) var manualHost: String
    /// Host chosen explicitly (overrides every Bonjour receiver).
    public private(set) var storedHost: String?
    /// Receivers reachable without Bonjour (tailnet addresses known).
    public private(set) var remoteReachable: Set<String> = []
    public private(set) var target: ReceiverTarget?
    public private(set) var status: Status = .noReceiver
    /// When the current service target dropped out of the browse results.
    private var targetMissingSince: TimeInterval?

    public init(
        storedSelection: String?,
        manualHost: String,
        storedHost: String? = nil,
        remoteReachable: Set<String> = [],
        serviceLossGrace: TimeInterval = ReceiverSelection.defaultServiceLossGrace,
        now: TimeInterval
    ) {
        self.storedSelection = Self.normalized(storedSelection)
        self.manualHost = manualHost.trimmingCharacters(in: .whitespaces)
        self.storedHost = Self.normalized(storedHost?.trimmingCharacters(in: .whitespaces))
        self.remoteReachable = remoteReachable
        self.serviceLossGrace = serviceLossGrace
        recompute(now: now)
    }

    /// New browse results (the full current set).
    public mutating func updateVisibleServices(_ names: some Sequence<String>, now: TimeInterval) {
        visibleServices = Array(Set(names)).sorted()
        recompute(now: now)
    }

    /// The user picked a receiver (nil = automatic). Clears a chosen host.
    public mutating func select(_ name: String?, now: TimeInterval) {
        storedSelection = Self.normalized(name)
        storedHost = nil
        recompute(now: now)
    }

    /// The user chose a host explicitly (nil = back to the receivers).
    /// Clears the stored receiver selection.
    public mutating func selectHost(_ host: String?, now: TimeInterval) {
        storedHost = Self.normalized(host?.trimmingCharacters(in: .whitespaces))
        if storedHost != nil {
            storedSelection = nil
        }
        recompute(now: now)
    }

    /// Receivers whose tailnet addresses are known.
    public mutating func updateRemoteReachable(_ names: Set<String>, now: TimeInterval) {
        guard names != remoteReachable else { return }
        remoteReachable = names
        recompute(now: now)
    }

    public mutating func setManualHost(_ host: String, now: TimeInterval) {
        manualHost = host.trimmingCharacters(in: .whitespaces)
        recompute(now: now)
    }

    /// Re-evaluates time-based rules (the loss grace) — call periodically.
    public mutating func tick(now: TimeInterval) {
        recompute(now: now)
    }

    // MARK: - Decision

    private mutating func recompute(now: TimeInterval) {
        let previous = target
        let previousWasAutomatic: Bool = {
            if case .target(_, let automatic) = status { return automatic }
            return false
        }()

        if let host = storedHost {
            set(.host(host), automatic: false, now: now)
            return
        }
        if let stored = storedSelection {
            if isVisible(stored) || keepsMissingService(stored, previous: previous, now: now)
                || remoteReachable.contains(stored)
            {
                set(.service(stored), automatic: false, now: now)
            } else {
                clear(.looking(stored))
            }
            return
        }

        // Automatic: stay on the receiver already picked while it is visible
        // (or within the grace), even when a second one appears.
        if previousWasAutomatic, case .service(let current)? = previous,
            isVisible(current) || keepsMissingService(current, previous: previous, now: now)
                || remoteReachable.contains(current)
        {
            set(.service(current), automatic: true, now: now)
            return
        }
        if visibleServices.count == 1 {
            set(.service(visibleServices[0]), automatic: true, now: now)
            return
        }
        if visibleServices.isEmpty, remoteReachable.count == 1, let only = remoteReachable.first {
            set(.service(only), automatic: true, now: now)
            return
        }
        if !manualHost.isEmpty {
            set(.host(manualHost), automatic: false, now: now)
            return
        }
        clear(visibleServices.isEmpty ? .noReceiver : .chooseReceiver(count: visibleServices.count))
    }

    private func isVisible(_ name: String) -> Bool {
        visibleServices.contains(name)
    }

    /// True while `name` is the current service target and has been missing
    /// from the browse results for less than the grace interval.
    private mutating func keepsMissingService(
        _ name: String, previous: ReceiverTarget?, now: TimeInterval
    ) -> Bool {
        guard previous == .service(name) else { return false }
        let missingSince = targetMissingSince ?? now
        targetMissingSince = missingSince
        return now - missingSince < serviceLossGrace
    }

    private mutating func set(_ newTarget: ReceiverTarget, automatic: Bool, now: TimeInterval) {
        if case .service(let name) = newTarget, isVisible(name) {
            targetMissingSince = nil
        } else if case .host = newTarget {
            targetMissingSince = nil
        }
        target = newTarget
        status = .target(newTarget, automatic: automatic)
    }

    private mutating func clear(_ newStatus: Status) {
        target = nil
        targetMissingSince = nil
        status = newStatus
    }

    private static func normalized(_ name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        return name
    }
}

/// Keepalive-based liveness of the sender's connection. The receiver answers
/// every arriving audio packet stream with a "MABK" keepalive every 20 ms, so
/// a connection that keeps sending without hearing one back for `timeout`
/// seconds is talking to a stale address: recreate it, which makes the
/// system resolve the Bonjour service again.
public enum ReceiverLiveness {
    public enum State: String, Equatable, Sendable {
        /// Waiting for the path / the first keepalive.
        case connecting
        /// Keepalives arriving.
        case alive
        /// Nothing sent recently (no audio playing), so nothing to judge.
        case idle
        /// Timed out — the connection is being recreated.
        case noResponse
    }

    public enum Decision: Equatable, Sendable {
        case keep
        case reconnect
    }

    public static let defaultTimeout: TimeInterval = 3

    /// - Parameters:
    ///   - connectionAge: seconds since this connection was created.
    ///   - isReady: whether the connection is in the `.ready` state.
    ///   - keepaliveAge: seconds since the last keepalive on this connection
    ///     (nil = none yet).
    ///   - unansweredSendAge: seconds since the first datagram sent after the
    ///     last keepalive (nil = nothing sent since then).
    public static func assess(
        connectionAge: TimeInterval,
        isReady: Bool,
        keepaliveAge: TimeInterval?,
        unansweredSendAge: TimeInterval?,
        timeout: TimeInterval = defaultTimeout
    ) -> (state: State, decision: Decision) {
        guard isReady else {
            // Stuck resolving, waiting for a path, or failed: retry with a
            // fresh connection (and a fresh resolution) every `timeout`.
            return connectionAge >= timeout ? (.noResponse, .reconnect) : (.connecting, .keep)
        }
        if let unanswered = unansweredSendAge, unanswered >= timeout {
            return connectionAge >= timeout ? (.noResponse, .reconnect) : (.connecting, .keep)
        }
        if let keepaliveAge, keepaliveAge < timeout {
            return (.alive, .keep)
        }
        return unansweredSendAge == nil ? (.idle, .keep) : (.connecting, .keep)
    }
}
