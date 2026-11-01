import BridgeCore
import CoreAudio
import Foundation

/// Control from the iPhone and switching between several Macs (Mac side).
///
/// Each phone holds a control session (`ControlServer`) and introduces itself
/// with a hello naming its receiver service. The phone arbitrates (see
/// `SourceArbiter`); this side carries out its commands:
/// - `connect`: remember the current output, switch to ours, stream to that
///   phone's receiver (persisted as the menu's receiver pick);
/// - `disconnect` / `release(byName:)`: stop streaming to that phone and
///   restore the remembered output (fallback: built-in, any other output;
///   with none, keep the output and pause — `releasedHold`); a release also
///   shows "iPhone used by <Mac>" in the menu;
/// - volume / mute / quality: applied to the virtual device / stream and
///   kept in sync with the menu (both directions, via the status reports).
/// A Mac-side selection of our output (System Settings, the menu button) is
/// an explicit action too: once streaming to that phone has started it is
/// sent a `claim`, and the phone releases whichever Mac it used before.
extension SenderController {
    private static let claimLifetime: TimeInterval = 10
    private static let statusHeartbeat: TimeInterval = 2

    // MARK: - Events from the control server

    func handleControlEvent(_ event: ControlServer.Event) {
        switch event {
        case .status(let status):
            if controlServerStatus != status { controlServerStatus = status }
        case .registeredName(let name):
            advertisedName = name
            remoteStateChanged(force: true)
        case .opened(let id, let kind):
            sessions[id] = .some(nil)
            sessionKinds[id] = kind
        case .listeningPort(let port):
            if controlPort != port { controlPort = port }
        case .closed(let id):
            sessions[id] = nil
            sessionKinds[id] = nil
            lastSentStatus[id] = nil
            micSessionClosed(id)
            remoteStateChanged()
        case .message(let id, let message):
            handle(message, from: id)
        }
    }

    private func handle(_ message: ControlMessage, from id: ControlServer.SessionID) {
        if case .hello(let hello) = message {
            // A phone that reconnected: its old session is stale.
            for (other, existing) in sessions where other != id && existing?.phoneID == hello.phoneID {
                controlServer?.close(other)
                sessions[other] = nil
                sessionKinds[other] = nil
                lastSentStatus[other] = nil
            }
            sessions[id] = .some(hello)
            recordPhoneHello(hello)
            lastSentStatus[id] = nil
            sendPendingClaim()
            remoteStateChanged(force: true)
            if case .some(let info) = media.currentForNewPhone {
                controlServer?.send(.nowPlaying(info), to: id)
            }
            return
        }
        guard let session = sessions[id], let hello = session else { return }
        switch message {
        case .connect:
            phoneConnect(hello)
        case .disconnect:
            phoneRelease(hello, byName: nil)
        case .release(let name):
            phoneRelease(hello, byName: name)
        case .setVolume(let volume):
            if let deviceID = BridgeDevice.deviceID() {
                BridgeDevice.setVolumeScalar(deviceID, volume)
                updateVolume(deviceID: deviceID)
            }
            remoteStateChanged()
        case .setMuted(let muted):
            if let deviceID = BridgeDevice.deviceID() {
                BridgeDevice.setMuted(deviceID, muted)
                updateVolume(deviceID: deviceID)
            }
            remoteStateChanged()
        case .setQuality(let newQuality):
            setQuality(newQuality)
        case .setInternetQuality(let newQuality):
            setInternetQuality(newQuality)
        case .media(let command):
            media.perform(command)
        case .micState(let state):
            handleMicState(state, from: id)
        case .hello, .status, .claim, .nowPlaying, .micStart, .micStop:
            break  // phone → Mac only / Mac → phone only
        }
    }

    // MARK: - Commands

    /// "Use this Mac" from a phone.
    private func phoneConnect(_ hello: PhoneHello) {
        usedBy = nil
        releasedHold = false
        pendingClaimSince = nil
        selectReceiver(hello.receiverService)
        if let deviceID = BridgeDevice.deviceID(),
            let currentDefault = BridgeDevice.defaultOutputDeviceID(),
            currentDefault != deviceID
        {
            observeOutput(BridgeDevice.outputDeviceInfo(currentDefault))
            // Our own switch: the phone already knows, no claim back.
            suppressClaimUntil = Self.uptime() + 2
            if !BridgeDevice.setDefaultOutputDevice(deviceID) {
                failureMessage = "Could not switch the output to iPhone (Mac Audio Bridge)"
            }
        }
        evaluate()
    }

    /// "Disconnect" (byName nil) or a takeover by another Mac.
    private func phoneRelease(_ hello: PhoneHello, byName: String?) {
        let phoneTarget = ReceiverTarget.service(hello.receiverService)
        // A phone we are not streaming to cannot stop our stream elsewhere.
        guard activeTarget == phoneTarget || selection.target == phoneTarget || isStreaming(to: hello) else {
            remoteStateChanged(force: true)
            return
        }
        usedBy = byName
        pendingClaimSince = nil
        if defaultOutputIsOurs, !restorePreviousOutput() {
            releasedHold = true
        }
        evaluate()
    }

    /// Menu "Resume streaming" after a release left the output on ours.
    func resumeAfterRelease() {
        releasedHold = false
        usedBy = nil
        pendingClaimSince = Self.uptime()
        evaluate()
    }

    // MARK: - Takeover (Mac-initiated)

    func handleOutputTransition(_ transition: OutputRestoreModel.Transition) {
        switch transition {
        case .becameOurs:
            releasedHold = false
            usedBy = nil
            if Self.uptime() >= suppressClaimUntil {
                pendingClaimSince = Self.uptime()
            }
        case .leftOurs:
            releasedHold = false
            pendingClaimSince = nil
        case .none:
            break
        }
    }

    /// Sends the pending claim to the phone(s) whose receiver we now stream
    /// to; the claim precedes the status that reports streaming.
    private func sendPendingClaim() {
        guard let since = pendingClaimSince else { return }
        guard Self.uptime() - since <= Self.claimLifetime else {
            pendingClaimSince = nil
            return
        }
        guard mode == .streaming, case .service(let name)? = activeTarget else { return }
        let targets = sessions.compactMap { id, hello in
            hello?.receiverService == name ? id : nil
        }
        guard !targets.isEmpty else { return }
        for id in targets {
            controlServer?.send(.claim, to: id)
        }
        pendingClaimSince = nil
    }

    // MARK: - Now Playing

    /// Sends what plays on this Mac to every phone that said hello.
    func broadcastNowPlaying(_ info: NowPlayingInfo?) {
        for (id, hello) in sessions where hello != nil {
            controlServer?.send(.nowPlaying(info), to: id)
        }
    }

    // MARK: - Status reports

    /// Called after every evaluate pass and state change: sends the pending
    /// claim, then each phone's status when it changed (or every 2 s).
    func remoteStateChanged(force: Bool = false) {
        sendPendingClaim()
        let now = Self.uptime()
        var controlling: String?
        for (id, session) in sessions {
            guard let hello = session else { continue }
            let status = makeStatus(for: hello)
            if status.streamingToYou {
                controlling = hello.phoneName
            }
            if !force, let last = lastSentStatus[id], last.status == status,
                now - last.at < Self.statusHeartbeat
            {
                continue
            }
            controlServer?.send(.status(status), to: id)
            lastSentStatus[id] = (status, now)
        }
        if controllingPhone != controlling {
            controllingPhone = controlling
        }
    }

    private func makeStatus(for hello: PhoneHello) -> SourceStatus {
        let streamingToPhone = isStreaming(to: hello)
        let audioPlaying = mode == .streaming
            ? converter.audibility.audible(within: 1.5)
            : defaultOutputIsOurs && BridgeDevice.isRunningSomewhere()
        return SourceStatus(
            sourceID: SourceIdentity.id,
            name: advertisedName,
            sourceTag: SourceIdentity.tag,
            driverInstalled: driverInstalled,
            outputIsOurs: defaultOutputIsOurs,
            streamingToYou: streamingToPhone,
            streamingTo: mode == .streaming ? activeReceiver : nil,
            audioPlaying: audioPlaying,
            outputDeviceName: outputDeviceName,
            volume: (deviceVolume * 100).rounded() / 100,
            muted: deviceMuted,
            quality: quality,
            usedBy: usedBy,
            problem: problem(for: hello),
            tailnetAddresses: ownTailnetAddresses.isEmpty ? nil : ownTailnetAddresses,
            path: streamingToPhone ? streamPath : nil,
            profile: streamingToPhone ? streamProfile : nil,
            qualityNote: streamingToPhone ? qualityNote : nil,
            sessionBytes: streamingToPhone ? usageMeter.totalBytes : nil,
            megabytesPerHour: streamingToPhone ? (megabytesPerHour * 10).rounded() / 10 : nil,
            internetQuality: internetQuality)
    }

    private func problem(for hello: PhoneHello) -> String? {
        if !driverInstalled { return "Driver not installed on this Mac" }
        if captureWarning != nil {
            return "Allow System Audio Recording for Mac Audio Bridge on the Mac"
        }
        if let failureMessage { return failureMessage }
        if browserStatus == .localNetworkDenied { return "Local Network access is off on this Mac" }
        if defaultOutputIsOurs, !releasedHold, mode == .waiting,
            case .looking(let name) = selectionStatus, name == hello.receiverService
        {
            return "The Mac cannot see this iPhone's receiver yet"
        }
        return nil
    }

    // MARK: - Nonisolated factory

    /// Control server whose events hop to the main actor in FIFO order.
    nonisolated static func makeControlServer(
        controller: SenderController, serviceName: String
    ) -> ControlServer {
        ControlServer(serviceName: serviceName) { [weak controller] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { controller?.handleControlEvent(event) }
            }
        }
    }
}
