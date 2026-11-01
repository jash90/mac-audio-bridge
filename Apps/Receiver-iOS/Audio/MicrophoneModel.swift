import AVFoundation
import BridgeCore
import Foundation
import os
import UIKit

/// "Talk through iPhone": the phone's microphone as the Mac's
/// "iPhone Mic (Mac Audio Bridge)".
///
/// - Arming (the toggle, foreground only — iOS does not let an app start
///   recording from the background): asks for microphone permission, then
///   the playback controller rebuilds the engine with the input
///   (`.playAndRecord` + A2DP, the built-in mic). Capture then keeps
///   running in the background and on the lock screen.
/// - Sending: only after the Mac asks (`micStart`, when a call opens its
///   mic) and only to that Mac's stream flow; `micStop` or a lost control
///   connection ends it. The state goes to the Macs as `micState`.
/// - Mute: frames carry silence (the Mac's stream stays steady).
@MainActor
final class MicrophoneModel: ObservableObject {
    enum Phase: Equatable {
        case off
        case arming
        /// Capture runs; no Mac asked for the mic yet.
        case armed
        /// Sending to the Mac that asked.
        case live(macName: String)
        case unavailable(String)
    }

    @Published private(set) var phase: Phase = .off
    @Published private(set) var level: Float = 0
    @Published private(set) var echoCancellation = false
    @Published var muted = false {
        didSet {
            sender.muted = muted
            publishState()
        }
    }

    /// The user's choice, persisted (re-armed at the next foreground launch).
    static let armedKey = "phoneMicrophoneEnabled"

    private let playback: PlaybackController
    private let sources: SourcesModel
    private let receiver: UDPReceiver
    private let sender: MicSender
    private let logger = Logger(subsystem: "dev.jash90.MacAudioBridge", category: "mic")
    private var meterLoop: Task<Void, Never>?
    /// The Mac that asked for the mic, and its source tag.
    private var requestedBy: (id: String, tag: UInt32)?
    private var problem: String?

    init(playback: PlaybackController, sources: SourcesModel, receiver: UDPReceiver) {
        self.playback = playback
        self.sources = sources
        self.receiver = receiver
        sender = MicSender(
            ring: playback.captureContext.ring,
            profile: Self.makeProfileProvider(receiver: receiver),
            send: Self.makeSend(receiver: receiver))
        sources.onMicCommand = { [weak self] id, start, tag in
            self?.macCommand(id: id, start: start, tag: tag)
        }
        playback.onCaptureSuspended = { [weak self] in
            self?.captureSuspended()
        }
    }

    var isArmed: Bool {
        switch phase {
        case .armed, .live: true
        default: false
        }
    }

    /// Re-arms at launch when the user left it on (the app is in the
    /// foreground then).
    func restoreAtLaunch() {
        guard UserDefaults.standard.bool(forKey: Self.armedKey),
            UIApplication.shared.applicationState != .background
        else { return }
        Task { await setArmed(true) }
    }

    /// The app came to the foreground: a capture dropped in the background
    /// starts again.
    func appBecameActive() {
        guard UserDefaults.standard.bool(forKey: Self.armedKey) else { return }
        if case .unavailable = phase, problem == Self.foregroundProblem {
            Task { await setArmed(true) }
        }
    }

    /// The toggle.
    func setArmed(_ on: Bool) async {
        UserDefaults.standard.set(on, forKey: Self.armedKey)
        if !on {
            stopSending()
            sender.stop()
            meterLoop?.cancel()
            meterLoop = nil
            phase = .off
            problem = nil
            level = 0
            await playback.setCaptureEnabled(false, reason: "mic off")
            publishState()
            return
        }
        guard !isArmed, phase != .arming else { return }
        phase = .arming
        guard await Self.requestPermission() else {
            fail("Microphone access is off — allow it in Settings › Mac Audio Bridge")
            return
        }
        guard UIApplication.shared.applicationState != .background else {
            fail(Self.foregroundProblem)
            return
        }
        let running = await playback.setCaptureEnabled(true, reason: "mic armed")
        guard running else {
            fail("The microphone could not start")
            return
        }
        problem = nil
        echoCancellation = playback.voiceProcessingActive
        sender.start()
        phase = .armed
        startMeterLoop()
        if let requestedBy {
            beginSending(id: requestedBy.id, tag: requestedBy.tag)
        }
        publishState()
        logger.notice("mic armed (echo cancellation \(self.echoCancellation))")
    }

    // MARK: - Mac requests

    private func macCommand(id: String, start: Bool, tag: UInt32) {
        if start {
            requestedBy = (id, tag)
            if isArmed {
                beginSending(id: id, tag: tag)
            }
            publishState()
        } else if requestedBy?.id == id {
            requestedBy = nil
            stopSending()
            publishState()
        }
    }

    private func beginSending(id: String, tag: UInt32) {
        sender.setSending(to: tag)
        let name = sources.sources.first { $0.id == id }?.name ?? "Mac"
        phase = .live(macName: name)
        logger.notice("mic: sending to \(name, privacy: .public)")
    }

    private func stopSending() {
        sender.setSending(to: nil)
        if case .live = phase {
            phase = .armed
        }
    }

    private func captureSuspended() {
        stopSending()
        sender.stop()
        meterLoop?.cancel()
        meterLoop = nil
        fail(Self.foregroundProblem)
    }

    private static let foregroundProblem = "Open the app to restart the microphone"

    private func fail(_ message: String) {
        problem = message
        phase = .unavailable(message)
        publishState()
        logger.error("mic unavailable: \(message, privacy: .public)")
    }

    // MARK: - State

    private func publishState() {
        sources.setMicState(
            MicState(armed: isArmed, sending: sender.isSending, muted: muted, problem: problem))
    }

    /// 10 Hz: the meter, echo-cancellation follow-up after route changes.
    private func startMeterLoop() {
        meterLoop?.cancel()
        meterLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.level = self.sender.inputLevel
                let echo = self.playback.voiceProcessingActive
                if self.echoCancellation != echo { self.echoCancellation = echo }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private static func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }

    // MARK: - Nonisolated factories (the send queue calls these)

    nonisolated private static func makeSend(receiver: UDPReceiver) -> MicSender.Send {
        { datagrams, tag in receiver.sendMic(datagrams, toSource: tag) }
    }

    nonisolated private static func makeProfileProvider(receiver: UDPReceiver) -> MicSender.ProfileProvider {
        { receiver.profile }
    }
}
