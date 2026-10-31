import Foundation
import Testing
@testable import BridgeCore

struct SourceArbiterTests {
    static let idA = "AAAAAAAA-0000-0000-0000-000000000001"
    static let idB = "BBBBBBBB-0000-0000-0000-000000000002"
    static var tagA: UInt32 { SourceTag.make(sourceID: idA) }
    static var tagB: UInt32 { SourceTag.make(sourceID: idB) }

    static func status(_ id: String, _ name: String, streaming: Bool) -> SourceStatus {
        SourceStatus(
            sourceID: id, name: name, sourceTag: SourceTag.make(sourceID: id), driverInstalled: true,
            outputIsOurs: streaming, streamingToYou: streaming, streamingTo: streaming ? "iPhone" : nil,
            audioPlaying: streaming, outputDeviceName: streaming ? "iPhone (Mac Audio Bridge)" : "Speakers",
            volume: 1, muted: false, quality: .opus192, usedBy: nil, problem: nil)
    }

    /// Two Macs, both browsed and control-connected, both idle.
    static func twoMacs() -> SourceArbiter {
        var arbiter = SourceArbiter()
        for (id, name) in [(idA, "Mac A"), (idB, "Mac B")] {
            arbiter.sourceSeen(id: id, name: name)
            arbiter.controlConnected(id: id)
            _ = arbiter.statusReceived(id: id, status(id, name, streaming: false))
        }
        return arbiter
    }

    @Test("Connect A, then connect B: A is released by name, B is connected")
    func connectThenSwitch() {
        var arbiter = Self.twoMacs()
        #expect(arbiter.gateMode == .adoptAny(excluding: []))

        #expect(arbiter.userConnect(id: Self.idA) == [.send(to: Self.idA, .connect)])
        #expect(arbiter.activeID == Self.idA)
        #expect(arbiter.gateMode == .locked(Self.tagA))
        #expect(arbiter.statusReceived(id: Self.idA, Self.status(Self.idA, "Mac A", streaming: true)).isEmpty)

        let effects = arbiter.userConnect(id: Self.idB)
        #expect(effects == [
            .send(to: Self.idA, .release(byName: "Mac B")),
            .send(to: Self.idB, .connect),
        ])
        #expect(arbiter.activeID == Self.idB)
        #expect(arbiter.lastUsedID == Self.idB)
        #expect(arbiter.gateMode == .locked(Self.tagB))

        // A still reports streaming (the release is in flight): no second release.
        #expect(arbiter.statusReceived(id: Self.idA, Self.status(Self.idA, "Mac A", streaming: true)).isEmpty)
        // A stops; B starts; nothing else to do.
        #expect(arbiter.statusReceived(id: Self.idA, Self.status(Self.idA, "Mac A", streaming: false)).isEmpty)
        #expect(arbiter.statusReceived(id: Self.idB, Self.status(Self.idB, "Mac B", streaming: true)).isEmpty)
        #expect(arbiter.activeID == Self.idB)
    }

    @Test("A stale not-streaming status right after connect does not end the activation")
    func staleStatusAfterConnect() {
        var arbiter = Self.twoMacs()
        _ = arbiter.userConnect(id: Self.idA)
        #expect(arbiter.statusReceived(id: Self.idA, Self.status(Self.idA, "Mac A", streaming: false)).isEmpty)
        #expect(arbiter.activeID == Self.idA)
    }

    @Test("Mac-initiated takeover: B claims while A streams, A is released")
    func macInitiatedTakeover() {
        var arbiter = Self.twoMacs()
        _ = arbiter.userConnect(id: Self.idA)
        _ = arbiter.statusReceived(id: Self.idA, Self.status(Self.idA, "Mac A", streaming: true))

        let effects = arbiter.claimReceived(id: Self.idB)
        #expect(effects == [.send(to: Self.idA, .release(byName: "Mac B"))])
        #expect(arbiter.activeID == Self.idB)
        #expect(arbiter.gateMode == .locked(Self.tagB))

        // The newest explicit action wins: a tap on A takes it back.
        let back = arbiter.userConnect(id: Self.idA)
        #expect(back == [.send(to: Self.idB, .release(byName: "Mac A")), .send(to: Self.idA, .connect)])
        #expect(arbiter.activeID == Self.idA)
    }

    @Test("A source streaming to us while another is active is released once per run")
    func unclaimedStreamIsReleased() {
        var arbiter = Self.twoMacs()
        _ = arbiter.userConnect(id: Self.idA)
        let first = arbiter.statusReceived(id: Self.idB, Self.status(Self.idB, "Mac B", streaming: true))
        #expect(first == [.send(to: Self.idB, .release(byName: "Mac A"))])
        #expect(arbiter.statusReceived(id: Self.idB, Self.status(Self.idB, "Mac B", streaming: true)).isEmpty)
        #expect(arbiter.activeID == Self.idA)
        // After stopping and streaming again (without a claim): released again.
        _ = arbiter.statusReceived(id: Self.idB, Self.status(Self.idB, "Mac B", streaming: false))
        let again = arbiter.statusReceived(id: Self.idB, Self.status(Self.idB, "Mac B", streaming: true))
        #expect(again == [.send(to: Self.idB, .release(byName: "Mac A"))])
    }

    @Test("With nothing active, a Mac already streaming to us is adopted")
    func adoptStreamingAtLaunch() {
        var arbiter = SourceArbiter()
        arbiter.sourceSeen(id: Self.idA, name: "Mac A")
        arbiter.controlConnected(id: Self.idA)
        let effects = arbiter.statusReceived(id: Self.idA, Self.status(Self.idA, "Mac A", streaming: true))
        #expect(effects.isEmpty)
        #expect(arbiter.activeID == Self.idA)
        #expect(arbiter.lastUsedID == Self.idA)

        // A second Mac streaming at the same time is released.
        arbiter.sourceSeen(id: Self.idB, name: "Mac B")
        arbiter.controlConnected(id: Self.idB)
        let second = arbiter.statusReceived(id: Self.idB, Self.status(Self.idB, "Mac B", streaming: true))
        #expect(second == [.send(to: Self.idB, .release(byName: "Mac A"))])
    }

    @Test("Disconnect: nothing active, the Mac is excluded until it claims")
    func disconnect() {
        var arbiter = Self.twoMacs()
        _ = arbiter.userConnect(id: Self.idA)
        _ = arbiter.statusReceived(id: Self.idA, Self.status(Self.idA, "Mac A", streaming: true))

        #expect(arbiter.userDisconnect(id: Self.idA) == [.send(to: Self.idA, .disconnect)])
        #expect(arbiter.activeID == nil)
        #expect(arbiter.lastUsedID == Self.idA)
        #expect(arbiter.gateMode == .adoptAny(excluding: [Self.tagA]))
        // Its in-flight streaming status neither re-adopts it nor re-releases it.
        #expect(arbiter.statusReceived(id: Self.idA, Self.status(Self.idA, "Mac A", streaming: true)).isEmpty)
        #expect(arbiter.activeID == nil)
        arbiter.audioAdopted(tag: Self.tagA)
        #expect(arbiter.activeID == nil)
        _ = arbiter.statusReceived(id: Self.idA, Self.status(Self.idA, "Mac A", streaming: false))

        // The Mac's user selects our output again: a claim brings it back.
        #expect(arbiter.claimReceived(id: Self.idA).isEmpty)
        #expect(arbiter.activeID == Self.idA)
        #expect(arbiter.gateMode == .locked(Self.tagA))
    }

    @Test("The active Mac stopping on its own leaves nothing active, reconnect is offered")
    func activeStopsOnMac() {
        var arbiter = Self.twoMacs()
        _ = arbiter.userConnect(id: Self.idA)
        _ = arbiter.statusReceived(id: Self.idA, Self.status(Self.idA, "Mac A", streaming: true))
        _ = arbiter.statusReceived(id: Self.idA, Self.status(Self.idA, "Mac A", streaming: false))
        #expect(arbiter.activeID == nil)
        #expect(arbiter.gateMode == .adoptAny(excluding: []))
        #expect(arbiter.reconnectLast() == [.send(to: Self.idA, .connect)])
        #expect(arbiter.activeID == Self.idA)
    }

    @Test("A disappears: nothing active, A stays listed offline as last used, reconnect waits for it")
    func activeDisappears() {
        var arbiter = Self.twoMacs()
        _ = arbiter.userConnect(id: Self.idA)
        _ = arbiter.statusReceived(id: Self.idA, Self.status(Self.idA, "Mac A", streaming: true))

        arbiter.sourceVanished(id: Self.idA)
        #expect(arbiter.activeID == Self.idA)  // control connection still up
        arbiter.controlDisconnected(id: Self.idA)
        #expect(arbiter.activeID == nil)
        #expect(arbiter.lastUsedID == Self.idA)
        #expect(arbiter.sources[Self.idA]?.isOnline == false)
        #expect(arbiter.sources[Self.idA]?.status == nil)
        #expect(arbiter.listed.map(\.id) == [Self.idA, Self.idB])
        #expect(arbiter.gateMode == .adoptAny(excluding: []))
        #expect(arbiter.reconnectLast().isEmpty)  // offline: nothing to send

        // Browsed again but the control connection is not up yet: still nothing.
        arbiter.sourceSeen(id: Self.idA, name: "Mac A")
        #expect(arbiter.userConnect(id: Self.idA).isEmpty)
        #expect(arbiter.activeID == nil)

        // B (not last used) going offline is dropped from the list.
        arbiter.sourceVanished(id: Self.idB)
        arbiter.controlDisconnected(id: Self.idB)
        #expect(arbiter.sources[Self.idB] == nil)

        // The control connection comes up: one tap reconnects.
        arbiter.controlConnected(id: Self.idA)
        #expect(arbiter.reconnectLast() == [.send(to: Self.idA, .connect)])
        #expect(arbiter.activeID == Self.idA)
    }

    @Test("The persisted last used source is listed before discovery")
    func persistedLastUsed() {
        var arbiter = SourceArbiter(lastUsed: (Self.idA, "Mac A"))
        #expect(arbiter.listed.map(\.name) == ["Mac A"])
        #expect(arbiter.lastUsed?.isOnline == false)
        #expect(arbiter.userConnect(id: Self.idA).isEmpty)
        arbiter.sourceSeen(id: Self.idA, name: "Mac A")
        arbiter.controlConnected(id: Self.idA)
        #expect(arbiter.reconnectLast() == [.send(to: Self.idA, .connect)])
    }

    @Test("Audio adoption: a known streaming Mac becomes active, a stale one does not, unknown tags lock until silent")
    func audioAdoption() {
        var arbiter = Self.twoMacs()
        // B's status says it is not streaming: a stray datagram does not adopt it.
        arbiter.audioAdopted(tag: Self.tagB)
        #expect(arbiter.activeID == nil)
        #expect(arbiter.gateMode == .adoptAny(excluding: []))

        // A Mac without a control connection (unknown tag).
        arbiter.audioAdopted(tag: 0x1234)
        #expect(arbiter.gateMode == .locked(0x1234))
        arbiter.audioStopped(tag: 0x1234)
        #expect(arbiter.gateMode == .adoptAny(excluding: []))

        // A Mac whose status has not arrived yet is adopted by its audio.
        arbiter.sourceSeen(id: "C", name: "Mac C")
        arbiter.audioAdopted(tag: SourceTag.make(sourceID: "C"))
        #expect(arbiter.activeID == "C")
    }

    @Test("Packets from a non-active source are dropped; switching resets once on a primary")
    func gateFiltersSources() {
        var arbiter = Self.twoMacs()
        _ = arbiter.userConnect(id: Self.idA)
        var gate = SourceGate()
        gate.setMode(arbiter.gateMode)

        #expect(gate.admit(tag: Self.tagA, hasPrimary: true) == .accept(newStream: true, adopted: false))
        #expect(gate.admit(tag: Self.tagA, hasPrimary: true) == .accept(newStream: false, adopted: false))
        #expect(gate.admit(tag: Self.tagB, hasPrimary: true) == .drop)
        #expect(gate.admit(tag: 0, hasPrimary: true) == .drop)

        _ = arbiter.claimReceived(id: Self.idB)
        gate.setMode(arbiter.gateMode)
        // Both Macs stream for a moment: A is dropped from now on.
        #expect(gate.admit(tag: Self.tagA, hasPrimary: true) == .drop)
        // B's first datagram without a primary cannot start the new stream.
        #expect(gate.admit(tag: Self.tagB, hasPrimary: false) == .drop)
        #expect(gate.admit(tag: Self.tagB, hasPrimary: true) == .accept(newStream: true, adopted: false))
        #expect(gate.admit(tag: Self.tagB, hasPrimary: false) == .accept(newStream: false, adopted: false))
        #expect(gate.admit(tag: Self.tagA, hasPrimary: true) == .drop)
    }

    @Test("The gate adopts the first non-excluded stream and locks onto it")
    func gateAdopts() {
        var gate = SourceGate(mode: .adoptAny(excluding: [Self.tagA]))
        #expect(gate.admit(tag: Self.tagA, hasPrimary: true) == .drop)
        #expect(gate.admit(tag: Self.tagB, hasPrimary: true) == .accept(newStream: true, adopted: true))
        #expect(gate.mode == .locked(Self.tagB))
        #expect(gate.admit(tag: 0x99, hasPrimary: true) == .drop)
        // Reopened while B keeps streaming: B continues without a reset.
        gate.setMode(.adoptAny(excluding: []))
        #expect(gate.admit(tag: Self.tagB, hasPrimary: false) == .accept(newStream: false, adopted: true))
    }
}
