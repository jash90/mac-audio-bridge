import Foundation

/// Which concrete path reaches one peer: the local one (a Bonjour endpoint,
/// re-resolved on every connection) or one of the peer's remote addresses
/// (its tailnet IPs learnt while on the same LAN, or a typed-in address).
/// Pure state machine shared by both apps: the Mac uses it for the audio
/// target of a receiver, the phone for the control connection to a Mac.
///
/// Rules:
/// - Preference order: local (while available), then the remote addresses
///   in the given order. Local is preferred whenever both work.
/// - `pathFailed` (keepalive timeout / connection failure on the current
///   path) marks it failed and moves to the next usable candidate. A failed
///   remote is usable again after `remoteRetry`; a failed local only after
///   fresh evidence that the LAN works: the local endpoint re-appearing
///   (`setLocalAvailable` false → true), or `localEvidence` (e.g. the peer's
///   control connection arrives from a LAN address) once the backoff since
///   the failure has passed (`localRetry`, doubling per consecutive local
///   failure up to `maxLocalRetry`). So a phone that left for 5G is not
///   re-probed on the LAN — each probe would cost a keepalive timeout of
///   silence — until there is a reason to believe it is back.
/// - With nothing usable, the candidate that failed longest ago is retried
///   (with no candidate at all: local), so the owner keeps trying.
/// - Losing the local endpoint does not abandon a current local path by
///   itself (a receiver app restart re-registers within a second); the
///   keepalive timeout decides.
/// - `pathAlive` clears the failure record of the current path.
public struct PathFailover: Equatable, Sendable {
    public enum Path: Hashable, Sendable {
        case local
        case remote(String)

        public var isRemote: Bool {
            if case .remote = self { return true }
            return false
        }

        public var remoteAddress: String? {
            if case .remote(let address) = self { return address }
            return nil
        }
    }

    struct Failure: Equatable, Sendable {
        var at: TimeInterval
        var count: Int
    }

    public static let defaultRemoteRetry: TimeInterval = 15
    public static let defaultLocalRetry: TimeInterval = 10
    public static let defaultMaxLocalRetry: TimeInterval = 300

    public let remoteRetry: TimeInterval
    public let localRetry: TimeInterval
    public let maxLocalRetry: TimeInterval
    public private(set) var current: Path?
    public private(set) var localAvailable: Bool
    public private(set) var remoteAddresses: [String]
    private var failures: [Path: Failure] = [:]

    public init(
        localAvailable: Bool,
        remoteAddresses: [String],
        now: TimeInterval,
        remoteRetry: TimeInterval = PathFailover.defaultRemoteRetry,
        localRetry: TimeInterval = PathFailover.defaultLocalRetry,
        maxLocalRetry: TimeInterval = PathFailover.defaultMaxLocalRetry
    ) {
        self.localAvailable = localAvailable
        self.remoteAddresses = Self.deduplicated(remoteAddresses)
        self.remoteRetry = remoteRetry
        self.localRetry = localRetry
        self.maxLocalRetry = maxLocalRetry
        current = nil
        reselect(now: now)
    }

    /// Candidates in preference order.
    public var candidates: [Path] {
        (localAvailable ? [.local] : []) + remoteAddresses.map(Path.remote)
    }

    public var isLocalFailed: Bool { failures[.local] != nil }

    // MARK: - Inputs

    public mutating func setLocalAvailable(_ available: Bool, now: TimeInterval) {
        guard available != localAvailable else { return }
        localAvailable = available
        if available {
            // A fresh announcement is evidence the LAN path is back.
            failures[.local] = nil
            localFailureCount = 0
            if current != .local {
                reselect(now: now)
            }
        } else if current == nil {
            reselect(now: now)
        }
    }

    public mutating func setRemoteAddresses(_ addresses: [String], now: TimeInterval) {
        let list = Self.deduplicated(addresses)
        guard list != remoteAddresses else { return }
        remoteAddresses = list
        for path in failures.keys where path.isRemote && !list.contains(path.remoteAddress!) {
            failures[path] = nil
        }
        if let current, current.isRemote, !list.contains(current.remoteAddress!) {
            reselect(now: now)
        } else if current == nil || (current == .local && !localAvailable) {
            reselect(now: now)
        }
    }

    /// A level signal that the LAN path works (e.g. the peer's control
    /// connection comes from a LAN address). Switches back to local once
    /// the backoff since the last local failure has passed.
    public mutating func localEvidence(now: TimeInterval) {
        guard localAvailable, let current, current.isRemote, let failure = failures[.local] else {
            return
        }
        guard now - failure.at >= localBackoff(failure.count) else { return }
        // Keep the count: a repeated failure backs off further.
        failures[.local] = nil
        localFailureCount = failure.count
        reselect(now: now)
    }

    /// The current path timed out or failed.
    public mutating func pathFailed(now: TimeInterval) {
        guard let current else {
            reselect(now: now)
            return
        }
        let previousCount = failures[current]?.count ?? (current == .local ? localFailureCount : 0)
        failures[current] = Failure(at: now, count: previousCount + 1)
        reselect(now: now, avoiding: current)
    }

    /// Traffic confirmed on the current path.
    public mutating func pathAlive(now: TimeInterval) {
        guard let current else { return }
        failures[current] = nil
        if current == .local {
            localFailureCount = 0
        }
    }

    /// Re-evaluates time-based rules (a failed remote becoming usable).
    public mutating func tick(now: TimeInterval) {
        if current == nil {
            reselect(now: now)
        }
    }

    /// Consecutive local failures carried across an evidence-triggered retry.
    private var localFailureCount = 0

    // MARK: - Selection

    private func localBackoff(_ count: Int) -> TimeInterval {
        let exponent = max(count - 1, 0)
        return min(localRetry * pow(2, Double(min(exponent, 16))), maxLocalRetry)
    }

    private func isUsable(_ path: Path, now: TimeInterval) -> Bool {
        guard let failure = failures[path] else { return true }
        switch path {
        case .local: return false  // only evidence clears it
        case .remote: return now - failure.at >= remoteRetry
        }
    }

    private mutating func reselect(now: TimeInterval, avoiding failed: Path? = nil) {
        let candidates = candidates
        if let usable = candidates.first(where: { isUsable($0, now: now) && $0 != failed }) {
            current = usable
            return
        }
        // Nothing usable: retry the one that failed longest ago, preferring
        // anything but the path that just failed.
        let others = candidates.filter { $0 != failed }
        let pool = others.isEmpty ? candidates : others
        if let oldest = pool.min(by: { (failures[$0]?.at ?? -.infinity) < (failures[$1]?.at ?? -.infinity) }) {
            current = oldest
        } else {
            current = .local
        }
    }

    private static func deduplicated(_ addresses: [String]) -> [String] {
        var seen = Set<String>()
        return addresses.compactMap { address in
            let trimmed = address.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }
}
