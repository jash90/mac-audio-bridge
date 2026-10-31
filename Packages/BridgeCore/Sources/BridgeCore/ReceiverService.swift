import Foundation

/// Bonjour identity of a receiver: the service type both apps agree on, the
/// TXT protocol version, and the rules for building a stable, unique service
/// name. Pure values only — the Network framework calls live in the apps.
public enum ReceiverService {
    /// DNS-SD service type advertised by the iOS receiver's UDP listener.
    public static let type = "_macaudiobridge._udp"
    /// Browse / resolve domain.
    public static let domain = "local."
    /// UDP port the receiver binds first; Bonjour carries the actual port, so
    /// a fallback port still works for discovered receivers.
    public static let preferredPort: UInt16 = 49_000
    /// TXT key / value carrying the wire-protocol version.
    public static let versionKey = "v"
    public static let protocolVersion = "2"  // AudioDatagram v2: 5 ms frames + redundancy
    /// Name used when the device reports an empty name.
    public static let fallbackDeviceName = "iPhone"
    /// Length of the persisted random suffix that keeps the name unique.
    public static let suffixLength = 4
    /// DNS-SD instance names are limited to 63 UTF-8 bytes.
    public static let maxNameBytes = 63
    /// Suffix alphabet without look-alike characters (0/O, 1/I/L).
    static let suffixAlphabet = Array("23456789ABCDEFGHJKMNPQRSTUVWXYZ")

    /// Whether a discovered receiver speaks our protocol. A missing version
    /// is accepted: the TXT record can arrive after the service itself.
    public static func isCompatible(version: String?) -> Bool {
        guard let version else { return true }
        return version == protocolVersion
    }

    /// A random suffix, generated once per install and persisted by the app.
    public static func makeSuffix<G: RandomNumberGenerator>(using generator: inout G) -> String {
        String((0..<suffixLength).map { _ in suffixAlphabet.randomElement(using: &generator)! })
    }

    public static func makeSuffix() -> String {
        var generator = SystemRandomNumberGenerator()
        return makeSuffix(using: &generator)
    }

    /// Whether a persisted suffix is still usable (else the app regenerates it).
    public static func isValidSuffix(_ suffix: String) -> Bool {
        suffix.count == suffixLength && suffix.allSatisfy { suffixAlphabet.contains($0) }
    }

    /// "<device name> <suffix>", e.g. "iPhone 7KQ2". iOS 16+ reports the
    /// generic "iPhone" without a special entitlement, so the suffix is what
    /// tells two phones apart; it is persisted, so the name stays stable
    /// across launches and the Mac's stored selection keeps matching. The
    /// device-name part is trimmed so the whole name fits 63 UTF-8 bytes.
    public static func serviceName(deviceName: String, suffix: String) -> String {
        var base = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = fallbackDeviceName }
        let budget = maxNameBytes - suffix.utf8.count - 1
        while base.utf8.count > budget, !base.isEmpty {
            base.removeLast()
        }
        base = base.trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = fallbackDeviceName }
        return "\(base) \(suffix)"
    }
}
