import BridgeCore
import CoreAudio
import Foundation
import os

private let micLogger = Logger(subsystem: "dev.jash90.MacAudioBridge", category: "mic")

/// What the menu says about the phone microphone.
enum MicMenuStatus: Equatable {
    /// The installed driver has no "iPhone Mic" device yet.
    case driverMissing
    /// No app has the mic open.
    case off
    /// An app (a call) has the mic open; the phone is not sending (why).
    case inUse(waitingFor: String)
    /// Mic audio arrives from the phone.
    case live(phone: String, muted: Bool)

    var text: String {
        switch self {
        case .driverMissing: "Mic: needs the updated driver (./scripts/install-driver.sh)"
        case .off: "Mic: off"
        case .inUse(let reason): "Mic: in use by a call — \(reason)"
        case .live(let phone, let muted): muted ? "Mic: \(phone) is muted" : "Mic: \(phone) sending"
        }
    }
}

/// "Talk through iPhone" (Mac side).
///
/// The driver publishes "iPhone Mic (Mac Audio Bridge)". When an app opens
/// it (`DeviceIsRunningSomewhere` 0 → 1) the feeder starts and the phone we
/// stream to is sent `micStart` — if it reported an armed mic (`micState`,
/// protocol version 4; older phones never get mic messages). When the app
/// closes it, `micStop` follows after a 2 s grace (`MicDemand`). Mic
/// datagrams arrive on the stream's UDP flow (`UDPSender` → `MicEngine`) and
/// the feeder plays them into the hidden feed device.
extension SenderController {
    static let micUID = "dev.jash90.MacAudioBridge.Mic"
    /// "iPhone sending" = a mic datagram within this window.
    private static let micLiveWindow: TimeInterval = 1.0

    /// Called from every `evaluate` pass (≈ 1 Hz and on device events).
    func refreshMic() {
        let micID = BridgeDevice.deviceID(uid: Self.micUID)
        if micID != micObservedDeviceID {
            micObservedDeviceID = micID
            micEvents.removeAllRegistrations()
            if let micID {
                _ = micEvents.add(
                    objectID: micID, selector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                    scope: kAudioObjectPropertyScopeGlobal, onEvent: Self.makeMicEventHandler(controller: self))
            }
        }
        let inUse = micID != nil && BridgeDevice.isRunningSomewhere(uid: Self.micUID)
        let now = Self.uptime()
        if let action = micDemand.update(inUse: inUse, now: now) {
            perform(action)
        }
        if micDemand.active {
            requestMicFromStreamingPhone()
        }
        publishMicStatus(driverHasMic: micID != nil)
    }

    /// The menu's level meter (decaying RMS of what the call hears).
    var micLevel: Float {
        micFeeder?.isRunning == true ? micEngine.reader.outputLevel : 0
    }

    private func perform(_ action: MicDemand.Action) {
        switch action {
        case .start:
            micLogger.notice("An app opened iPhone Mic: starting the feeder")
            micEngine.begin()
            if micFeeder == nil { micFeeder = MicFeeder(engine: micEngine) }
            micFeeder?.start()
            requestMicFromStreamingPhone()
        case .stop:
            micLogger.notice(
                "iPhone Mic closed (grace over): stopping; \(self.micEngine.datagramCount) mic datagrams this launch")
            if let id = micRequestedSession {
                controlServer?.send(.micStop, to: id)
            }
            micRequestedSession = nil
            micEngine.end()
            micFeeder?.stop()
        }
    }

    /// Sends `micStart` to the phone we stream to when its mic is armed
    /// (and `micStop` to a phone asked before, after a switch).
    private func requestMicFromStreamingPhone() {
        let target = sessions.first { id, hello in
            guard let hello, micStates[id]?.armed == true else { return false }
            return isStreaming(to: hello)
        }?.key
        guard target != micRequestedSession else { return }
        if let previous = micRequestedSession {
            controlServer?.send(.micStop, to: previous)
        }
        micRequestedSession = target
        if let target {
            controlServer?.send(.micStart, to: target)
            let name = (sessions[target] ?? nil)?.phoneName ?? "?"
            micLogger.notice("micStart → \(name, privacy: .public)")
        }
    }

    /// A phone reported its mic (protocol version 4).
    func handleMicState(_ state: MicState, from id: ControlServer.SessionID) {
        micStates[id] = state
        if !state.armed, micRequestedSession == id {
            micRequestedSession = nil
        }
        if micDemand.active {
            requestMicFromStreamingPhone()
            // A phone that re-armed (app relaunch) needs the request again.
            if state.armed, !state.sending, micRequestedSession == id {
                controlServer?.send(.micStart, to: id)
            }
        }
        publishMicStatus(driverHasMic: micObservedDeviceID != nil)
    }

    func micSessionClosed(_ id: ControlServer.SessionID) {
        micStates[id] = nil
        if micRequestedSession == id {
            micRequestedSession = nil
        }
    }

    private func publishMicStatus(driverHasMic: Bool) {
        let status: MicMenuStatus
        if !driverHasMic {
            status = .driverMissing
        } else if !micDemand.active {
            status = .off
        } else if let id = micRequestedSession, let hello = sessions[id] ?? nil,
            let age = micEngine.secondsSinceLastPacket, age < Self.micLiveWindow
        {
            status = .live(phone: hello.phoneName, muted: micEngine.phoneMuted)
        } else if let id = micRequestedSession, let problem = micStates[id]?.problem {
            status = .inUse(waitingFor: problem)
        } else if micRequestedSession != nil {
            status = .inUse(waitingFor: "waiting for the iPhone")
        } else if mode != .streaming {
            status = .inUse(waitingFor: "stream to an iPhone to use its mic")
        } else {
            status = .inUse(waitingFor: "turn on Talk through iPhone on the phone")
        }
        if micStatus != status { micStatus = status }
    }

    /// CoreAudio listener (listener queue) → main actor.
    nonisolated private static func makeMicEventHandler(controller: SenderController) -> @Sendable () -> Void {
        { [weak controller] in
            Task { @MainActor in controller?.refreshMic() }
        }
    }
}
