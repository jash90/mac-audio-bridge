import BridgeCore
import SwiftUI

/// Menu lines for playback control from the phone: what plays on this Mac,
/// and the permission the command method needs when it lacks it.
struct MediaMenuSection: View {
    @ObservedObject var media: MacMediaControl

    var body: some View {
        if let info = media.nowPlaying {
            Label {
                Text(line(info))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: info.isPlaying ? "play.fill" : "pause.fill")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        if media.method == .needsAccessibility {
            HStack(spacing: 6) {
                Text("Playback control: needs Accessibility")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                Button("Open Settings") {
                    media.requestAccessibility()
                }
                .controlSize(.small)
            }
        }
        if let problem = media.infoProblem {
            Text(problem)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Title — Artist (App)".
    private func line(_ info: NowPlayingInfo) -> String {
        var text = info.title
        if let artist = info.artist { text += " — \(artist)" }
        if let app = info.app { text += " (\(app))" }
        return text
    }
}
