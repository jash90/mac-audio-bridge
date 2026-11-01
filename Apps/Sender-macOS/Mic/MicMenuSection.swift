import SwiftUI

/// "Mic: in use by a call / iPhone sending / off" and a level meter of what
/// the call hears (refreshed 10 × per second while the menu is open).
struct MicMenuSection: View {
    @ObservedObject var controller: SenderController

    var body: some View {
        let status = controller.micStatus
        if status != .off {
            HStack(spacing: 8) {
                Image(systemName: symbol(status))
                    .foregroundStyle(color(status))
                Text(status.text)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if case .live = status {
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    MicLevelBar(level: controller.micLevel)
                }
            }
        } else {
            Label(status.text, systemImage: "mic.slash")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func symbol(_ status: MicMenuStatus) -> String {
        switch status {
        case .live(_, let muted): muted ? "mic.slash.fill" : "mic.fill"
        case .inUse: "mic.badge.xmark"
        case .driverMissing: "exclamationmark.triangle"
        case .off: "mic.slash"
        }
    }

    private func color(_ status: MicMenuStatus) -> Color {
        switch status {
        case .live(_, let muted): muted ? .orange : .green
        case .inUse: .orange
        case .driverMissing: .red
        case .off: .secondary
        }
    }
}

/// Horizontal meter: RMS mapped to dBFS (−60…0 dB).
private struct MicLevelBar: View {
    let level: Float

    var body: some View {
        let db = level > 0 ? 20 * log10(Double(level)) : -60
        let fraction = min(max((db + 60) / 60, 0), 1)
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.green).frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 5)
        .accessibilityLabel("Mic level")
        .accessibilityValue("\(Int(db.rounded())) dB")
    }
}
