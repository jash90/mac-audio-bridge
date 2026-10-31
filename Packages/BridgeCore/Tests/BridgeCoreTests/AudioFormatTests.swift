import Testing
@testable import BridgeCore

struct AudioFormatTests {
    @Test
    func samplesPerFrameIs480PerChannel() {
        #expect(AudioFormat.samplesPerFrame == 480)
    }
}
