import Foundation
import Testing
@testable import BridgeCore

struct ReceiverSelectionTests {
    @Test("A single visible receiver is picked automatically")
    func singleAutoPick() {
        var selection = ReceiverSelection(storedSelection: nil, manualHost: "", now: 0)
        #expect(selection.target == nil)
        #expect(selection.status == .noReceiver)

        selection.updateVisibleServices(["iPhone 7KQ2"], now: 1)

        #expect(selection.target == .service("iPhone 7KQ2"))
        #expect(selection.status == .target(.service("iPhone 7KQ2"), automatic: true))
    }

    @Test("Several receivers and no selection ask the user to choose")
    func severalReceiversNeedAChoice() {
        var selection = ReceiverSelection(storedSelection: nil, manualHost: "", now: 0)
        selection.updateVisibleServices(["iPhone B", "iPhone A", "iPhone A"], now: 0)

        #expect(selection.target == nil)
        #expect(selection.status == .chooseReceiver(count: 2))
        #expect(selection.visibleServices == ["iPhone A", "iPhone B"])
    }

    @Test("The automatic pick stays put when a second receiver appears")
    func automaticPickIsSticky() {
        var selection = ReceiverSelection(storedSelection: nil, manualHost: "", now: 0)
        selection.updateVisibleServices(["iPhone A"], now: 0)
        selection.updateVisibleServices(["iPhone A", "iPhone B"], now: 1)

        #expect(selection.target == .service("iPhone A"))
    }

    @Test("A stored selection wins over the automatic pick and the manual host")
    func storedSelectionWins() {
        var selection = ReceiverSelection(
            storedSelection: "iPhone B", manualHost: "192.168.1.151", now: 0)
        selection.updateVisibleServices(["iPhone A", "iPhone B"], now: 0)
        #expect(selection.target == .service("iPhone B"))
        #expect(selection.status == .target(.service("iPhone B"), automatic: false))

        // Even when another receiver is the only visible one, the stored
        // selection is looked for — never silently replaced.
        selection.updateVisibleServices(["iPhone A"], now: 10)
        selection.tick(now: 20)
        #expect(selection.target == nil)
        #expect(selection.status == .looking("iPhone B"))
    }

    @Test("Picking a receiver overrides the automatic one; nil returns to automatic")
    func selectAndClear() {
        var selection = ReceiverSelection(storedSelection: nil, manualHost: "", now: 0)
        selection.updateVisibleServices(["iPhone A", "iPhone B"], now: 0)
        selection.select("iPhone B", now: 1)
        #expect(selection.target == .service("iPhone B"))

        selection.select(nil, now: 2)
        #expect(selection.status == .chooseReceiver(count: 2))
        selection.select("", now: 3)
        #expect(selection.storedSelection == nil)
    }

    @Test("A selection that disappears turns into looking after the grace")
    func selectionDisappearsThenLooking() {
        var selection = ReceiverSelection(storedSelection: "iPhone A", manualHost: "", now: 0)
        selection.updateVisibleServices(["iPhone A"], now: 0)
        #expect(selection.target == .service("iPhone A"))

        selection.updateVisibleServices([], now: 10)
        // Within the grace: target kept (stream keeps running).
        #expect(selection.target == .service("iPhone A"))
        selection.tick(now: 11.5)
        #expect(selection.target == .service("iPhone A"))

        selection.tick(now: 12.0)
        #expect(selection.target == nil)
        #expect(selection.status == .looking("iPhone A"))
    }

    @Test("A stored selection not visible at launch is looked for")
    func storedSelectionAtLaunchIsLooking() {
        let selection = ReceiverSelection(storedSelection: "iPhone A", manualHost: "", now: 0)
        #expect(selection.target == nil)
        #expect(selection.status == .looking("iPhone A"))
    }

    @Test("A looked-for selection resumes as soon as it reappears")
    func selectionReappearsResumes() {
        var selection = ReceiverSelection(storedSelection: "iPhone A", manualHost: "", now: 0)
        selection.updateVisibleServices(["iPhone A"], now: 0)
        selection.updateVisibleServices([], now: 1)
        selection.tick(now: 10)
        #expect(selection.status == .looking("iPhone A"))

        selection.updateVisibleServices(["iPhone A"], now: 11)
        #expect(selection.target == .service("iPhone A"))
        #expect(selection.status == .target(.service("iPhone A"), automatic: false))

        // The grace restarts from scratch on the next loss.
        selection.updateVisibleServices([], now: 30)
        selection.tick(now: 31)
        #expect(selection.target == .service("iPhone A"))
    }

    @Test("Receiver app restart: deregister + re-register within the grace keeps the target")
    func receiverRestartKeepsTarget() {
        var selection = ReceiverSelection(storedSelection: nil, manualHost: "", now: 0)
        selection.updateVisibleServices(["iPhone A"], now: 0)

        // Old listener cancelled → service removed; new listener → re-added.
        selection.updateVisibleServices([], now: 5.0)
        #expect(selection.target == .service("iPhone A"))
        selection.updateVisibleServices(["iPhone A"], now: 5.8)
        #expect(selection.target == .service("iPhone A"))
        #expect(selection.status == .target(.service("iPhone A"), automatic: true))

        // A later, unrelated loss gets the full grace again.
        selection.updateVisibleServices([], now: 20)
        selection.tick(now: 21.9)
        #expect(selection.target == .service("iPhone A"))
    }

    @Test("An automatic receiver that is gone for good falls back to nothing")
    func automaticReceiverGone() {
        var selection = ReceiverSelection(storedSelection: nil, manualHost: "", now: 0)
        selection.updateVisibleServices(["iPhone A"], now: 0)
        selection.updateVisibleServices([], now: 1)
        selection.tick(now: 3.5)
        #expect(selection.target == nil)
        #expect(selection.status == .noReceiver)
    }

    @Test("Manual host is the fallback when no service is selected")
    func manualFallback() {
        var selection = ReceiverSelection(storedSelection: nil, manualHost: " 192.168.1.171 ", now: 0)
        #expect(selection.target == .host("192.168.1.171"))
        #expect(selection.status == .target(.host("192.168.1.171"), automatic: false))

        // Several receivers and no choice: the manual host still applies.
        selection.updateVisibleServices(["iPhone A", "iPhone B"], now: 1)
        #expect(selection.target == .host("192.168.1.171"))

        // A single discovered receiver is a selected (automatic) service.
        selection.updateVisibleServices(["iPhone A"], now: 2)
        #expect(selection.target == .service("iPhone A"))

        // Clearing the manual host with nothing selectable → no target.
        selection.updateVisibleServices(["iPhone A", "iPhone B"], now: 3)
        selection.select(nil, now: 3)
        selection.setManualHost("", now: 4)
        #expect(selection.target == .service("iPhone A"))
        selection.updateVisibleServices([], now: 5)
        selection.tick(now: 10)
        #expect(selection.target == nil)
    }

    @Test("A stored selection that is missing never falls back to the manual host")
    func storedSelectionDoesNotFallBackToManual() {
        let selection = ReceiverSelection(
            storedSelection: "iPhone A", manualHost: "192.168.1.151", now: 0)
        #expect(selection.target == nil)
        #expect(selection.status == .looking("iPhone A"))
    }

    @Test("Display names cover both target kinds")
    func displayNames() {
        #expect(ReceiverTarget.service("iPhone A").displayName == "iPhone A")
        #expect(ReceiverTarget.host("10.0.0.2").displayName == "10.0.0.2")
    }
}

struct ReceiverLivenessTests {
    @Test("Keepalives arriving mean alive")
    func alive() {
        let result = ReceiverLiveness.assess(
            connectionAge: 60, isReady: true, keepaliveAge: 0.02, unansweredSendAge: 0.01)
        #expect(result.state == .alive)
        #expect(result.decision == .keep)
    }

    @Test("No keepalive for 3 s while sending forces a reconnect")
    func keepaliveTimeoutReconnects() {
        let early = ReceiverLiveness.assess(
            connectionAge: 60, isReady: true, keepaliveAge: 2.9, unansweredSendAge: 2.9)
        #expect(early.decision == .keep)
        #expect(early.state == .alive)

        let timedOut = ReceiverLiveness.assess(
            connectionAge: 60, isReady: true, keepaliveAge: 3.0, unansweredSendAge: 3.0)
        #expect(timedOut.state == .noResponse)
        #expect(timedOut.decision == .reconnect)
    }

    @Test("A fresh connection gets the full timeout before the first keepalive")
    func freshConnectionWaits() {
        let result = ReceiverLiveness.assess(
            connectionAge: 1, isReady: true, keepaliveAge: nil, unansweredSendAge: 1)
        #expect(result.state == .connecting)
        #expect(result.decision == .keep)

        let never = ReceiverLiveness.assess(
            connectionAge: 3.2, isReady: true, keepaliveAge: nil, unansweredSendAge: 3.1)
        #expect(never.decision == .reconnect)
    }

    @Test("Nothing sent (no audio playing) is idle, never a timeout")
    func idleDoesNotReconnect() {
        let result = ReceiverLiveness.assess(
            connectionAge: 600, isReady: true, keepaliveAge: 300, unansweredSendAge: nil)
        #expect(result.state == .idle)
        #expect(result.decision == .keep)
    }

    @Test("Sending resumes after idle: connecting until the first keepalive")
    func resumeAfterIdle() {
        let result = ReceiverLiveness.assess(
            connectionAge: 600, isReady: true, keepaliveAge: 300, unansweredSendAge: 0.5)
        #expect(result.state == .connecting)
        #expect(result.decision == .keep)
    }

    @Test("A connection that never becomes ready is retried every timeout")
    func notReadyRetries() {
        let early = ReceiverLiveness.assess(
            connectionAge: 2, isReady: false, keepaliveAge: nil, unansweredSendAge: nil)
        #expect(early == (.connecting, .keep))

        let stuck = ReceiverLiveness.assess(
            connectionAge: 3, isReady: false, keepaliveAge: nil, unansweredSendAge: nil)
        #expect(stuck == (.noResponse, .reconnect))
    }

    @Test("Receiver restart then new address: selection keeps the target, liveness recreates the connection")
    func restartWithNewAddressRecovers() {
        // Service briefly re-registered (receiver relaunched on a new DHCP
        // address): the selection keeps the same target...
        var selection = ReceiverSelection(storedSelection: "iPhone A", manualHost: "", now: 0)
        selection.updateVisibleServices(["iPhone A"], now: 0)
        selection.updateVisibleServices([], now: 100)
        selection.updateVisibleServices(["iPhone A"], now: 101)
        #expect(selection.target == .service("iPhone A"))

        // ...while the old connection's datagrams go to the old address, so
        // no keepalive comes back and liveness asks for a fresh connection,
        // which resolves the service again.
        let assessment = ReceiverLiveness.assess(
            connectionAge: 104, isReady: true, keepaliveAge: 4, unansweredSendAge: 3.98)
        #expect(assessment.decision == .reconnect)

        // The new connection starts from zero and gets its own timeout.
        let fresh = ReceiverLiveness.assess(
            connectionAge: 0.5, isReady: true, keepaliveAge: nil, unansweredSendAge: 0.49)
        #expect(fresh.decision == .keep)
    }
}

struct ReceiverServiceTests {
    @Test("Service name is device name plus suffix")
    func serviceName() {
        #expect(ReceiverService.serviceName(deviceName: "iPhone", suffix: "7KQ2") == "iPhone 7KQ2")
        #expect(ReceiverService.serviceName(deviceName: "  ", suffix: "7KQ2") == "iPhone 7KQ2")
    }

    @Test("Long names are trimmed to the 63-byte DNS-SD limit")
    func longNameFits() {
        let long = String(repeating: "ż", count: 60)
        let name = ReceiverService.serviceName(deviceName: long, suffix: "7KQ2")
        #expect(name.utf8.count <= ReceiverService.maxNameBytes)
        #expect(name.hasSuffix(" 7KQ2"))
    }

    @Test("Suffixes are valid and deterministic for a seeded generator")
    func suffixes() {
        var generator = SeededGenerator(seed: 42)
        let first = ReceiverService.makeSuffix(using: &generator)
        #expect(ReceiverService.isValidSuffix(first))
        #expect(ReceiverService.isValidSuffix(ReceiverService.makeSuffix()))
        #expect(!ReceiverService.isValidSuffix("0O1I"))
        #expect(!ReceiverService.isValidSuffix("ABC"))
    }

    @Test("Only protocol version 3 (or a not-yet-known TXT) is compatible")
    func versionCompatibility() {
        #expect(ReceiverService.isCompatible(version: "3"))
        #expect(ReceiverService.isCompatible(version: nil))
        #expect(!ReceiverService.isCompatible(version: "1"))  // 10 ms single-frame datagrams
        #expect(!ReceiverService.isCompatible(version: "2"))  // no source tag
        #expect(!ReceiverService.isCompatible(version: "4"))
    }
}

/// SplitMix64 — reproducible randomness for the suffix test.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
