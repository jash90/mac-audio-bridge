import Foundation
import Testing
@testable import BridgeCore

struct PlaybackWatchdogTests {
    /// Drives the watchdog at 4 Hz with packets arriving at 100/s; `playing`
    /// decides whether 25 frames are played per tick, `rendering` whether
    /// the render callback runs. Returns the verdicts, one per tick.
    private func drive(
        _ watchdog: inout PlaybackWatchdog,
        from start: TimeInterval,
        ticks: Int,
        counters: inout (received: Int, played: Int, renders: Int),
        arriving: Bool = true,
        playing: Bool,
        rendering: Bool = false
    ) -> [PlaybackWatchdog.Verdict] {
        var verdicts: [PlaybackWatchdog.Verdict] = []
        for tick in 0..<ticks {
            if arriving { counters.received += 25 }
            if playing { counters.played += 25 }
            if rendering || playing { counters.renders += 50 }
            verdicts.append(
                watchdog.evaluate(
                    now: start + Double(tick) * 0.25,
                    received: counters.received,
                    played: counters.played,
                    renderCalls: counters.renders))
        }
        return verdicts
    }

    @Test("Steady playback is healthy")
    func steadyPlaybackIsHealthy() {
        var watchdog = PlaybackWatchdog()
        var counters = (received: 0, played: 0, renders: 0)
        let verdicts = drive(&watchdog, from: 0, ticks: 40, counters: &counters, playing: true)
        #expect(verdicts.allSatisfy { $0 == .healthy })
    }

    @Test("No arrivals and no playback is idle, never a restart")
    func idleIsHealthy() {
        var watchdog = PlaybackWatchdog()
        var counters = (received: 0, played: 0, renders: 0)
        let verdicts = drive(
            &watchdog, from: 0, ticks: 40, counters: &counters, arriving: false, playing: false)
        #expect(verdicts.allSatisfy { $0 == .healthy })
    }

    @Test("Arrivals with nothing played for 1 s trigger a restart; engine-stopped reason")
    func stalledEngineTriggersRestart() {
        var watchdog = PlaybackWatchdog()
        var counters = (received: 0, played: 0, renders: 0)
        _ = drive(&watchdog, from: 0, ticks: 4, counters: &counters, playing: true)
        // From t = 1.0 the engine stops: arrivals continue, no renders.
        let verdicts = drive(&watchdog, from: 1.0, ticks: 5, counters: &counters, playing: false)
        // Stall starts at 1.0; 1.25/1.5/1.75 are suspect; 2.0 is 1 s later.
        #expect(verdicts == [.suspect, .suspect, .suspect, .suspect, .restart(.renderStopped)])
    }

    @Test("Render calls without playable frames report nothingPlayable")
    func renderingButNothingPlayable() {
        var watchdog = PlaybackWatchdog()
        var counters = (received: 0, played: 0, renders: 0)
        _ = drive(&watchdog, from: 0, ticks: 1, counters: &counters, playing: false)
        let verdicts = drive(
            &watchdog, from: 0.25, ticks: 5, counters: &counters, playing: false, rendering: true)
        #expect(verdicts.last == .restart(.nothingPlayable))
    }

    @Test("Prebuffering shorter than the threshold is not a stall")
    func shortPrebufferIsNotAStall() {
        var watchdog = PlaybackWatchdog()
        var counters = (received: 0, played: 0, renders: 0)
        _ = drive(&watchdog, from: 0, ticks: 1, counters: &counters, playing: false)
        // 500 ms of prebuffering, then playback.
        let prebuffer = drive(&watchdog, from: 0.25, ticks: 2, counters: &counters, playing: false)
        let playing = drive(&watchdog, from: 0.75, ticks: 20, counters: &counters, playing: true)
        #expect(!prebuffer.contains { if case .restart = $0 { true } else { false } })
        #expect(playing.allSatisfy { $0 == .healthy })
    }

    @Test("A gap in arrivals ends the stall clock")
    func arrivalGapResetsStall() {
        var watchdog = PlaybackWatchdog()
        var counters = (received: 0, played: 0, renders: 0)
        _ = drive(&watchdog, from: 0, ticks: 1, counters: &counters, playing: false)
        _ = drive(&watchdog, from: 0.25, ticks: 3, counters: &counters, playing: false)
        // One evaluation with no arrivals: idle again.
        let idle = drive(
            &watchdog, from: 1.0, ticks: 1, counters: &counters, arriving: false, playing: false)
        #expect(idle == [.healthy])
        // Arrivals resume: the 1 s threshold counts from scratch.
        let resumed = drive(&watchdog, from: 1.25, ticks: 4, counters: &counters, playing: false)
        #expect(resumed == [.suspect, .suspect, .suspect, .suspect])
    }

    @Test("Failed restarts back off exponentially and reset once playback resumes")
    func restartsBackOff() {
        var watchdog = PlaybackWatchdog()
        var counters = (received: 0, played: 0, renders: 0)
        _ = drive(&watchdog, from: 0, ticks: 1, counters: &counters, playing: false)

        var restartTimes: [Double] = []
        for tick in 1...80 {  // 20 s of stall
            let now = Double(tick) * 0.25
            counters.received += 25
            let verdict = watchdog.evaluate(
                now: now, received: counters.received, played: counters.played,
                renderCalls: counters.renders)
            if case .restart = verdict {
                restartTimes.append(now)
                watchdog.recordRestart(now: now)
            }
        }
        // First restart after 1 s of stall, then spaced by max(stall, backoff):
        // 1 s backoff → next at +1.25 (new stall clock), 2 s, 4 s, 8 s.
        #expect(restartTimes.first == 1.25)
        let gaps = zip(restartTimes.dropFirst(), restartTimes).map { $0 - $1 }
        #expect(gaps.count >= 3)
        for (earlier, later) in zip(gaps, gaps.dropFirst()) {
            #expect(later >= earlier)
        }
        #expect(gaps.last! >= 4)
        #expect(watchdog.consecutiveRestarts == restartTimes.count)

        // Playback resumes: the backoff resets.
        counters.played += 25
        counters.received += 25
        #expect(
            watchdog.evaluate(
                now: 20.25, received: counters.received, played: counters.played,
                renderCalls: counters.renders) == .healthy)
        #expect(watchdog.consecutiveRestarts == 0)
    }

    @Test("Counters that go backwards re-baseline instead of tripping")
    func countersResetRebaseline() {
        var watchdog = PlaybackWatchdog()
        #expect(watchdog.evaluate(now: 0, received: 500, played: 400, renderCalls: 900) == .healthy)
        #expect(watchdog.evaluate(now: 0.25, received: 10, played: 0, renderCalls: 0) == .healthy)
        #expect(watchdog.evaluate(now: 0.5, received: 35, played: 0, renderCalls: 0) == .suspect)
    }
}
