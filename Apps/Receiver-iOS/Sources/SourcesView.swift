import BridgeCore
import SwiftUI

/// "Sources": every Mac running Mac Audio Bridge on this network, with live
/// status. Tap a row to use that Mac; the active row has Disconnect, volume,
/// mute and quality. Macs elsewhere (over Tailscale) are added by address
/// and then listed like the ones found on Wi-Fi.
struct SourcesView: View {
    @ObservedObject var model: SourcesModel
    @State private var addressText = ""
    @State private var showsAddAddress = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sources")
                    .font(.headline)
                Spacer()
                if model.browserStatus == .localNetworkDenied {
                    Text("Local Network access needed")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if model.sources.isEmpty {
                Text("Looking for Macs running Mac Audio Bridge on this Wi-Fi… (elsewhere: add the Mac by its Tailscale address below)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(model.sources) { source in
                SourceRow(
                    model: model, source: source, isActive: source.id == model.activeID,
                    isLastUsed: source.id == model.lastUsedID,
                    isIncompatible: model.incompatibleIDs.contains(source.id),
                    remoteAddress: model.remoteAddresses[source.id])
            }

            if model.activeID == nil, let last = model.lastUsed, last.connected {
                Button {
                    model.reconnectLast()
                } label: {
                    Label("Reconnect to \(last.name)", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            }

            manualHosts
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Add Mac by address" plus the added addresses (removable).
    @ViewBuilder
    private var manualHosts: some View {
        ForEach(model.manualHosts, id: \.self) { host in
            HStack {
                Image(systemName: "network")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.manualHostNames[host].map { "\($0) · \(host)" } ?? host)
                        .font(.footnote)
                    if model.unreachableHosts.contains(host) {
                        Text("Not reachable — is Tailscale on and the Mac awake?")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                Button(role: .destructive) {
                    model.removeManualHost(host)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(host)")
            }
        }
        if showsAddAddress {
            HStack {
                TextField("Mac IP or Tailscale name", text: $addressText)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onSubmit(addAddress)
                Button("Add", action: addAddress)
                    .disabled(addressText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } else {
            Button {
                showsAddAddress = true
            } label: {
                Label("Add Mac by address", systemImage: "plus")
                    .font(.footnote)
            }
            .buttonStyle(.borderless)
        }
    }

    private func addAddress() {
        let host = addressText.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        model.addManualHost(host)
        addressText = ""
        showsAddAddress = false
    }
}

private struct SourceRow: View {
    @ObservedObject var model: SourcesModel
    let source: SourceArbiter.Source
    let isActive: Bool
    let isLastUsed: Bool
    let isIncompatible: Bool
    /// The tailnet / typed address the control connection uses (nil: LAN).
    let remoteAddress: String?

    @State private var volume: Float = 1
    @State private var editingVolume = false

    private var status: SourceStatus? { source.status }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                if !isActive { model.connect(source.id) }
            } label: {
                HStack(spacing: 12) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.name)
                            .font(.body.weight(isActive ? .semibold : .regular))
                            .foregroundStyle(.primary)
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(detailIsWarning ? .orange : .secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    if status?.audioPlaying == true {
                        Image(systemName: "waveform")
                            .foregroundStyle(.tint)
                            .accessibilityLabel("Audio playing")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!source.isOnline || isIncompatible || !source.connected)

            if isActive, let status {
                activeControls(status)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isActive ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08)))
        .onAppear { volume = status?.volume ?? 1 }
        .onChange(of: status?.volume) { _, newValue in
            if !editingVolume, let newValue { volume = newValue }
        }
    }

    @ViewBuilder
    private func activeControls(_ status: SourceStatus) -> some View {
        HStack(spacing: 12) {
            Button {
                model.setMuted(!status.muted, for: source.id)
            } label: {
                Image(systemName: status.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 28)
            }
            .accessibilityLabel(status.muted ? "Unmute" : "Mute")
            Slider(value: $volume, in: 0...1) { editing in
                editingVolume = editing
                if !editing { model.setVolume(volume, for: source.id) }
            }
            .onChange(of: volume) { _, newValue in
                if editingVolume { model.setVolume(newValue, for: source.id) }
            }
            Text("\(Int((volume * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .frame(width: 40, alignment: .trailing)
        }
        Picker("Quality", selection: qualityBinding(status)) {
            ForEach(StreamQuality.allCases, id: \.self) { quality in
                Text(quality.shortName).tag(quality)
            }
        }
        .pickerStyle(.segmented)
        if let note = status.qualityNote {
            Text(note)
                .font(.caption)
                .foregroundStyle(.orange)
        }
        Button(role: .destructive) {
            model.disconnect(source.id)
        } label: {
            Label("Disconnect", systemImage: "xmark.circle")
        }
        .buttonStyle(.bordered)
    }

    private func qualityBinding(_ status: SourceStatus) -> Binding<StreamQuality> {
        Binding(
            get: { status.quality },
            set: { model.setQuality($0, for: source.id) })
    }

    private var dotColor: Color {
        if !source.isOnline { return .red }
        if isActive { return source.isStreamingToUs ? .green : .yellow }
        return source.connected ? .gray : .gray.opacity(0.4)
    }

    private var detailIsWarning: Bool {
        isIncompatible || status?.problem != nil
    }

    private var detail: String {
        if !source.isOnline { return isLastUsed ? "Offline — last used" : "Offline" }
        if isIncompatible { return "Update Mac Audio Bridge (different version)" }
        guard source.connected, let status else { return "Connecting…" }
        if let problem = status.problem { return problem }
        if status.streamingToYou {
            let quality = (status.profile ?? .lan).effectiveQuality(status.quality).shortName
            if let path = status.path, path != .local {
                return "Playing on this iPhone · \(quality) · \(path.displayName)"
            }
            return "Playing on this iPhone · \(quality)"
        }
        if isActive { return "Starting…" }
        if let other = status.streamingTo { return "Streaming to \(other)" }
        if let usedBy = status.usedBy { return "Switched to \(usedBy)" }
        let via = remoteAddress == nil ? "" : " · via Tailscale"
        return "Output: \(status.outputDeviceName ?? "unknown")\(via)"
    }
}

extension StreamQuality {
    /// Segment label.
    var shortName: String {
        switch self {
        case .opus192: "Opus 192"
        case .opus128: "Opus 128"
        case .pcm: "PCM"
        }
    }
}
