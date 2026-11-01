import BridgeCore
import Foundation
import MediaPlayer
import UIKit

/// Now Playing / lock screen for the active Mac. With the Mac's playback
/// info (protocol v2) it shows the Mac's track (title, artist, artwork,
/// position) with the Mac's name, `playbackRate` follows the Mac's play
/// state, and the remote commands (lock screen, Control Center, AirPods)
/// control the Mac's player — routed by `MediaControlRouter`. Without it
/// it shows the Mac's name and play / pause unmute / mute that Mac.
@MainActor
final class NowPlayingPublisher {
    /// What the active Mac's Now Playing entry shows.
    struct Content: Equatable {
        /// nil = no Mac active.
        var sourceName: String?
        var muted: Bool
        /// The Mac's track, when it reports one.
        var track: NowPlayingInfo?
        /// next / previous are offered (the Mac takes commands).
        var canControl: Bool
    }

    private var lastContent: Content?
    private var started = false

    /// Registers the remote commands once. `onCommand` hops to the main actor
    /// itself (the command center calls handlers on the main thread, but the
    /// closure is built nonisolated so no executor check can trip).
    func start(onCommand: @escaping @Sendable (MediaCommand) -> Void) {
        guard !started else { return }
        started = true
        Self.registerCommands(onCommand: onCommand)
    }

    func update(_ content: Content) {
        if content == lastContent { return }
        let commands = MPRemoteCommandCenter.shared()
        if lastContent?.canControl != content.canControl {
            commands.nextTrackCommand.isEnabled = content.canControl
            commands.previousTrackCommand.isEnabled = content.canControl
        }
        lastContent = content
        MPNowPlayingInfoCenter.default().nowPlayingInfo = Self.makeInfo(content)
    }

    private static func makeInfo(_ content: Content) -> [String: Any] {
        guard let name = content.sourceName else {
            return [
                MPMediaItemPropertyTitle: "Not connected",
                MPMediaItemPropertyArtist: "Mac Audio Bridge",
                MPNowPlayingInfoPropertyIsLiveStream: true,
                MPNowPlayingInfoPropertyPlaybackRate: 0.0,
            ]
        }
        guard let track = content.track else {
            return [
                MPMediaItemPropertyTitle: name,
                MPMediaItemPropertyArtist: "Mac Audio Bridge",
                MPNowPlayingInfoPropertyIsLiveStream: true,
                MPNowPlayingInfoPropertyPlaybackRate: content.muted ? 0.0 : 1.0,
            ]
        }
        // "Artist · Mac" so the lock screen names the Mac as well.
        let artist = [track.artist, name].compactMap { $0 }.joined(separator: " · ")
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: artist,
            MPNowPlayingInfoPropertyPlaybackRate: track.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyIsLiveStream: track.duration == nil,
        ]
        if let album = track.album ?? track.app {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        if let duration = track.duration {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let elapsed = track.elapsed {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        }
        if let data = track.artwork, let image = UIImage(data: data) {
            info[MPMediaItemPropertyArtwork] = makeArtwork(image)
        }
        return info
    }

    nonisolated private static func registerCommands(onCommand: @escaping @Sendable (MediaCommand) -> Void) {
        let center = MPRemoteCommandCenter.shared()
        let commands: [(MPRemoteCommand, MediaCommand)] = [
            (center.togglePlayPauseCommand, .togglePlayPause),
            (center.playCommand, .play),
            (center.pauseCommand, .pause),
            (center.nextTrackCommand, .nextTrack),
            (center.previousTrackCommand, .previousTrack),
        ]
        for (remote, command) in commands {
            remote.addTarget(handler: makeHandler(command, onCommand))
        }
        center.togglePlayPauseCommand.isEnabled = true
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        // Offered only while the active Mac takes commands (see `update`).
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    nonisolated private static func makeHandler(
        _ command: MediaCommand, _ onCommand: @escaping @Sendable (MediaCommand) -> Void
    ) -> @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { _ in
            onCommand(command)
            return .success
        }
    }

    /// The request handler runs on a MediaPlayer queue: built nonisolated.
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
