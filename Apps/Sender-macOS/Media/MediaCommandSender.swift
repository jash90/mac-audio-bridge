import AppKit
import ApplicationServices
import BridgeCore
import os

/// How this Mac carries out a playback command from the phone.
enum MediaCommandMethod: Equatable, Sendable {
    /// `MRMediaRemoteSendCommand` (private MediaRemote.framework). Sending
    /// still works for unentitled apps on macOS 27 (only reading Now Playing
    /// was locked down in 15.4) and needs no permission.
    case mediaRemote
    /// Fallback: system media-key events (`NX_KEYTYPE_PLAY/NEXT/PREVIOUS`)
    /// posted with `CGEvent.post` — needs the Accessibility permission.
    case mediaKeys
    /// The fallback is needed but Accessibility is not granted.
    case needsAccessibility

    var canControl: Bool { self != .needsAccessibility }
}

/// Sends play / pause / next / previous to the Mac's Now Playing app.
@MainActor
enum MediaCommandSender {
    private static let logger = Logger(subsystem: "dev.jash90.MacAudioBridge", category: "media")
    /// A MediaRemote send that reported failure: use media keys from then on.
    private static var mediaRemoteFailed = false

    static var method: MediaCommandMethod {
        if MediaRemote.sendCommand != nil, !mediaRemoteFailed { return .mediaRemote }
        return AXIsProcessTrusted() ? .mediaKeys : .needsAccessibility
    }

    /// - Parameter isPlaying: the Mac's current play state, when known (a
    ///   media key only toggles, so an explicit play / pause that matches
    ///   the state is skipped).
    static func send(_ command: MediaCommand, isPlaying: Bool?) {
        if method == .mediaRemote, let sendCommand = MediaRemote.sendCommand {
            if sendCommand(command.mediaRemoteCommand, nil) { return }
            logger.error("MRMediaRemoteSendCommand failed; falling back to media keys")
            mediaRemoteFailed = true
        }
        guard AXIsProcessTrusted() else {
            logger.notice("Media keys need the Accessibility permission")
            return
        }
        switch command {
        case .play where isPlaying == true, .pause where isPlaying == false:
            return
        default:
            postMediaKey(command.mediaKey)
        }
    }

    /// Shows the system prompt (adds the app to the Accessibility list) and
    /// opens the pane.
    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// A key down + key up pair of a system-defined (subtype 8) aux key.
    private static func postMediaKey(_ key: Int32) {
        for (flags, state) in [(0xA00, 0xA), (0xB00, 0xB)] {
            let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                data1: Int((key << 16) | Int32(state << 8)), data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

/// `MRMediaRemoteSendCommand`, resolved once with dlopen/dlsym (the
/// framework is private; nil when the symbol is gone).
private enum MediaRemote {
    typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool

    static let sendCommand: SendCommand? = {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_LAZY), let symbol = dlsym(handle, "MRMediaRemoteSendCommand") else {
            return nil
        }
        return unsafeBitCast(symbol, to: SendCommand.self)
    }()
}

extension MediaCommand {
    /// MRCommand values (kMRPlay = 0 … kMRPreviousTrack = 5).
    fileprivate var mediaRemoteCommand: UInt32 {
        switch self {
        case .play: 0
        case .pause: 1
        case .togglePlayPause: 2
        case .nextTrack: 4
        case .previousTrack: 5
        }
    }

    /// NX_KEYTYPE_PLAY = 16, NX_KEYTYPE_NEXT = 17, NX_KEYTYPE_PREVIOUS = 18.
    fileprivate var mediaKey: Int32 {
        switch self {
        case .play, .pause, .togglePlayPause: 16
        case .nextTrack: 17
        case .previousTrack: 18
        }
    }
}
