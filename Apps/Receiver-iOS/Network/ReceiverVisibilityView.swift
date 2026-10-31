import SwiftUI
import UIKit

/// The receiver's "how the Mac finds me" block: the Bonjour name the Mac
/// lists, a Local Network explanation when iOS blocks the advertisement, and
/// the Wi-Fi address small below for debugging / the manual fallback.
struct ReceiverVisibilityView: View {
    let ipAddress: String?
    let isListening: Bool
    @ObservedObject private var advertisement = ReceiverAdvertisement.shared

    var body: some View {
        VStack(spacing: 4) {
            if !isListening {
                Text("Listener stopped")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                switch advertisement.status {
                case .advertising:
                    Text("Visible to your Mac as")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(advertisement.registeredName ?? "…")
                        .font(.title3.bold())
                        .textSelection(.enabled)
                case .starting:
                    Text("Starting…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .localNetworkDenied:
                    localNetworkHelp
                case .failed(let message):
                    Text("Not visible to your Mac: \(message)")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            Text(debugLine)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var localNetworkHelp: some View {
        VStack(spacing: 6) {
            Text("Local Network access needed")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("Your Mac finds this iPhone over the local network. Tap Allow in the prompt, or turn on Mac Audio Bridge in Settings → Privacy & Security → Local Network.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.footnote)
        }
    }

    private var debugLine: String {
        let address = ipAddress ?? "no Wi-Fi address"
        let port = advertisement.port.map(String.init) ?? "—"
        return "\(address) · UDP \(port)"
    }
}
