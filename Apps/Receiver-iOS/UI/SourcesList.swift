import BridgeCore
import SwiftUI

/// The Sources tab: every Mac with live status (tap to play from it), the
/// active Mac's volume, mute, quality and Disconnect, and Macs elsewhere
/// added by address (Tailscale).
struct SourcesList: View {
    @ObservedObject var sources: SourcesModel
    @State private var addressText = ""
    @State private var showsAddAddress = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        List {
            if sources.browserStatus == .localNetworkDenied {
                Section {
                    Label("Allow Local Network access in Settings to find Macs on this Wi‑Fi.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.subheadline)
                }
            }

            Section {
                ForEach(sources.sources) { source in
                    SourceRow(sources: sources, source: source)
                }
                if sources.activeID == nil, let last = sources.lastUsed, last.connected {
                    Button {
                        sources.reconnectLast()
                    } label: {
                        Label("Reconnect to \(last.name)", systemImage: "arrow.clockwise")
                    }
                }
            } header: {
                Text("Macs")
            } footer: {
                Label(
                    sources.sources.isEmpty
                        ? "Looking for Macs running Mac Audio Bridge on this Wi‑Fi and your tailnet…"
                        : "Macs elsewhere are reached over Tailscale.",
                    systemImage: "dot.radiowaves.left.and.right")
                    .font(.footnote)
            }

            if let active = sources.active, let status = active.status {
                Section {
                    MacVolumeRow(sources: sources, sourceID: active.id, status: status)
                    QualityPicker(sources: sources, sourceID: active.id, status: status)
                    if let note = status.qualityNote {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    Button(role: .destructive) {
                        sources.disconnect(active.id)
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                    }
                } header: {
                    Text("\(active.name) output")
                }
            }

            Section {
                ForEach(sources.manualHosts, id: \.self) { host in
                    manualHostRow(host)
                }
                .onDelete { offsets in
                    offsets.map { sources.manualHosts[$0] }.forEach(sources.removeManualHost)
                }
                if showsAddAddress {
                    HStack {
                        TextField("Mac IP or Tailscale name", text: $addressText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .focused($addressFocused)
                            .onSubmit(addAddress)
                        Button("Add", action: addAddress)
                            .disabled(addressText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } else {
                    Button {
                        showsAddAddress = true
                        addressFocused = true
                    } label: {
                        Label("Add a Mac by address", systemImage: "plus.circle")
                    }
                }
            } header: {
                if !sources.manualHosts.isEmpty { Text("Added by address") }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func manualHostRow(_ host: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "network")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(sources.manualHostNames[host].map { "\($0) · \(host)" } ?? host)
                    .font(.subheadline)
                if sources.unreachableHosts.contains(host) {
                    Text("Not reachable — is Tailscale on and the Mac awake?")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button(role: .destructive) {
                sources.removeManualHost(host)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(host)")
        }
    }

    private func addAddress() {
        let host = addressText.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        sources.addManualHost(host)
        addressText = ""
        showsAddAddress = false
    }
}

private struct SourceRow: View {
    @ObservedObject var sources: SourcesModel
    let source: SourceArbiter.Source

    private var isActive: Bool { source.id == sources.activeID }
    private var isIncompatible: Bool { sources.incompatibleIDs.contains(source.id) }
    private var canConnect: Bool { source.isOnline && source.connected && !isIncompatible }

    var body: some View {
        Button {
            if !isActive { sources.connect(source.id) }
        } label: {
            HStack(spacing: 14) {
                icon
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(source.name)
                            .font(.body.weight(isActive ? .semibold : .regular))
                            .foregroundStyle(.primary)
                        if sources.remoteAddresses[source.id] != nil {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Via Tailscale")
                        }
                    }
                    Text(
                        SourcePresentation.detail(
                            source, isActive: isActive, isLastUsed: source.id == sources.lastUsedID,
                            isIncompatible: isIncompatible, remoteAddress: sources.remoteAddresses[source.id]))
                        .font(.subheadline)
                        .foregroundStyle(SourcePresentation.isWarning(source, isIncompatible: isIncompatible) ? .orange : .secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(.vertical, 4)
            .opacity(source.isOnline ? 1 : 0.55)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isActive && !canConnect)
        .accessibilityElement(children: .combine)
        .accessibilityHint(!isActive && canConnect ? "Double-tap to play from this Mac" : "")
    }

    private var icon: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: SourcePresentation.symbol(for: source.name))
                .font(.title3)
                .foregroundStyle(isActive ? .white : (source.isOnline ? Color.primary : Color.secondary))
                .frame(width: 46, height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(isActive ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(.quaternary)))
            Circle()
                .fill(dotColor)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(Color(uiColor: .secondarySystemGroupedBackground), lineWidth: 2.5))
                .offset(x: 3, y: 3)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var trailing: some View {
        if isActive {
            Image(systemName: "waveform")
                .font(.title3)
                .foregroundStyle(Brand.blue)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: source.isStreamingToUs)
                .accessibilityLabel(source.isStreamingToUs ? "Playing here" : "Starting")
        } else if source.status?.audioPlaying == true {
            Image(systemName: "waveform")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Audio playing")
        } else if canConnect {
            Text("Play here")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.blue)
        }
    }

    private var dotColor: Color {
        if !source.isOnline { return .gray }
        if isActive { return source.isStreamingToUs ? .green : .yellow }
        if isIncompatible || source.status?.problem != nil { return .orange }
        return source.connected ? .green.opacity(0.7) : .gray
    }
}
