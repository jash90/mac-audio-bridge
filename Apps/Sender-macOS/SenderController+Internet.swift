import BridgeCore
import Foundation

/// Internet mode (Mac side): streaming to a phone that is not on this Mac's
/// LAN, through Tailscale.
///
/// - The phone's hello carries its tailnet addresses; they are persisted per
///   receiver (`tailnetBook`), which keeps that receiver a valid target while
///   Bonjour cannot see it (`ReceiverSelection.remoteReachable`).
/// - Per logical target a `PathFailover` picks the concrete endpoint: the
///   Bonjour service while it works, the phone's tailnet IP after a
///   keepalive timeout, and the LAN again when the phone is announced again
///   or its control session arrives from a LAN address.
/// - The stream profile follows the path (`StreamProfile.decide`): WAN for a
///   tailnet / public address or a phone on an expensive path.
/// - `tailscale status --json` (polled while the menu is open or while
///   streaming) lists the tailnet's iOS peers for the menu and tells direct
///   from relayed paths.
extension SenderController {
    // MARK: - Failover

    func makeFailover(for target: ReceiverTarget?) -> PathFailover? {
        guard case .service(let name)? = target else { return nil }
        return PathFailover(
            localAvailable: selection.visibleServices.contains(name),
            remoteAddresses: tailnetBook[name] ?? [], now: Self.uptime())
    }

    /// The endpoint for the active (logical) target: the Bonjour service, or
    /// the tailnet address the failover picked.
    func resolveConcreteTarget() -> ReceiverTarget? {
        guard let activeTarget else { return nil }
        guard case .service = activeTarget, case .remote(let address)? = failover?.current else {
            return activeTarget
        }
        return .host(address)
    }

    /// Feeds the failover (Bonjour presence, stored addresses, LAN evidence,
    /// and — once a second, with `snapshot` — liveness timeouts and
    /// keepalives), re-points the sender and re-decides the profile.
    func updateInternetPath(snapshot: UDPSender.LinkSnapshot?) {
        let now = Self.uptime()
        let reconnected = snapshot.map { $0.reconnects != lastReconnects } ?? false
        if let snapshot {
            lastReconnects = snapshot.reconnects
        }
        if var updated = failover, case .service(let name)? = activeTarget, mode == .streaming {
            updated.setLocalAvailable(selection.visibleServices.contains(name), now: now)
            updated.setRemoteAddresses(tailnetBook[name] ?? [], now: now)
            if phoneReachesUsLocally(receiverService: name) {
                updated.localEvidence(now: now)
            }
            if reconnected {
                updated.pathFailed(now: now)
            } else if snapshot?.link == .alive {
                updated.pathAlive(now: now)
            }
            updated.tick(now: now)
            if updated != failover {
                failover = updated
            }
        }
        applyConcreteTarget()
        updateProfile()
    }

    /// A control session of that receiver's phone comes from a LAN address.
    private func phoneReachesUsLocally(receiverService name: String) -> Bool {
        sessions.contains { id, hello in
            hello?.receiverService == name && sessionKinds[id] == .lan
        }
    }

    // MARK: - Profile

    func updateProfile() {
        let snapshot = linkSnapshot
        var kind = snapshot.remoteKind
        var hostName = false
        var address = snapshot.remoteAddress
        if case .host(let host)? = concreteTarget {
            if let literal = NetworkAddress.kind(host) {
                kind = literal
                address = address ?? host
            } else if kind == nil {
                hostName = true
            }
        }
        var receiverExpensive = false
        if case .service(let name)? = activeTarget {
            receiverExpensive = phoneExpensive[name] ?? false
        }
        let expensive = snapshot.peerFlags.contains(.expensivePath) || receiverExpensive
        let profile: StreamProfile = mode == .streaming
            ? StreamProfile.decide(remoteKind: kind, targetIsHostName: hostName, phoneOnExpensivePath: expensive)
            : .lan
        if profile != streamProfile {
            streamProfile = profile
            profileGate.value = profile
            setLivenessTimeout(profile.livenessTimeout)
        }
        applyEffectiveQuality()
        let peerPath = address.flatMap { tailscaleStatus?.peer(owning: $0)?.path }
        let path = StreamPath.classify(remoteKind: kind ?? (hostName ? .tailnet : nil), tailscalePath: peerPath)
        if path != streamPath {
            streamPath = path
        }
    }

    /// The encoding: the LAN pick, or on WAN the Internet quality (20 ms
    /// Opus frames with low-rate copies).
    func applyEffectiveQuality() {
        let encoding = streamProfile.encoding(lan: quality, internet: internetQuality)
        if converter.encodingGate.value != encoding {
            converter.encodingGate.value = encoding
        }
        let note = streamProfile.qualityNote(lan: quality, internet: internetQuality)
        if note != qualityNote {
            qualityNote = note
        }
    }

    // MARK: - Phones

    /// Stores the phone's tailnet addresses under its receiver name (and
    /// forgets the same addresses under an old name of the same phone).
    func recordPhoneHello(_ hello: PhoneHello) {
        phoneExpensive[hello.receiverService] = hello.expensivePath ?? false
        let addresses = InterfaceAddresses.ordered((hello.tailnetAddresses ?? []).filter(NetworkAddress.isTailnet))
        guard !addresses.isEmpty, tailnetBook[hello.receiverService] != addresses else { return }
        for (name, known) in tailnetBook where name != hello.receiverService && !Set(known).isDisjoint(with: addresses) {
            tailnetBook[name] = nil
        }
        tailnetBook[hello.receiverService] = addresses
        UserDefaults.standard.set(tailnetBook, forKey: Self.tailnetAddressesKey)
        remoteReceivers = tailnetBook.keys.sorted()
        selection.updateRemoteReachable(Set(tailnetBook.keys), now: Self.uptime())
    }

    /// Whether the current stream goes to this phone: its receiver service,
    /// or a chosen host that is one of its tailnet addresses / its Tailscale
    /// peer name.
    func isStreaming(to hello: PhoneHello) -> Bool {
        guard mode == .streaming, let activeTarget else { return false }
        switch activeTarget {
        case .service(let name):
            return name == hello.receiverService
        case .host(let host):
            let phoneAddresses = Set(hello.tailnetAddresses ?? [])
            guard !phoneAddresses.isEmpty else { return false }
            return !phoneAddresses.isDisjoint(with: addresses(forHost: host))
        }
    }

    /// Tailnet addresses a typed host stands for (an IP, or a peer's name).
    private func addresses(forHost host: String) -> [String] {
        if NetworkAddress.isIPLiteral(host) { return [host] }
        let lowered = host.lowercased()
        return (tailscaleStatus?.peers ?? [])
            .filter { $0.name.lowercased() == lowered || $0.dnsName.lowercased() == lowered }
            .flatMap(\.addresses)
    }

    // MARK: - Menu actions

    /// Streams to `host` (a typed address or a Tailscale peer) even while
    /// Bonjour receivers are visible; nil goes back to the receiver list.
    func chooseHost(_ host: String?) {
        let trimmed = host?.trimmingCharacters(in: .whitespaces) ?? ""
        let value = trimmed.isEmpty ? nil : trimmed
        let defaults = UserDefaults.standard
        if let value {
            defaults.set(value, forKey: Self.storedHostKey)
        } else {
            defaults.removeObject(forKey: Self.storedHostKey)
        }
        storedHost = value
        selection.selectHost(value, now: Self.uptime())
        evaluate()
    }

    /// The menu window opened / closed: Tailscale peers are polled while open.
    func setMenuOpen(_ open: Bool) {
        menuOpen = open
        tailscaleMonitor?.setActive(open || mode == .streaming)
        if open {
            tailscaleMonitor?.pollNow()
        }
    }

    /// Forgets a receiver's stored tailnet addresses.
    func forgetRemoteReceiver(_ name: String) {
        tailnetBook[name] = nil
        UserDefaults.standard.set(tailnetBook, forKey: Self.tailnetAddressesKey)
        remoteReceivers = tailnetBook.keys.sorted()
        selection.updateRemoteReachable(Set(tailnetBook.keys), now: Self.uptime())
        evaluate()
    }

    /// The receiver name a Tailscale peer belongs to (its addresses were
    /// reported by that phone), if known.
    func receiverName(for peer: TailscaleStatus.Peer) -> String? {
        tailnetBook.first { !Set($0.value).isDisjoint(with: peer.addresses) }?.key
    }

    // MARK: - Housekeeping (1 Hz)

    func refreshInternetHousekeeping() {
        let own = InterfaceAddresses.tailnet()
        let addresses = own.isEmpty ? (tailscaleStatus?.selfAddresses ?? []) : own
        if addresses != ownTailnetAddresses {
            ownTailnetAddresses = addresses
            remoteStateChanged(force: true)
        }
        tailscaleMonitor?.setActive(menuOpen || mode == .streaming)
    }

    func tailscaleUpdated(_ state: TailscaleMonitor.State, _ status: TailscaleStatus?) {
        if tailscaleState != state {
            tailscaleState = state
        }
        if status != tailscaleStatus {
            tailscaleStatus = status
            let peers = status?.iosPeers ?? []
            if peers != tailscalePeers {
                tailscalePeers = peers
            }
            updateProfile()
        }
    }

    // MARK: - Nonisolated factory

    /// Monitor whose updates hop to the main actor in FIFO order.
    nonisolated static func makeTailscaleMonitor(controller: SenderController) -> TailscaleMonitor {
        TailscaleMonitor { [weak controller] state, status in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { controller?.tailscaleUpdated(state, status) }
            }
        }
    }
}
