import Foundation
import Testing
@testable import BridgeCore

struct OutputRestoreModelTests {
    static let bridge = OutputDeviceInfo(uid: "dev.jash90.MacAudioBridge.Device", name: "iPhone (Mac Audio Bridge)", isBuiltIn: false)
    static let speakers = OutputDeviceInfo(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers", isBuiltIn: true)
    static let airpods = OutputDeviceInfo(uid: "AA-BB-CC:output", name: "AirPods", isBuiltIn: false)
    static let display = OutputDeviceInfo(uid: "Display:1", name: "LG UltraFine", isBuiltIn: false)

    @Test("Remembers the last non-bridge output and restores it")
    func remembersAndRestores() {
        var model = OutputRestoreModel(bridgeUID: Self.bridge.uid)
        #expect(model.observeDefaultOutput(Self.airpods) == .none)
        #expect(model.observeDefaultOutput(Self.bridge) == .becameOurs)
        #expect(model.remembered == Self.airpods)
        #expect(model.restoreTarget(available: [Self.speakers, Self.airpods, Self.bridge]) == Self.airpods)
        #expect(model.observeDefaultOutput(Self.airpods) == .leftOurs)
    }

    @Test("Remembered device gone: built-in, then any other output, then nothing")
    func fallbacks() {
        var model = OutputRestoreModel(bridgeUID: Self.bridge.uid)
        _ = model.observeDefaultOutput(Self.airpods)
        _ = model.observeDefaultOutput(Self.bridge)
        #expect(model.restoreTarget(available: [Self.display, Self.speakers, Self.bridge]) == Self.speakers)
        #expect(model.restoreTarget(available: [Self.display, Self.bridge]) == Self.display)
        #expect(model.restoreTarget(available: [Self.bridge]) == nil)
        #expect(model.restoreTarget(available: []) == nil)
    }

    @Test("Our device already default at launch is not a takeover")
    func launchIsNotATransition() {
        var model = OutputRestoreModel(bridgeUID: Self.bridge.uid, remembered: Self.speakers)
        #expect(model.observeDefaultOutput(Self.bridge) == .none)
        #expect(model.observeDefaultOutput(Self.bridge) == .none)
        #expect(model.remembered == Self.speakers)
        #expect(model.observeDefaultOutput(Self.speakers) == .leftOurs)
        #expect(model.observeDefaultOutput(Self.bridge) == .becameOurs)
    }

    @Test("A persisted bridge UID is never remembered as the device to restore")
    func neverRemembersBridge() {
        let model = OutputRestoreModel(bridgeUID: Self.bridge.uid, remembered: Self.bridge)
        #expect(model.remembered == nil)
        #expect(model.restoreTarget(available: [Self.bridge, Self.speakers]) == Self.speakers)
    }

    @Test("Switching between other outputs updates the remembered one without transitions")
    func otherSwitches() {
        var model = OutputRestoreModel(bridgeUID: Self.bridge.uid)
        _ = model.observeDefaultOutput(Self.speakers)
        #expect(model.observeDefaultOutput(Self.airpods) == .none)
        #expect(model.remembered == Self.airpods)
        #expect(model.observeDefaultOutput(nil) == .none)
        #expect(model.observeDefaultOutput(Self.bridge) == .becameOurs)
        #expect(model.remembered == Self.airpods)
    }
}
