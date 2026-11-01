import Foundation
import Testing
@testable import BridgeCore

struct MediaControlTests {
    static let track = NowPlayingInfo(
        title: "Tamagotchi", artist: "Taco Hemingway", album: "Café Belga", app: "Spotify",
        isPlaying: true, duration: 201.5, elapsed: 12, artwork: Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]),
        canControl: true)

    // MARK: - Protocol

    @Test("media and nowPlaying survive a frame round trip")
    func roundTrips() throws {
        var messages: [ControlMessage] = MediaCommand.allCases.map { .media($0) }
        messages.append(.nowPlaying(Self.track))
        messages.append(.nowPlaying(NowPlayingInfo(title: "Live", isPlaying: false, canControl: false)))
        messages.append(.nowPlaying(nil))
        for message in messages {
            var decoder = ControlFrameDecoder()
            let payloads = try decoder.append(message.frame())
            #expect(payloads.count == 1)
            #expect(try ControlMessage.decode(payload: payloads[0]) == message)
        }
    }

    @Test("Version 1 messages keep v:1 on the wire, the new ones carry v:2")
    func perMessageVersion() throws {
        #expect(ControlProtocol.version == 5)
        for message in ControlProtocolTests.allMessages {
            #expect(message.requiredVersion == 1)
            let probe = try JSONSerialization.jsonObject(with: message.payload()) as? [String: Any]
            #expect(probe?["v"] as? Int == 1)
        }
        let media = String(decoding: ControlMessage.media(.togglePlayPause).payload(), as: UTF8.self)
        #expect(media == #"{"media":"togglePlayPause","type":"media","v":2}"#)
        #expect(String(decoding: ControlMessage.nowPlaying(nil).payload(), as: UTF8.self)
            == #"{"type":"nowPlaying","v":2}"#)
    }

    @Test("A version 1 status (no protocolVersion) still decodes; a new status reports the current version")
    func statusProtocolVersion() throws {
        var old = ControlProtocolTests.status
        old.protocolVersion = nil
        let oldPayload = ControlMessage.status(old).payload()
        #expect(!String(decoding: oldPayload, as: UTF8.self).contains("protocolVersion"))
        guard case .status(let decodedOld) = try ControlMessage.decode(payload: oldPayload) else {
            Issue.record("not a status")
            return
        }
        #expect(decodedOld.protocolVersion == nil)
        #expect(ControlProtocolTests.status.protocolVersion == ControlProtocol.version)
    }

    @Test("Malformed media frames are rejected")
    func malformed() {
        for text in [
            #"{"v":2,"type":"media"}"#,
            #"{"v":2,"type":"media","media":"rewind"}"#,
            #"{"v":2,"type":"nowPlaying","nowPlaying":{"title":"x"}}"#,
        ] {
            #expect(throws: ControlProtocolError.malformed) {
                try ControlMessage.decode(payload: Data(text.utf8))
            }
        }
    }

    @Test("A frame with the largest artwork fits the frame limit")
    func artworkFits() {
        var info = Self.track
        info.artwork = Data(repeating: 0xAB, count: NowPlayingInfo.maxArtworkBytes)
        #expect(ControlMessage.nowPlaying(info).payload().count < ControlProtocol.maxFrameBytes)
    }

    // MARK: - Routing

    static func connectedArbiter(protocolVersion: Int?, muted: Bool = false) -> SourceArbiter {
        var arbiter = SourceArbiter()
        let id = SourceArbiterTests.idA
        arbiter.sourceSeen(id: id, name: "Mac A")
        arbiter.controlConnected(id: id)
        var status = SourceArbiterTests.status(id, "Mac A", streaming: false)
        status.protocolVersion = protocolVersion
        status.muted = muted
        _ = arbiter.statusReceived(id: id, status)
        _ = arbiter.userConnect(id: id)
        return arbiter
    }

    @Test("Remote commands go to the active Mac when it reported what plays")
    func routesToActiveMac() {
        let arbiter = Self.connectedArbiter(protocolVersion: 2)
        var router = MediaControlRouter()
        router.nowPlayingReceived(id: SourceArbiterTests.idA, Self.track)
        for command in MediaCommand.allCases {
            #expect(router.route(command, active: arbiter.active) == .mac(id: SourceArbiterTests.idA, command))
        }
    }

    @Test("Nothing active: no route")
    func noActive() {
        var router = MediaControlRouter()
        router.nowPlayingReceived(id: SourceArbiterTests.idA, Self.track)
        #expect(router.route(.togglePlayPause, active: nil) == .none)
        #expect(!router.canControl(nil))
    }

    @Test("Fallback to mute when nothing is known, the Mac is version 1, or it cannot control")
    func localFallback() {
        let id = SourceArbiterTests.idA
        // Nothing reported yet.
        let arbiter = Self.connectedArbiter(protocolVersion: 2, muted: true)
        var router = MediaControlRouter()
        #expect(router.route(.play, active: arbiter.active) == .setMuted(id: id, false))
        #expect(router.route(.pause, active: arbiter.active) == .setMuted(id: id, true))
        #expect(router.route(.togglePlayPause, active: arbiter.active) == .setMuted(id: id, false))
        #expect(router.route(.nextTrack, active: arbiter.active) == .none)
        #expect(router.route(.previousTrack, active: arbiter.active) == .none)
        // Mac says nothing plays.
        router.nowPlayingReceived(id: id, nil)
        #expect(router.route(.togglePlayPause, active: arbiter.active) == .setMuted(id: id, false))
        // The Mac lacks the permission.
        var blocked = Self.track
        blocked.canControl = false
        router.nowPlayingReceived(id: id, blocked)
        #expect(router.route(.pause, active: arbiter.active) == .setMuted(id: id, true))
        // A version 1 Mac never gets `media` (it would close the connection).
        let old = Self.connectedArbiter(protocolVersion: nil)
        router.nowPlayingReceived(id: id, Self.track)
        #expect(router.route(.togglePlayPause, active: old.active) == .setMuted(id: id, true))
        #expect(!router.canControl(old.active))
    }

    @Test("A lost control connection forgets what the Mac reported")
    func forgetOnDisconnect() {
        var arbiter = Self.connectedArbiter(protocolVersion: 2)
        var router = MediaControlRouter()
        router.nowPlayingReceived(id: SourceArbiterTests.idA, Self.track)
        #expect(router.canControl(arbiter.active))
        router.forget(id: SourceArbiterTests.idA)
        #expect(router.nowPlaying.isEmpty)
        #expect(router.route(.pause, active: arbiter.active) == .setMuted(id: SourceArbiterTests.idA, true))
        // Connection down but still listed and active: commands cannot reach it.
        router.nowPlayingReceived(id: SourceArbiterTests.idA, Self.track)
        arbiter.controlDisconnected(id: SourceArbiterTests.idA)
        #expect(!router.canControl(arbiter.active))
    }

    // MARK: - Throttling

    @Test("First value and real changes go out at once; an unchanged one does not")
    func throttleSendsChanges() {
        var throttle = NowPlayingThrottle(minInterval: 0.5)
        #expect(throttle.current == .none)
        #expect(throttle.offer(nil, now: 0) == .send(nil))
        #expect(throttle.offer(nil, now: 1) == .unchanged)
        #expect(throttle.offer(Self.track, now: 2) == .send(Self.track))
        #expect(throttle.offer(Self.track, now: 3) == .unchanged)
        var paused = Self.track
        paused.isPlaying = false
        #expect(throttle.offer(paused, now: 4) == .send(paused))
        #expect(throttle.current == .some(paused))
    }

    @Test("A burst collapses into its last value, sent when the interval is over")
    func throttleBurst() {
        var throttle = NowPlayingThrottle(minInterval: 0.5)
        #expect(throttle.offer(Self.track, now: 10) == .send(Self.track))
        var next = Self.track
        next.title = "Next"
        var third = Self.track
        third.title = "Third"
        #expect(throttle.offer(next, now: 10.1) == .deferred(until: 10.5))
        #expect(throttle.offer(third, now: 10.2) == .deferred(until: 10.5))
        #expect(throttle.current == .some(third))
        #expect(throttle.due(now: 10.3) == nil)
        #expect(throttle.due(now: 10.5) == .some(third))
        #expect(throttle.due(now: 11) == nil)
        // Back to the value already sent before the deferred one is due: nothing pending.
        #expect(throttle.offer(Self.track, now: 11.1) == .send(Self.track))
        #expect(throttle.offer(third, now: 11.2) == .deferred(until: 11.6))
        #expect(throttle.offer(Self.track, now: 11.3) == .unchanged)
        #expect(throttle.due(now: 12) == nil)
    }

    @Test("The position advancing while playing is not a change; a seek is")
    func throttlePosition() {
        var throttle = NowPlayingThrottle(minInterval: 0.5, seekTolerance: 2)
        #expect(throttle.offer(Self.track, now: 100) == .send(Self.track))  // elapsed 12
        var later = Self.track
        later.elapsed = 22
        #expect(throttle.offer(later, now: 110) == .unchanged)
        later.elapsed = 60
        #expect(throttle.offer(later, now: 111) == .send(later))
        // Paused: the position must stay put.
        var paused = later
        paused.isPlaying = false
        #expect(throttle.offer(paused, now: 112) == .send(paused))
        paused.elapsed = 61
        #expect(throttle.offer(paused, now: 120) == .unchanged)
        paused.elapsed = 64
        #expect(throttle.offer(paused, now: 121) == .send(paused))
    }

    // MARK: - mediaremote-adapter stream

    @Test("Full and diff payloads merge; null removes a key; no title = nothing playing")
    func adapterStream() throws {
        var stream = MediaRemoteAdapterStream()
        #expect(try stream.consume(line: Data(#"{"type":"data","diff":false,"payload":{}}"#.utf8)) == nil)
        let full = #"""
            {"type":"data","diff":false,"payload":{"artist":"GLOBUZZ","title":"Episode 4",
            "elapsedTime":124.5,"bundleIdentifier":"com.google.Chrome","playing":true,
            "duration":1343.4,"playbackRate":1,"album":"","timestamp":"2026-11-01T10:02:12Z",
            "artworkData":"/9j/AA==","artworkMimeType":"image/jpeg"}}
            """#
        let snapshot = try #require(try stream.consume(line: Data(full.replacingOccurrences(of: "\n", with: "").utf8)))
        #expect(snapshot.title == "Episode 4")
        #expect(snapshot.artist == "GLOBUZZ")
        #expect(snapshot.album == nil)  // empty string = none
        #expect(snapshot.bundleIdentifier == "com.google.Chrome")
        #expect(snapshot.isPlaying)
        #expect(snapshot.duration == 1343.4)
        #expect(snapshot.artworkBase64 == "/9j/AA==")
        let stamp = try #require(snapshot.timestamp)
        #expect(snapshot.elapsed(at: stamp.addingTimeInterval(10)) == 134.5)

        let pause = #"{"type":"data","diff":true,"payload":{"playing":false,"artworkData":null}}"#
        let paused = try #require(try stream.consume(line: Data(pause.utf8)))
        #expect(!paused.isPlaying)
        #expect(paused.title == "Episode 4")
        #expect(paused.artworkBase64 == nil)
        #expect(paused.elapsed(at: stamp.addingTimeInterval(10)) == 124.5)  // not extrapolated

        let gone = #"{"type":"data","diff":true,"payload":{"title":null}}"#
        #expect(try stream.consume(line: Data(gone.utf8)) == nil)
        #expect(try stream.consume(line: Data(full.replacingOccurrences(of: "\n", with: "").utf8))?.title == "Episode 4")
        #expect(try stream.consume(line: Data(#"{"type":"data","diff":false,"payload":{}}"#.utf8)) == nil)
    }

    @Test("Lines that are not adapter data messages throw and leave the state alone")
    func adapterGarbage() throws {
        var stream = MediaRemoteAdapterStream()
        _ = try stream.consume(line: Data(#"{"type":"data","diff":false,"payload":{"title":"A","playing":1}}"#.utf8))
        for text in ["not json", #"{"type":"error"}"#, #"{"type":"data","payload":{}}"#] {
            #expect(throws: ControlProtocolError.malformed) {
                try stream.consume(line: Data(text.utf8))
            }
        }
        #expect(stream.snapshot?.title == "A")
        #expect(stream.snapshot?.isPlaying == true)  // numeric playing flag
    }
}
