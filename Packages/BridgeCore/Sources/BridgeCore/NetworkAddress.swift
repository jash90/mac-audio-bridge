import Foundation

/// What kind of network an IP address belongs to, as far as the bridge
/// cares: the local network (Bonjour reaches it), the Tailscale tailnet
/// (the Internet path), or anything else.
public enum NetworkAddressKind: String, Sendable, Equatable, Codable {
    case loopback
    /// Private (RFC 1918), link-local and unique-local addresses — the LAN.
    case lan
    /// Tailscale: 100.64.0.0/10 (CGNAT space Tailscale assigns from) and
    /// fd7a:115c:a1e0::/48.
    case tailnet
    /// Public or otherwise unknown.
    case other
}

/// Address classification and the control-channel trust rule.
///
/// Trust: control commands are accepted from loopback, LAN and tailnet
/// addresses; everything else is refused. Tailscale authenticates every peer
/// of a tailnet (WireGuard keys bound to the user's account) and this is a
/// personal tailnet, so a tailnet address is as trusted as a LAN one; there
/// is still no authentication of our own (personal MVP).
public enum NetworkAddress {
    /// The Tailscale IPv6 ULA prefix fd7a:115c:a1e0::/48.
    public static let tailnetIPv6Prefix: [UInt8] = [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]

    public static func kind(ipv4 bytes: [UInt8]) -> NetworkAddressKind? {
        guard bytes.count == 4 else { return nil }
        if bytes[0] == 127 { return .loopback }
        // 100.64.0.0/10: second octet 64...127.
        if bytes[0] == 100, bytes[1] & 0xC0 == 0x40 { return .tailnet }
        return LocalNetworkAddress.isLocal(ipv4: bytes) ? .lan : .other
    }

    public static func kind(ipv6 bytes: [UInt8]) -> NetworkAddressKind? {
        guard bytes.count == 16 else { return nil }
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return .loopback }
        if Array(bytes[0..<6]) == tailnetIPv6Prefix { return .tailnet }
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
            return kind(ipv4: Array(bytes[12..<16]))
        }
        return LocalNetworkAddress.isLocal(ipv6: bytes) ? .lan : .other
    }

    /// Classifies a textual IP literal ("100.64.1.2", "fd7a:…", "[fe80::1%en0]");
    /// nil for a host name (MagicDNS "iphone171") or garbage.
    public static func kind(_ text: String) -> NetworkAddressKind? {
        if let bytes = ipv4Bytes(text) { return kind(ipv4: bytes) }
        if let bytes = ipv6Bytes(text) { return kind(ipv6: bytes) }
        return nil
    }

    /// Whether a peer of this kind may send control commands.
    public static func isTrustedForControl(_ kind: NetworkAddressKind?) -> Bool {
        switch kind {
        case .loopback?, .lan?, .tailnet?: true
        case .other?, nil: false
        }
    }

    public static func isTailnet(_ text: String) -> Bool {
        kind(text) == .tailnet
    }

    /// Whether `text` is an IP literal (not a host name).
    public static func isIPLiteral(_ text: String) -> Bool {
        kind(text) != nil
    }

    // MARK: - Parsing

    static func ipv4Bytes(_ text: String) -> [UInt8]? {
        var address = in_addr()
        let parsed = text.trimmingCharacters(in: .whitespaces).withCString { inet_pton(AF_INET, $0, &address) }
        guard parsed == 1 else { return nil }
        return withUnsafeBytes(of: address.s_addr) { Array($0) }
    }

    static func ipv6Bytes(_ text: String) -> [UInt8]? {
        var literal = text.trimmingCharacters(in: .whitespaces)
        if literal.hasPrefix("["), literal.hasSuffix("]") {
            literal = String(literal.dropFirst().dropLast())
        }
        if let percent = literal.firstIndex(of: "%") {
            literal = String(literal[..<percent])
        }
        var address = in6_addr()
        let parsed = literal.withCString { inet_pton(AF_INET6, $0, &address) }
        guard parsed == 1 else { return nil }
        return withUnsafeBytes(of: address) { Array($0) }
    }
}

/// This device's own interface addresses (getifaddrs). Not pure; the
/// classification it relies on is.
public enum InterfaceAddresses {
    public struct Entry: Sendable, Equatable {
        public var interface: String
        public var address: String
        public var kind: NetworkAddressKind
    }

    public static func current() -> [Entry] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }
        var entries: [Entry] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let interface = current.pointee
            cursor = interface.ifa_next
            guard let address = interface.ifa_addr, interface.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            let name = String(cString: interface.ifa_name)
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                let bytes = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee
                    .sin_addr
                let raw = withUnsafeBytes(of: bytes.s_addr) { Array($0) }
                if let kind = NetworkAddress.kind(ipv4: raw) {
                    entries.append(Entry(interface: name, address: raw.map(String.init).joined(separator: "."), kind: kind))
                }
            case AF_INET6:
                var sin6 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee
                let raw = withUnsafeBytes(of: sin6.sin6_addr) { Array($0) }
                guard let kind = NetworkAddress.kind(ipv6: raw) else { continue }
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                guard inet_ntop(AF_INET6, &sin6.sin6_addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil
                else { continue }
                let text = buffer.withUnsafeBufferPointer { pointer in
                    String(decoding: pointer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
                entries.append(Entry(interface: name, address: text, kind: kind))
            default:
                continue
            }
        }
        return entries
    }

    /// This device's tailnet addresses, IPv4 first, de-duplicated.
    public static func tailnet() -> [String] {
        ordered(current().filter { $0.kind == .tailnet }.map(\.address))
    }

    /// IPv4 before IPv6, otherwise sorted; duplicates removed.
    public static func ordered(_ addresses: [String]) -> [String] {
        Array(Set(addresses)).sorted { lhs, rhs in
            let lhsV4 = NetworkAddress.ipv4Bytes(lhs) != nil
            let rhsV4 = NetworkAddress.ipv4Bytes(rhs) != nil
            if lhsV4 != rhsV4 { return lhsV4 }
            return lhs < rhs
        }
    }
}
