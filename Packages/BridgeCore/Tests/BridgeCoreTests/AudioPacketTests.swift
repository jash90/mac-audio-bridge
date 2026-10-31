import Testing
import Foundation
@testable import BridgeCore

struct AudioPacketTests {
    private func referencePacket() -> AudioPacket {
        AudioPacket(
            codec: .opus,
            flags: [.discontinuity],
            sequence: 0xDEAD_BEEF,
            sampleTime: 0x1122_3344_5566_7788,
            payload: Data([0xAA, 0xBB])
        )
    }

    @Test(
        "Round trip preserves all fields",
        arguments: [
            (AudioCodec.pcm16, AudioPacketFlags()),
            (.opus, [.discontinuity]),
        ] as [(AudioCodec, AudioPacketFlags)]
    )
    func roundTripPreservesFields(codec: AudioCodec, flags: AudioPacketFlags) throws {
        let packet = AudioPacket(
            codec: codec,
            flags: flags,
            sequence: 0x0102_0304,
            sampleTime: 480,
            payload: Data([0x00, 0x01, 0xFE, 0xFF])
        )
        let decoded = try AudioPacket.decode(packet.encoded())
        #expect(decoded == packet)
    }

    @Test("Round trip with empty payload and extreme field values")
    func roundTripExtremes() throws {
        let packet = AudioPacket(
            codec: .pcm16,
            sequence: .max,
            sampleTime: .max,
            payload: Data()
        )
        let decoded = try AudioPacket.decode(packet.encoded())
        #expect(decoded == packet)
        #expect(decoded.encoded().count == AudioPacket.headerSize)
    }

    @Test("Decode accepts a Data slice with non-zero startIndex")
    func decodeAcceptsNonZeroStartIndex() throws {
        let packet = referencePacket()
        var frame = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
        frame.append(packet.encoded())
        let slice = frame.dropFirst(7)
        #expect(slice.startIndex != 0)
        #expect(try AudioPacket.decode(slice) == packet)
    }

    @Test("Decode rejects empty and truncated data")
    func decodeRejectsTooShortData() {
        #expect(throws: AudioPacketError.tooShort) {
            try AudioPacket.decode(Data())
        }
        #expect(throws: AudioPacketError.tooShort) {
            try AudioPacket.decode(referencePacket().encoded().prefix(19))
        }
    }

    @Test("Decode rejects a wrong magic value")
    func decodeRejectsBadMagic() {
        var bytes = [UInt8](referencePacket().encoded())
        bytes[0] ^= 0xFF
        #expect(throws: AudioPacketError.badMagic) {
            try AudioPacket.decode(Data(bytes))
        }
    }

    @Test("Decode rejects an unsupported version")
    func decodeRejectsUnsupportedVersion() {
        var bytes = [UInt8](referencePacket().encoded())
        bytes[4] = 2
        #expect(throws: AudioPacketError.unsupportedVersion(2)) {
            try AudioPacket.decode(Data(bytes))
        }
    }

    @Test("Decode rejects an unknown codec")
    func decodeRejectsUnknownCodec() {
        var bytes = [UInt8](referencePacket().encoded())
        bytes[5] = 0x7F
        #expect(throws: AudioPacketError.unknownCodec(0x7F)) {
            try AudioPacket.decode(Data(bytes))
        }
    }

    @Test("Encoded header is byte exact for a known packet")
    func encodedHeaderIsByteExact() {
        let packet = referencePacket()
        #expect([UInt8](packet.encoded()) == [
            0x4D, 0x41, 0x42, 0x41,  // magic "MABA"
            0x01,  // version
            0x01,  // opus
            0x01,  // discontinuity flag
            0x00,  // reserved
            0xDE, 0xAD, 0xBE, 0xEF,  // sequence
            0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,  // sampleTime
            0xAA, 0xBB,  // payload
        ])
    }

    @Test(
        "Sequence comparison follows RFC 1982 including wrap-around",
        arguments: [
            (UInt32(5), UInt32(3), true),
            (UInt32(3), UInt32(5), false),
            (UInt32(7), UInt32(7), false),
            (UInt32(0), .max, true),
            (UInt32(1), .max, true),
            (.max, UInt32(0), false),
            (.max - 2, UInt32(0), false),
            (UInt32(0), .max - 2, true),
            (UInt32(0), .max - 1, true),
        ]
    )
    func sequenceIsAfterFollowsRFC1982(a: UInt32, b: UInt32, expected: Bool) {
        #expect(sequenceIsAfter(a, b) == expected)
    }
}
