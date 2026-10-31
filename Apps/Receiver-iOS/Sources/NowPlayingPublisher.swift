import Foundation
import MediaPlayer

/// Shows the active Mac's name in Now Playing / on the lock screen. The
/// play/pause buttons there unmute / mute that Mac (sending real media keys
/// to the Mac would need the Accessibility permission there).
@MainActor
final class NowPlayingPublisher {
    /// What a lock-screen button asks for: play = unmute, pause = mute,
    /// toggle = flip.
    enum Command: Sendable {
        case play
        case pause
        case toggle
    }

    private var lastInfo: (title: String, playing: Bool)?
    private var started = false

    /// Registers the remote commands once. `onCommand` hops to the main actor
    /// itself (the command center calls handlers on the main thread, but the
    /// closure is built nonisolated so no executor check can trip).
    func start(onCommand: @escaping @Sendable (Command) -> Void) {
        guard !started else { return }
        started = true
        Self.registerCommands(onCommand: onCommand)
    }

    /// `sourceName` nil = no Mac active; `muted` shows as paused.
    func update(sourceName: String?, muted: Bool) {
        let title = sourceName ?? "Not connected"
        let playing = sourceName != nil && !muted
        if let lastInfo, lastInfo.title == title, lastInfo.playing == playing { return }
        lastInfo = (title, playing)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "Mac Audio Bridge",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
        ]
    }

    nonisolated private static func registerCommands(onCommand: @escaping @Sendable (Command) -> Void) {
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget(handler: makeHandler(.toggle, onCommand))
        center.playCommand.isEnabled = true
        center.playCommand.addTarget(handler: makeHandler(.play, onCommand))
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget(handler: makeHandler(.pause, onCommand))
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    nonisolated private static func makeHandler(
        _ command: Command, _ onCommand: @escaping @Sendable (Command) -> Void
    ) -> @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { _ in
            onCommand(command)
            return .success
        }
    }
}
