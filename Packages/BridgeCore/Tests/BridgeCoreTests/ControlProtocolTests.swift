import Foundation
import Testing
@testable import BridgeCore

struct ControlProtocolTests {
    static let status = SourceStatus(
        sourceID: "8D1F0C2E-3A4B-4C5D-9E6F-7A8B9C0D1E2F", name: "Studio Mac",
        sourceTag: SourceTag.make(sourceID: "8D1F0C2E-3A4B-4C5D-9E6F-7A8B9C0D1E2F"),
        driverInstalled: true, outputIsOurs: true, streamingToYou: true,
        streamingTo: "iPhone 7KQ2", audioPlaying: true, outputDeviceName: "iPhone (Mac Audio Bridge)",
        volume: 0.75, muted: false, quality: .opus128, usedBy: nil, problem: nil)

    static let allMessages: [ControlMessage] = [
        .hello(PhoneHello(phoneID: "P1", phoneName: "iPhone 7KQ2", receiverService: "iPhone 7KQ2")),
        .connect,
        .disconnect,
        .release(byName: "Office Mac"),
        .setVolume(0.5),
        .setMuted(true),
        .setQuality(.pcm),
        .status(status),
        .claim,
    ]

    @Test("Every message survives a frame round trip")
    func roundTrips() throws {
        for message in Self.allMessages {
            var decoder = ControlFrameDecoder()
            let payloads = try decoder.append(message.frame())
            #expect(payloads.count == 1)
            #expect(try ControlMessage.decode(payload: payloads[0]) == message)
            #expect(decoder.pendingBytes == 0)
        }
    }

    @Test("Frames split at every byte boundary and concatenated frames decode in order")
    func streamReassembly() throws {
        let stream = Self.allMessages.reduce(into: Data()) { $0.append($1.frame()) }
        for chunkSize in [1, 3, 7, 64, stream.count] {
            var decoder = ControlFrameDecoder()
            var decoded: [ControlMessage] = []
            var offset = 0
            while offset < stream.count {
                let end = min(offset + chunkSize, stream.count)
                for payload in try decoder.append(stream.subdata(in: offset..<end)) {
                    decoded.append(try ControlMessage.decode(payload: payload))
                }
                offset = end
            }
            #expect(decoded == Self.allMessages)
        }
    }

    @Test("The frame header is a big-endian payload length")
    func lengthPrefix() {
        let frame = ControlMessage.connect.frame()
        let payload = ControlMessage.connect.payload()
        #expect(frame.count == 4 + payload.count)
        #expect(Array(frame.prefix(4)) == [0, 0, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
        #expect(String(decoding: payload, as: UTF8.self) == #"{"type":"connect","v":1}"#)
    }

    @Test("A different envelope version is reported as a version mismatch")
    func versionMismatch() throws {
        #expect(ControlProtocol.version == 5)
        for version in [0, 6] {
            let payload = Data(#"{"v":\#(version),"type":"connect"}"#.utf8)
            #expect(throws: ControlProtocolError.versionMismatch(version)) {
                try ControlMessage.decode(payload: payload)
            }
        }
        // Every version in minimumVersion...version is accepted.
        for version in ControlProtocol.minimumVersion...ControlProtocol.version {
            let payload = Data(#"{"v":\#(version),"type":"connect"}"#.utf8)
            #expect(try ControlMessage.decode(payload: payload) == .connect)
        }
        let payload = Data(#"{"v":6,"type":"connect"}"#.utf8)
        #expect(throws: ControlProtocolError.versionMismatch(6)) {
            try ControlMessage.decode(payload: payload)
        }
        // Even when the rest of a newer envelope is unknown to us.
        let future = Data(#"{"v":9,"type":"teleport","where":"moon"}"#.utf8)
        #expect(throws: ControlProtocolError.versionMismatch(9)) {
            try ControlMessage.decode(payload: future)
        }
    }

    @Test("Malformed payloads are rejected without killing the stream")
    func malformedPayloads() throws {
        let bad: [String] = [
            "not json",
            #"{"type":"connect"}"#,  // no version
            #"{"v":2}"#,  // no type
            #"{"v":2,"type":"teleport"}"#,  // unknown type
            #"{"v":2,"type":"release"}"#,  // missing field
            #"{"v":2,"type":"setVolume","volume":"loud"}"#,  // wrong type
            #"{"v":2,"type":"setQuality","quality":"mp3"}"#,  // unknown quality
            #"{"v":2,"type":"status","status":{"name":"x"}}"#,  // incomplete status
        ]
        for text in bad {
            #expect(throws: ControlProtocolError.malformed) {
                try ControlMessage.decode(payload: Data(text.utf8))
            }
        }
        // A malformed frame between two good ones: the good ones still decode.
        var stream = ControlMessage.connect.frame()
        let junk = Data("garbage".utf8)
        stream.append(contentsOf: [0, 0, 0, UInt8(junk.count)])
        stream.append(junk)
        stream.append(ControlMessage.claim.frame())
        var decoder = ControlFrameDecoder()
        let payloads = try decoder.append(stream)
        #expect(payloads.count == 3)
        #expect(try ControlMessage.decode(payload: payloads[0]) == .connect)
        #expect(throws: ControlProtocolError.malformed) { try ControlMessage.decode(payload: payloads[1]) }
        #expect(try ControlMessage.decode(payload: payloads[2]) == .claim)
    }

    @Test("Oversized and empty frames are fatal")
    func fatalFrames() {
        var decoder = ControlFrameDecoder()
        #expect(throws: ControlProtocolError.frameTooLarge(0x0100_0000)) {
            try decoder.append(Data([1, 0, 0, 0]))
        }
        var empty = ControlFrameDecoder()
        #expect(throws: ControlProtocolError.emptyFrame) {
            try empty.append(Data([0, 0, 0, 0]))
        }
    }

    @Test("Volume is clamped to 0...1")
    func volumeClamped() throws {
        let loud = Data(#"{"v":2,"type":"setVolume","volume":3}"#.utf8)
        #expect(try ControlMessage.decode(payload: loud) == .setVolume(1))
        let negative = Data(#"{"v":2,"type":"setVolume","volume":-1}"#.utf8)
        #expect(try ControlMessage.decode(payload: negative) == .setVolume(0))
    }

    @Test("Source tags are stable, case-insensitive and never zero")
    func sourceTags() {
        let id = "8D1F0C2E-3A4B-4C5D-9E6F-7A8B9C0D1E2F"
        #expect(SourceTag.make(sourceID: id) == SourceTag.make(sourceID: id.lowercased()))
        #expect(SourceTag.make(sourceID: id) != SourceTag.make(sourceID: "another"))
        #expect(SourceTag.make(sourceID: "") != 0)
    }

    @Test("TXT version compatibility")
    func txtCompatibility() {
        #expect(ControlProtocol.isCompatible(txtVersion: nil))
        #expect(ControlProtocol.isCompatible(txtVersion: "2"))
        #expect(!ControlProtocol.isCompatible(txtVersion: "1"))
    }

    @Test("Only local addresses are trusted")
    func localAddresses() {
        #expect(LocalNetworkAddress.isLocal(ipv4: [192, 168, 1, 20]))
        #expect(LocalNetworkAddress.isLocal(ipv4: [10, 0, 0, 1]))
        #expect(LocalNetworkAddress.isLocal(ipv4: [172, 20, 1, 1]))
        #expect(LocalNetworkAddress.isLocal(ipv4: [169, 254, 3, 4]))
        #expect(LocalNetworkAddress.isLocal(ipv4: [127, 0, 0, 1]))
        #expect(!LocalNetworkAddress.isLocal(ipv4: [172, 32, 1, 1]))
        #expect(!LocalNetworkAddress.isLocal(ipv4: [8, 8, 8, 8]))
        #expect(!LocalNetworkAddress.isLocal(ipv4: [100, 64, 0, 1]))
        #expect(!LocalNetworkAddress.isLocal(ipv4: [1, 2, 3]))

        let loopback = [UInt8](repeating: 0, count: 15) + [1]
        let linkLocal: [UInt8] = [0xFE, 0x80] + [UInt8](repeating: 0, count: 13) + [5]
        let uniqueLocal: [UInt8] = [0xFD, 0x12] + [UInt8](repeating: 7, count: 14)
        let mappedPrivate = [UInt8](repeating: 0, count: 10) + [0xFF, 0xFF, 192, 168, 0, 9]
        let mappedPublic = [UInt8](repeating: 0, count: 10) + [0xFF, 0xFF, 8, 8, 4, 4]
        let global: [UInt8] = [0x20, 0x01, 0x0D, 0xB8] + [UInt8](repeating: 1, count: 12)
        #expect(LocalNetworkAddress.isLocal(ipv6: loopback))
        #expect(LocalNetworkAddress.isLocal(ipv6: linkLocal))
        #expect(LocalNetworkAddress.isLocal(ipv6: uniqueLocal))
        #expect(LocalNetworkAddress.isLocal(ipv6: mappedPrivate))
        #expect(!LocalNetworkAddress.isLocal(ipv6: mappedPublic))
        #expect(!LocalNetworkAddress.isLocal(ipv6: global))
    }

    @Test("Audio datagrams carry the source tag")
    func datagramSourceTag() throws {
        var packer = RedundancyPacker()
        packer.sourceTag = 0xCAFE_F00D
        let frame = AudioPacket(
            codec: .opus, flags: [.discontinuity], sequence: 7, sampleTime: 7 * 240,
            payload: Data(repeating: 1, count: 120))
        let datagrams = packer.pack(frame)
        #expect(datagrams.count == 1)
        let decoded = try AudioDatagram.decode(datagrams[0])
        #expect(decoded.source == 0xCAFE_F00D)
        #expect(decoded.hasPrimary)
        #expect(datagrams[0].count == AudioDatagram.headerSize + 3 + 120)
    }
}
