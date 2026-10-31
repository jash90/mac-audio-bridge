import Foundation

/// An output device as the Mac's output switch sees it.
public struct OutputDeviceInfo: Equatable, Sendable {
    /// CoreAudio device UID (stable across coreaudiod restarts, unlike the
    /// AudioObjectID).
    public var uid: String
    public var name: String
    /// Built-in speakers / headphone jack.
    public var isBuiltIn: Bool

    public init(uid: String, name: String, isBuiltIn: Bool) {
        self.uid = uid
        self.name = name
        self.isBuiltIn = isBuiltIn
    }
}

/// Mac-side model of the default-output switch: remembers the output used
/// before "iPhone (Mac Audio Bridge)" (by UID), detects the user selecting
/// our device (a Mac-initiated takeover), and picks what to restore on
/// disconnect/release — the remembered device if it still exists, else the
/// built-in output, else any other output; nil when there is nothing but
/// ours (the sender then pauses streaming instead).
public struct OutputRestoreModel: Equatable, Sendable {
    public enum Transition: Equatable, Sendable {
        case none
        /// The default output changed to our device.
        case becameOurs
        /// The default output changed from our device to another one.
        case leftOurs
    }

    public let bridgeUID: String
    public private(set) var remembered: OutputDeviceInfo?
    /// Default output at the last observation (nil before the first one).
    public private(set) var lastDefaultUID: String?
    private var hasObserved = false

    public init(bridgeUID: String, remembered: OutputDeviceInfo? = nil) {
        self.bridgeUID = bridgeUID
        self.remembered = remembered?.uid == bridgeUID ? nil : remembered
    }

    /// Feeds the current default output (nil = none / unknown). The first
    /// observation is never a transition: our device already being the
    /// default at launch is not an explicit action.
    public mutating func observeDefaultOutput(_ device: OutputDeviceInfo?) -> Transition {
        let uid = device?.uid
        if let device, device.uid != bridgeUID {
            remembered = device
        }
        defer {
            lastDefaultUID = uid
            hasObserved = true
        }
        guard hasObserved, uid != lastDefaultUID else { return .none }
        if uid == bridgeUID { return .becameOurs }
        if lastDefaultUID == bridgeUID { return .leftOurs }
        return .none
    }

    /// The device to switch back to, among `available` output devices.
    public func restoreTarget(available: [OutputDeviceInfo]) -> OutputDeviceInfo? {
        let candidates = available.filter { $0.uid != bridgeUID }
        if let remembered, let match = candidates.first(where: { $0.uid == remembered.uid }) {
            return match
        }
        if let builtIn = candidates.first(where: \.isBuiltIn) {
            return builtIn
        }
        return candidates.first
    }
}
