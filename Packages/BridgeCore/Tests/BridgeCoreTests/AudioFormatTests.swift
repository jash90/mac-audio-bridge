import Testing
@testable import BridgeCore

struct AudioFormatTests {
    @Test("5 ms frames: 240 samples per channel, 960-byte PCM16 payload")
    func frameIs5Milliseconds() {
        #expect(AudioFormat.frameDurationMs == 5)
        #expect(AudioFormat.samplesPerFrame == 240)
        #expect(AudioFormat.pcm16FrameBytes == 960)
    }

    @Test("A PCM16 datagram is never IP-fragmented")
    func pcmDatagramFitsTheMTUBudget() {
        let size = AudioDatagram.encodedSize(payloadSizes: [AudioFormat.pcm16FrameBytes])
        #expect(size <= AudioFormat.maxDatagramBytes)
        #expect(AudioFormat.maxDatagramBytes <= 1472)
    }

    @Test("Millisecond-to-frame conversion rounds up")
    func framesForMilliseconds() {
        #expect(AudioFormat.frames(milliseconds: 20) == 4)
        #expect(AudioFormat.frames(milliseconds: 21) == 5)
        #expect(AudioFormat.frames(milliseconds: 0) == 1)
    }
}
