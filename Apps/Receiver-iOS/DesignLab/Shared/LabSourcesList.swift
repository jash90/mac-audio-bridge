import SwiftUI

/// Polished version of today's Sources list (the concept the user likes):
/// every Mac with live status, tap to use it, the active row carries volume,
/// mute, quality and Disconnect. Shared by all three variants so Sources stay
/// the same whichever direction is picked.
struct LabSourcesList: View {
    @ObservedObject var store: LabStore

    var body: some View {
        List {
            Section {
                ForEach(store.snapshot.macs) { mac in
                    LabSourceRow(store: store, mac: mac)
                }
            } header: {
                Text("Macs")
            } footer: {
                Label(
                    store.snapshot.scenario == .cellular
                        ? "Away from home: Macs you paired on Wi‑Fi are reached through Tailscale."
                        : "Looking for Macs on this Wi‑Fi and your tailnet…",
                    systemImage: store.snapshot.scenario == .cellular ? "lock.shield" : "dot.radiowaves.left.and.right")
                    .font(.footnote)
            }

            if let active = store.activeMac {
                Section("\(active.name) output") {
                    LabActiveSourceControls(store: store)
                }
            }

            Section {
                Button {
                } label: {
                    Label("Add a Mac by address", systemImage: "plus.circle")
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

struct LabSourceRow: View {
    @ObservedObject var store: LabStore
    let mac: LabMac

    var body: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: mac.symbol)
                    .font(.title3)
                    .foregroundStyle(mac.active ? .white : (mac.online ? Color.primary : Color.secondary))
                    .frame(width: 46, height: 46)
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(mac.active ? AnyShapeStyle(LabBrand.gradient) : AnyShapeStyle(.quaternary)))
                Circle()
                    .fill(dotColor)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color(uiColor: .secondarySystemGroupedBackground), lineWidth: 2.5))
                    .offset(x: 3, y: 3)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(mac.name)
                        .font(.body.weight(mac.active ? .semibold : .regular))
                    if let path = mac.path, path != .wifi {
                        Image(systemName: path.symbol)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(path.title)
                    }
                }
                Text(mac.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 4)
        .opacity(mac.online ? 1 : 0.55)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(mac.active ? "" : mac.online ? "Double-tap to play from this Mac" : "")
    }

    @ViewBuilder
    private var trailing: some View {
        if mac.active {
            Image(systemName: "waveform")
                .font(.title3)
                .foregroundStyle(LabBrand.blue)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: mac.playing)
                .accessibilityLabel("Playing here")
        } else if mac.playing {
            Image(systemName: "waveform")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Playing elsewhere")
        } else if mac.online {
            Text("Play here")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LabBrand.blue)
        }
    }

    private var dotColor: Color {
        if !mac.online { return .gray }
        if mac.active { return .green }
        return mac.playing ? .orange : .green.opacity(0.7)
    }
}

/// Volume, mute, quality and Disconnect for the active Mac.
struct LabActiveSourceControls: View {
    @ObservedObject var store: LabStore
    var showsDisconnect = true

    var body: some View {
        HStack(spacing: 12) {
            Button {
                store.muted.toggle()
            } label: {
                Image(systemName: store.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 28)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(store.muted ? "Unmute Mac" : "Mute Mac")
            Slider(value: $store.volume, in: 0...1)
                .accessibilityLabel("Mac volume")
            Text("\(Int((store.volume * 100).rounded()))%")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 42, alignment: .trailing)
        }
        Picker(selection: $store.quality) {
            ForEach(LabQuality.allCases) { quality in
                VStack(alignment: .leading) {
                    Text(quality.title)
                    Text(quality.subtitle)
                }
                .tag(quality)
            }
        } label: {
            Label("Quality", systemImage: "dial.medium")
        }
        .pickerStyle(.menu)
        if showsDisconnect {
            Button(role: .destructive) {
            } label: {
                Label("Disconnect", systemImage: "xmark.circle")
            }
        }
    }
}
