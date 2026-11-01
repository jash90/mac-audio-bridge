import Foundation
import Testing
@testable import BridgeCore

// MARK: - Address classification + trust

struct NetworkAddressTests {
    @Test("Tailscale v4/v6 ranges, LAN, loopback and public addresses are told apart")
    func classification() {
        #expect(NetworkAddress.kind("100.64.0.1") == .tailnet)
        #expect(NetworkAddress.kind("100.125.230.116") == .tailnet)
        #expect(NetworkAddress.kind("100.127.255.254") == .tailnet)
        #expect(NetworkAddress.kind("100.63.255.255") == .other)  // just below 100.64/10
        #expect(NetworkAddress.kind("100.128.0.1") == .other)  // just above
        #expect(NetworkAddress.kind("fd7a:115c:a1e0::4a38:e675") == .tailnet)
        #expect(NetworkAddress.kind("[fd7a:115c:a1e0:ab12::1]") == .tailnet)
        #expect(NetworkAddress.kind("fd7a:115c:a1e1::1") == .lan)  // other ULA: local
        #expect(NetworkAddress.kind("192.168.10.131") == .lan)
        #expect(NetworkAddress.kind("10.1.2.3") == .lan)
        #expect(NetworkAddress.kind("172.16.0.9") == .lan)
        #expect(NetworkAddress.kind("169.254.3.4") == .lan)
        #expect(NetworkAddress.kind("fe80::1%en0") == .lan)
        #expect(NetworkAddress.kind("127.0.0.1") == .loopback)
        #expect(NetworkAddress.kind("::1") == .loopback)
        #expect(NetworkAddress.kind("::ffff:100.100.1.1") == .tailnet)
        #expect(NetworkAddress.kind("::ffff:192.168.1.1") == .lan)
        #expect(NetworkAddress.kind("8.8.8.8") == .other)
        #expect(NetworkAddress.kind("2a00:1450:4001::200e") == .other)
        #expect(NetworkAddress.kind("iphone171") == nil)  // MagicDNS host name
        #expect(NetworkAddress.kind("iphone171.tail77985b.ts.net") == nil)
        #expect(!NetworkAddress.isIPLiteral("macbook-pro-3"))
        #expect(NetworkAddress.isIPLiteral("100.111.63.100"))
    }

    @Test("Control commands are trusted from LAN, loopback and tailnet only")
    func trust() {
        #expect(NetworkAddress.isTrustedForControl(NetworkAddress.kind("192.168.1.20")))
        #expect(NetworkAddress.isTrustedForControl(NetworkAddress.kind("100.111.63.100")))
        #expect(NetworkAddress.isTrustedForControl(NetworkAddress.kind("fd7a:115c:a1e0::1938:3f65")))
        #expect(NetworkAddress.isTrustedForControl(NetworkAddress.kind("127.0.0.1")))
        #expect(!NetworkAddress.isTrustedForControl(NetworkAddress.kind("8.8.8.8")))
        #expect(!NetworkAddress.isTrustedForControl(NetworkAddress.kind("100.128.0.1")))
        #expect(!NetworkAddress.isTrustedForControl(nil))
    }

    @Test("Addresses are ordered IPv4 first and de-duplicated")
    func ordering() {
        #expect(
            InterfaceAddresses.ordered(["fd7a:115c:a1e0::2", "100.64.0.2", "100.64.0.2", "100.64.0.1"])
                == ["100.64.0.1", "100.64.0.2", "fd7a:115c:a1e0::2"])
    }
}

// MARK: - Failover

struct PathFailoverTests {
    private let phoneV4 = "100.125.230.116"
    private let phoneV6 = "fd7a:115c:a1e0::4a38:e675"

    @Test("LAN → keepalive lost → tailnet → LAN back when the receiver is announced again")
    func lanToTailnetAndBack() {
        var failover = PathFailover(localAvailable: true, remoteAddresses: [phoneV4, phoneV6], now: 0)
        #expect(failover.current == .local)
        failover.pathAlive(now: 1)
        // The phone left the Wi-Fi; its Bonjour record is still cached.
        failover.pathFailed(now: 10)
        #expect(failover.current == .remote(phoneV4))
        failover.pathAlive(now: 11)
        // Bonjour finally drops the record: nothing changes.
        failover.setLocalAvailable(false, now: 30)
        #expect(failover.current == .remote(phoneV4))
        // Back on the Wi-Fi: the receiver re-registers.
        failover.setLocalAvailable(true, now: 90)
        #expect(failover.current == .local)
        #expect(!failover.isLocalFailed)
    }

    @Test("LAN evidence switches back only after the backoff, which doubles per failure")
    func localEvidenceBackoff() {
        var failover = PathFailover(localAvailable: true, remoteAddresses: [phoneV4], now: 0)
        failover.pathFailed(now: 10)
        #expect(failover.current == .remote(phoneV4))
        failover.localEvidence(now: 15)  // 5 s < 10 s backoff
        #expect(failover.current == .remote(phoneV4))
        failover.localEvidence(now: 21)
        #expect(failover.current == .local)
        // The LAN path fails again: back to the tailnet, now 20 s backoff.
        failover.pathFailed(now: 24)
        #expect(failover.current == .remote(phoneV4))
        failover.localEvidence(now: 40)
        #expect(failover.current == .remote(phoneV4))
        failover.localEvidence(now: 44)
        #expect(failover.current == .local)
        // Keepalives on the LAN reset the backoff.
        failover.pathAlive(now: 45)
        failover.pathFailed(now: 100)
        failover.localEvidence(now: 110)
        #expect(failover.current == .local)
    }

    @Test("Losing the Bonjour endpoint alone keeps a working local path")
    func vanishKeepsLocal() {
        var failover = PathFailover(localAvailable: true, remoteAddresses: [phoneV4], now: 0)
        failover.setLocalAvailable(false, now: 1)  // receiver app restart
        #expect(failover.current == .local)
        failover.setLocalAvailable(true, now: 2)
        #expect(failover.current == .local)
    }

    @Test("Remote addresses rotate on failure and a failed one is retried after the cooldown")
    func remoteRotation() {
        var failover = PathFailover(localAvailable: false, remoteAddresses: [phoneV4, phoneV6], now: 0)
        #expect(failover.current == .remote(phoneV4))
        failover.pathFailed(now: 5)
        #expect(failover.current == .remote(phoneV6))
        failover.pathFailed(now: 10)
        // Both failed: the one that failed longest ago is retried.
        #expect(failover.current == .remote(phoneV4))
        failover.pathFailed(now: 12)
        #expect(failover.current == .remote(phoneV6))
        // 15 s after its failure, v4 is usable again and preferred.
        failover.pathFailed(now: 26)
        #expect(failover.current == .remote(phoneV4))
    }

    @Test("Stored addresses arriving later (hello) rescue a target that Bonjour lost")
    func storedAddressesArriveLater() {
        var failover = PathFailover(localAvailable: false, remoteAddresses: [], now: 0)
        #expect(failover.current == .local)  // nothing else: keep resolving
        failover.setRemoteAddresses([phoneV4], now: 1)
        #expect(failover.current == .remote(phoneV4))
        // A manual entry replaces the address list; the current one is gone.
        failover.setRemoteAddresses(["iphone171"], now: 2)
        #expect(failover.current == .remote("iphone171"))
        failover.setRemoteAddresses(["iphone171", "iphone171", " "], now: 3)
        #expect(failover.remoteAddresses == ["iphone171"])
    }

    @Test("Only the local path: it is retried forever")
    func onlyLocal() {
        var failover = PathFailover(localAvailable: true, remoteAddresses: [], now: 0)
        failover.pathFailed(now: 3)
        #expect(failover.current == .local)
        failover.pathFailed(now: 6)
        #expect(failover.current == .local)
    }
}

// MARK: - Tailscale peers

struct TailscaleStatusTests {
    static let fixture = """
        {
          "Version": "1.90.6", "BackendState": "Running", "TailscaleIPs": ["100.111.63.100"],
          "Self": {"ID": "n1", "HostName": "MacBook Pro (3)", "DNSName": "macbook-pro-3.tail77985b.ts.net.",
                   "OS": "macOS", "TailscaleIPs": ["fd7a:115c:a1e0::1938:3f65", "100.111.63.100"],
                   "Online": true, "CurAddr": "", "Relay": "waw"},
          "MagicDNSSuffix": "tail77985b.ts.net",
          "Peer": {
            "nodekey:a": {"ID": "p1", "HostName": "localhost", "DNSName": "iphone171.tail77985b.ts.net.", "OS": "iOS",
                          "TailscaleIPs": ["100.125.230.116", "fd7a:115c:a1e0::4a38:e675"], "Online": true,
                          "Active": true, "CurAddr": "83.21.10.4:41641", "Relay": "waw", "LastSeen": "0001-01-01T00:00:00Z"},
            "nodekey:b": {"ID": "p2", "HostName": "localhost", "DNSName": "ipad-mini.tail77985b.ts.net.", "OS": "iOS",
                          "TailscaleIPs": ["100.70.1.2"], "Online": true, "Active": true, "CurAddr": "", "Relay": "fra"},
            "nodekey:c": {"ID": "p3", "HostName": "localhost", "DNSName": "old-iphone.tail77985b.ts.net.", "OS": "iOS",
                          "TailscaleIPs": ["100.80.9.9"], "Online": false, "Active": false, "CurAddr": "", "Relay": "waw",
                          "LastSeen": "2026-10-25T21:48:19.1Z"},
            "nodekey:d": {"ID": "p4", "HostName": "kate102", "DNSName": "kate102.tail77985b.ts.net.", "OS": "linux",
                          "TailscaleIPs": ["100.103.117.1"], "Online": true, "Active": false, "CurAddr": "", "Relay": "hel"}
          },
          "User": {}
        }
        """

    @Test("Peer list parse: iOS peers, online state, direct vs relay, own addresses")
    func parse() throws {
        let status = try #require(TailscaleStatus.parse(Data(Self.fixture.utf8)))
        #expect(status.isRunning)
        #expect(status.selfName == "macbook-pro-3")
        #expect(status.selfAddresses == ["100.111.63.100", "fd7a:115c:a1e0::1938:3f65"])
        #expect(status.peers.count == 4)
        let ios = status.iosPeers
        #expect(ios.map(\.name) == ["ipad-mini", "iphone171", "old-iphone"])
        let phone = try #require(status.peer(owning: "100.125.230.116"))
        #expect(phone.name == "iphone171")
        #expect(phone.dnsName == "iphone171.tail77985b.ts.net")
        #expect(phone.online)
        #expect(phone.path == .direct)
        #expect(phone.preferredAddress == "100.125.230.116")
        #expect(ios[0].path == .relay)
        #expect(ios[2].online == false)
        #expect(ios[2].path == .unknown)
        #expect(StreamPath.classify(remoteKind: .tailnet, tailscalePath: phone.path) == .tailscaleDirect)
        #expect(StreamPath.classify(remoteKind: .tailnet, tailscalePath: ios[0].path) == .tailscaleRelay)
        #expect(StreamPath.classify(remoteKind: .tailnet, tailscalePath: nil) == .tailscale)
        #expect(StreamPath.classify(remoteKind: .lan, tailscalePath: nil) == .local)
    }

    @Test("Stopped Tailscale and garbage are tolerated")
    func stoppedOrGarbage() throws {
        let stopped = try #require(TailscaleStatus.parse(Data(#"{"BackendState":"Stopped","Peer":null}"#.utf8)))
        #expect(!stopped.isRunning)
        #expect(stopped.peers.isEmpty)
        #expect(TailscaleStatus.parse(Data("failed to connect to local tailscaled".utf8)) == nil)
        #expect(TailscaleStatus.parse(Data("{}".utf8)) == nil)
    }
}

// MARK: - Selection, protocol, keepalive

struct InternetSelectionTests {
    @Test("A stored receiver Bonjour cannot see stays the target while its tailnet address is known")
    func storedRemoteReachable() {
        var selection = ReceiverSelection(storedSelection: "iPhone 7KQ2", manualHost: "", now: 0)
        #expect(selection.status == .looking("iPhone 7KQ2"))
        selection.updateRemoteReachable(["iPhone 7KQ2"], now: 1)
        #expect(selection.target == .service("iPhone 7KQ2"))
        // Bonjour sees it, then loses it for good: still the target.
        selection.updateVisibleServices(["iPhone 7KQ2"], now: 2)
        selection.updateVisibleServices([], now: 3)
        selection.tick(now: 30)
        #expect(selection.target == .service("iPhone 7KQ2"))
    }

    @Test("Automatic mode keeps its receiver over the tailnet and picks the only remote one")
    func automaticRemote() {
        var selection = ReceiverSelection(storedSelection: nil, manualHost: "", now: 0)
        selection.updateRemoteReachable(["iPhone 7KQ2"], now: 0)
        #expect(selection.status == .target(.service("iPhone 7KQ2"), automatic: true))
        selection.updateRemoteReachable(["iPhone 7KQ2", "iPhone AB3C"], now: 1)
        #expect(selection.target == .service("iPhone 7KQ2"))  // stays
        selection.updateVisibleServices(["iPad 9XYZ", "iPhone 4FFF"], now: 2)
        #expect(selection.target == .service("iPhone 7KQ2"))
    }

    @Test("A chosen host wins over Bonjour receivers; picking a receiver clears it")
    func chosenHost() {
        var selection = ReceiverSelection(storedSelection: "iPhone 7KQ2", manualHost: "", now: 0)
        selection.updateVisibleServices(["iPhone 7KQ2"], now: 0)
        selection.selectHost("iphone171", now: 1)
        #expect(selection.status == .target(.host("iphone171"), automatic: false))
        #expect(selection.storedSelection == nil)
        selection.select("iPhone 7KQ2", now: 2)
        #expect(selection.storedHost == nil)
        #expect(selection.target == .service("iPhone 7KQ2"))
    }

    @Test("Hello and status carry the tailnet fields; a v2 envelope without them still decodes")
    func protocolRoundTrip() throws {
        let hello = PhoneHello(
            phoneID: "P", phoneName: "iPhone 7KQ2", receiverService: "iPhone 7KQ2",
            tailnetAddresses: ["100.125.230.116"], network: "cellular", expensivePath: true)
        #expect(try ControlMessage.decode(payload: ControlMessage.hello(hello).payload()) == .hello(hello))
        let status = SourceStatus(
            sourceID: "S", name: "MacBook", sourceTag: 7, driverInstalled: true, outputIsOurs: true,
            streamingToYou: true, streamingTo: "iPhone 7KQ2", audioPlaying: true, outputDeviceName: nil,
            volume: 0.5, muted: false, quality: .opus192, usedBy: nil, problem: nil,
            tailnetAddresses: ["100.111.63.100"], path: .tailscaleRelay, profile: .wan,
            qualityNote: "x", sessionBytes: 12_345, megabytesPerHour: 199.4)
        #expect(try ControlMessage.decode(payload: ControlMessage.status(status).payload()) == .status(status))
        let bare = Data(#"{"v":2,"type":"hello","hello":{"phoneID":"P","phoneName":"n","receiverService":"r"}}"#.utf8)
        #expect(
            try ControlMessage.decode(payload: bare)
                == .hello(PhoneHello(phoneID: "P", phoneName: "n", receiverService: "r")))
    }

    @Test("Keepalive flags round trip; other datagrams are not keepalives")
    func keepalive() {
        let data = ReceiverKeepalive.encode([.expensivePath])
        #expect(data.count == 16)
        #expect(Array(data.prefix(4)) == [0x4D, 0x41, 0x42, 0x4B])
        #expect(ReceiverKeepalive.decode(data) == [.expensivePath])
        #expect(ReceiverKeepalive.decode(ReceiverKeepalive.encode([])) == [])
        #expect(ReceiverKeepalive.decode(Data(count: 16)) == nil)
        #expect(ReceiverKeepalive.decode(data.prefix(15)) == nil)
    }

    @Test("The receiver follows the profile of the newest datagram only")
    func profileFollower() {
        var follower = ProfileFollower()
        #expect(follower.observe(.lan, sequence: 10) == nil)
        #expect(follower.observe(.wan, sequence: 14) == .wan)
        #expect(follower.observe(.lan, sequence: 12) == nil)  // straggler of the old path
        #expect(follower.observe(.wan, sequence: 18) == nil)
        #expect(follower.observe(.lan, sequence: 19) == .lan)
        follower.reset()
        #expect(follower.observe(.wan, sequence: 3) == .wan)  // new stream: sequences restart
    }

    @Test("The sender picks WAN for tailnet/public paths, host names and expensive phones")
    func profileDecision() {
        #expect(StreamProfile.decide(remoteKind: .lan, targetIsHostName: false, phoneOnExpensivePath: false) == .lan)
        #expect(StreamProfile.decide(remoteKind: .tailnet, targetIsHostName: false, phoneOnExpensivePath: false) == .wan)
        #expect(StreamProfile.decide(remoteKind: .other, targetIsHostName: false, phoneOnExpensivePath: false) == .wan)
        #expect(StreamProfile.decide(remoteKind: .lan, targetIsHostName: false, phoneOnExpensivePath: true) == .wan)
        #expect(StreamProfile.decide(remoteKind: nil, targetIsHostName: true, phoneOnExpensivePath: false) == .wan)
        #expect(StreamProfile.decide(remoteKind: nil, targetIsHostName: false, phoneOnExpensivePath: false) == .lan)
        // A resolved LAN address beats the host-name guess.
        #expect(StreamProfile.decide(remoteKind: .lan, targetIsHostName: true, phoneOnExpensivePath: false) == .lan)
    }
}

// MARK: - WAN profile: datagrams, quality, data rate

struct WANProfileTests {
    @Test("PCM is never encoded on WAN: the Internet quality applies whatever the LAN pick")
    func pcmRefused() {
        for lan in StreamQuality.allCases {
            for internet in InternetQuality.allCases {
                let encoding = StreamProfile.wan.encoding(lan: lan, internet: internet)
                #expect(encoding.quality.codec == .opus)
                #expect(encoding.quality == internet.quality)
            }
            #expect(StreamProfile.lan.effectiveQuality(lan: lan, internet: .floor) == lan)
        }
        #expect(StreamProfile.lan.qualityNote(lan: .pcm, internet: .standard) == nil)
        #expect(StreamProfile.wan.qualityNote(lan: .pcm, internet: .high)?.contains("High") == true)
    }

    @Test("Every datagram stays ≤ 1200 B at every profile × quality × frame duration, PCM frames included")
    func datagramBudget() {
        var encodings = StreamQuality.allCases.map(StreamEncoding.lan)
        encodings += InternetQuality.allCases.map(StreamEncoding.wan)
        // Full-rate copies of 20 ms frames, the largest Opus layout possible.
        encodings.append(StreamEncoding(quality: .opus192, frameSlots: 4))
        for profile in StreamProfile.allCases {
            for encoding in encodings {
                let estimate = StreamDataRate.estimate(encoding, profile: profile, path: .tailscaleRelay)
                #expect(
                    estimate.largestDatagram <= AudioFormat.maxDatagramBytes,
                    "\(profile) \(encoding.displayName): \(estimate.largestDatagram) B")
            }
        }
    }

    @Test("WAN layout: one 20 ms frame per datagram + low-rate copies of the previous two; wire round trip")
    func wanLayout() throws {
        var packer = RedundancyPacker()
        packer.profile = .wan
        var datagrams: [AudioDatagram] = []
        for group in 0..<10 {
            let sequence = UInt32(group * 4)
            let packet = AudioPacket(
                codec: .opus, flags: group == 0 ? [.discontinuity] : [], sequence: sequence,
                sampleTime: UInt64(sequence) * 240, payload: Data(repeating: UInt8(group), count: 240),
                frameSlots: 4, copyPayload: Data(repeating: UInt8(100 + group), count: 60))
            let out = packer.pack(packet)
            #expect(out.count == 1)
            datagrams += try out.map { try AudioDatagram.decode($0) }
        }
        let first = datagrams[0]
        #expect(first.profile == .wan && first.primaryCount == 1)
        #expect(first.flags == [.discontinuity])
        #expect(first.packets().map(\.sequence) == [0])
        let steady = datagrams[9]
        #expect(steady.entries.map(\.offset) == [0, 4, 8])
        #expect(steady.entries.map(\.frameSlots) == [4, 4, 4])
        #expect(steady.entries.map(\.lowRate) == [false, true, true])
        let packets = steady.packets()
        #expect(packets.map(\.sequence) == [36, 32, 28])
        #expect(packets.map(\.sampleTime) == [UInt64(8640), 7680, 6720])
        #expect(packets.map(\.isRedundant) == [false, true, true])
        #expect(packets.map(\.isLowRateCopy) == [false, true, true])
        #expect(packets[0].payload == Data(repeating: 9, count: 240))
        #expect(packets[1].payload == Data(repeating: 108, count: 60))
        #expect(packets[2].payload == Data(repeating: 107, count: 60))
        #expect(steady.encoded().count == 24 + 3 + 240 + 2 * (3 + 60))
    }

    @Test("Wire v6: frame duration and low-rate bits; reserved bits and 40 ms frames rejected; v4 and the mic's v5 refused")
    func wireVersionSix() throws {
        let datagram = AudioDatagram(
            codec: .opus, flags: [], sequence: 100, sampleTime: 24_000, source: 7, primaryCount: 1, profile: .wan,
            entries: [
                .init(offset: 0, payload: Data(count: 160), frameSlots: 4),
                .init(offset: 2, payload: Data(count: 30), frameSlots: 2, lowRate: true),
                .init(offset: 5, payload: Data(count: 40)),
            ])
        var bytes = datagram.encoded()
        #expect(bytes[4] == 6)
        #expect(try AudioDatagram.decode(bytes) == datagram)
        #expect(bytes[25] == 0x40 && bytes[26] == 160)  // slots code 2 → bits 13–14
        var reserved = bytes
        reserved[25] |= 0x08
        #expect(throws: AudioPacketError.malformedEntries) { try AudioDatagram.decode(reserved) }
        var fortyMs = bytes
        fortyMs[25] |= 0x60
        #expect(throws: AudioPacketError.malformedEntries) { try AudioDatagram.decode(fortyMs) }
        bytes[4] = 4
        #expect(throws: AudioPacketError.unsupportedVersion(4)) { try AudioDatagram.decode(bytes) }
        bytes[4] = 5
        #expect(throws: AudioPacketError.unsupportedVersion(5)) { try AudioDatagram.decode(bytes) }
        // The playback stream never looks like a mic datagram (the Mac's
        // socket tells them apart by the version byte).
        #expect(!MicDatagram.isMicDatagram(datagram.encoded()))
    }

    @Test("A profile switch keeps sequences continuous across 5 ms and 20 ms frames")
    func profileSwitchFlushes() throws {
        var packer = RedundancyPacker()
        var sequences: [UInt32] = []
        func record(_ out: [Data]) throws {
            for data in out {
                sequences += try AudioDatagram.decode(data).packets().filter { !$0.isRedundant }.map(\.sequence)
            }
        }
        for frame in 0..<4 {
            try record(packer.pack(AudioPacket(codec: .opus, sequence: UInt32(frame), sampleTime: 0, payload: Data(count: 120))))
        }
        try record(packer.setProfile(.wan))
        #expect(packer.pendingCount == 0)
        for group in 0..<3 {
            try record(
                packer.pack(
                    AudioPacket(
                        codec: .opus, sequence: UInt32(4 + 4 * group), sampleTime: 0, payload: Data(count: 240),
                        frameSlots: 4, copyPayload: Data(count: 60))))
        }
        // The remainder of a group cut short, then LAN again, then PCM.
        try record(packer.pack(AudioPacket(codec: .opus, sequence: 16, sampleTime: 0, payload: Data(count: 60))))
        try record(packer.setProfile(.lan))
        try record(packer.pack(AudioPacket(codec: .opus, sequence: 17, sampleTime: 0, payload: Data(count: 120))))
        try record(packer.pack(AudioPacket(codec: .pcm16, sequence: 18, sampleTime: 0, payload: Data(count: 960))))
        #expect(sequences == [0, 1, 2, 3, 4, 8, 12, 16, 17, 18])
    }

    @Test("Data rate per profile (wire bytes incl. IP/UDP/WireGuard headers)")
    func dataRate() {
        let cases: [(String, StreamEncoding, StreamProfile, StreamPath)] = [
            ("pcm/lan/local", .lan(.pcm), .lan, .local), ("opus192/lan/local", .lan(.opus192), .lan, .local),
            ("opus128/lan/local", .lan(.opus128), .lan, .local), ("opus96/lan/local", .lan(.opus96), .lan, .local),
            ("opus192/lan/tailscale", .lan(.opus192), .lan, .tailscaleDirect),
            ("standard/wan/tailscale", .wan(.standard), .wan, .tailscaleDirect),
            ("standard/wan/relay", .wan(.standard), .wan, .tailscaleRelay),
            ("high/wan/tailscale", .wan(.high), .wan, .tailscaleDirect),
        ]
        var results: [String: StreamDataRate.Estimate] = [:]
        for (name, encoding, profile, path) in cases {
            let estimate = StreamDataRate.estimate(encoding, profile: profile, path: path)
            results[name] = estimate
            print(
                "data rate \(name): "
                    + "\(String(format: "%.0f", estimate.datagramsPerSecond)) datagrams/s, "
                    + "largest \(estimate.largestDatagram) B, \(String(format: "%.0f", estimate.kilobitsPerSecond)) kbit/s, "
                    + "\(String(format: "%.0f", estimate.megabytesPerHour)) MB/h")
            #expect(estimate.largestDatagram <= AudioFormat.maxDatagramBytes)
        }
        let wan = results["standard/wan/tailscale"]!
        #expect(wan.datagramsPerSecond == 50)
        #expect(wan.megabytesPerHour <= 90)
        #expect(results["high/wan/tailscale"]!.megabytesPerHour <= 102)
        #expect(results["pcm/lan/local"]!.megabytesPerHour > 1400)
        // The study's LAN numbers: Opus 192 480 MB/h, Opus 96 264 MB/h.
        #expect(abs(results["opus192/lan/local"]!.megabytesPerHour - 480) < 2)
        #expect(abs(results["opus96/lan/local"]!.megabytesPerHour - 264) < 2)
        // WAN Standard is less than a fifth of LAN Opus 192 over the same tunnel.
        #expect(wan.megabytesPerHour < results["opus192/lan/tailscale"]!.megabytesPerHour / 5)
    }

    @Test("Data usage meter: session total and rolling MB/h")
    func usageMeter() {
        var meter = DataUsageMeter(window: 10)
        for _ in 0..<20 {
            meter.record(datagrams: 50, payloadBytes: 51_000, path: .tailscaleDirect)
        }
        #expect(meter.totalBytes == 20 * (51_000 + 50 * 88))
        #expect(meter.megabytesPerHour == 199.4)
        meter.reset()
        #expect(meter.totalBytes == 0 && meter.megabytesPerHour == 0)
    }

    @Test("Retune swaps the WAN floor in place: no reset, no dropped audio either way")
    func retuneInPlace() {
        let buffer = JitterBuffer(config: .latency(.balanced))
        var sequence: UInt32 = 0
        func feed(_ count: Int, at time: inout TimeInterval) {
            for _ in 0..<count {
                buffer.insert(
                    AudioPacket(
                        codec: .opus, sequence: sequence, sampleTime: UInt64(sequence) * 240,
                        payload: Data(count: 80)), arrivalTime: time)
                sequence &+= 1
                time += AudioFormat.frameDuration
            }
        }
        var time: TimeInterval = 0
        feed(20, at: &time)
        for _ in 0..<10 { _ = buffer.pop() }
        let before = buffer.stats
        buffer.retune(StreamProfile.wan.jitterConfig(.balanced))
        var after = buffer.stats
        #expect(after.targetFrames == AudioFormat.frames(milliseconds: 140))
        #expect(after.depthFrames == before.depthFrames)
        #expect(buffer.config.lossHorizonFrames == 14)
        // Fill deep (as a WAN stall would), then back to LAN: nothing is
        // dropped at once, the target clamps to the LAN ceiling.
        feed(100, at: &time)
        buffer.retune(StreamProfile.lan.jitterConfig(.balanced))
        feed(1, at: &time)
        after = buffer.stats
        #expect(after.overflowDropped == 0)
        #expect(after.targetFrames <= AudioFormat.frames(milliseconds: 300))
        #expect(after.rebuffers == 0)
        guard case .packet = buffer.pop() else {
            Issue.record("playout must continue across the retune")
            return
        }
    }
}
