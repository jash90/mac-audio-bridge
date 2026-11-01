import BridgeCore
import SwiftUI
import UIKit

/// The Settings tab: delay mode, the active Mac's quality, (later) the mic,
/// data use, and the stats log.
struct SettingsView: View {
    @ObservedObject var model: ReceiverModel
    @ObservedObject var sources: SourcesModel
    @Binding var latencyMode: JitterLatencyMode
    @ObservedObject private var advertisement = ReceiverAdvertisement.shared

    var body: some View {
        Form {
            Section {
                ForEach(JitterLatencyMode.allCases, id: \.self) { mode in
                    delayRow(mode)
                }
            } header: {
                Text("Delay")
            } footer: {
                Text(
                    model.streamProfile == .wan
                        ? "Applies right away. Over the internet every mode starts higher, and the buffer grows when the network needs it."
                        : "Applies right away. The buffer starts here and grows only when the network needs it.")
            }

            Section {
                if let active = sources.active, let status = active.status {
                    QualityPicker(sources: sources, sourceID: active.id, status: status)
                    if let note = status.qualityNote {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                } else {
                    LabeledContent("Quality") {
                        Text("Connect a Mac first")
                    }
                }
            } header: {
                Text("Sound")
            } footer: {
                Text("Each Mac keeps its own quality. Over the internet the Mac caps it to save data.")
            }

            if FeatureFlags.phoneMicrophone {
                MicrophoneSection(mic: model.mic)
            }

            Section("Data usage") {
                LabeledContent("This session") {
                    Text(String(format: "%.1f MB", model.sessionMegabytes)).monospacedDigit()
                }
                LabeledContent("Rate") {
                    Text("≈ \(Int(model.megabytesPerHour.rounded())) MB/h").monospacedDigit()
                }
            }

            Section {
                if case .localNetworkDenied = advertisement.status {
                    Label("Local Network access is off, so your Mac can't find this iPhone.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
                LabeledContent("Version", value: Self.version)
                if FileManager.default.fileExists(atPath: model.statsFileURL.path) {
                    ShareLink(item: model.statsFileURL) {
                        Label("Share stats log", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .navigationTitle("Settings")
    }

    private func delayRow(_ mode: JitterLatencyMode) -> some View {
        Button {
            withAnimation(.snappy) { latencyMode = mode }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: mode.symbol)
                    .font(.title3)
                    .foregroundStyle(mode == latencyMode ? Brand.blue : .secondary)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(mode.displayName).foregroundStyle(.primary)
                        Text("from \(mode.minimumTargetMilliseconds(on: model.streamProfile)) ms")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(mode.shortExplanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if mode == latencyMode {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Brand.blue)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(mode == latencyMode ? .isSelected : [])
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}

/// "Talk through iPhone" settings: the same toggle and mute as on Now,
/// plus how the mic works.
private struct MicrophoneSection: View {
    @ObservedObject var mic: MicrophoneModel

    var body: some View {
        Section {
            Toggle(isOn: armedBinding) {
                Label("Talk through iPhone", systemImage: "mic")
            }
            .disabled(mic.phase == .arming)
            if mic.isArmed {
                Toggle(isOn: $mic.muted) {
                    Label("Mute", systemImage: "mic.slash")
                }
                LabeledContent("Level") {
                    MicLevelMeter(level: mic.muted ? 0 : mic.level).frame(width: 140)
                }
                LabeledContent("Echo cancellation") {
                    Text(mic.echoCancellation ? "On (speaker)" : "Off (headphones)")
                }
            }
            if case .unavailable(let message) = mic.phase {
                Text(message).font(.footnote).foregroundStyle(.orange)
            }
        } header: {
            Text("Microphone")
        } footer: {
            Text(
                "Your Mac gets this iPhone's built-in microphone as “iPhone Mic (Mac Audio Bridge)”. Turn it on here before the call — iOS only lets it start while the app is open; it then keeps running in the background. AirPods stay on full-quality sound.")
        }
    }

    private var armedBinding: Binding<Bool> {
        Binding(
            get: { mic.isArmed || mic.phase == .arming },
            set: { on in Task { await mic.setArmed(on) } })
    }
}
