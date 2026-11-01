import SwiftUI

/// The Settings tab shared by the variants: delay mode, quality, microphone
/// and data usage, each explained in one line. A native Form so it reads
/// like iOS Settings whatever the variant looks like elsewhere.
struct LabSettingsForm: View {
    @ObservedObject var store: LabStore
    /// Variants that already show the delay control on Now can leave it out.
    var showsDelay = true
    @State private var cellularSaver = true
    @State private var dataWarning = true
    @State private var micSource = "iPhone microphone"

    var body: some View {
        Form {
            if showsDelay {
                Section {
                    ForEach(LabLatency.allCases) { mode in
                        Button {
                            withAnimation(.snappy) { store.latency = mode }
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: mode.symbol)
                                    .font(.title3)
                                    .foregroundStyle(mode == store.latency ? LabBrand.blue : .secondary)
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(mode.title).foregroundStyle(.primary)
                                        Text("\(store.targetMs(for: mode)) ms")
                                            .font(.subheadline.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(mode.shortExplanation)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if mode == store.latency {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(LabBrand.blue)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(mode == store.latency ? .isSelected : [])
                    }
                } header: {
                    Text("Delay")
                } footer: {
                    Text(store.latency.explanation)
                }
            }

            Section {
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
                Toggle(isOn: $cellularSaver) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Save data on cellular")
                            Text("Opus 128 away from Wi‑Fi, ≈ 190 MB/h")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    }
                }
            } header: {
                Text("Sound")
            }

            Section {
                Toggle(isOn: $store.micEnabled.animation(.snappy)) {
                    Label("Talk through iPhone", systemImage: "mic")
                }
                if store.micEnabled {
                    Picker(selection: $micSource) {
                        Text("iPhone microphone").tag("iPhone microphone")
                        Text("AirPods microphone").tag("AirPods microphone")
                    } label: {
                        Label("Input", systemImage: "waveform")
                    }
                    HStack(spacing: 12) {
                        LabLevelMeter(level: store.snapshot.mic.level, segments: 22, muted: store.micMuted)
                        Button(store.micMuted ? "Unmute" : "Mute") { store.micMuted.toggle() }
                            .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Microphone")
            } footer: {
                Text("Your Mac sees “Mac Audio Bridge Mic” as an input. Turn this on before you start a call.")
            }

            Section {
                LabeledContent("This session") {
                    Text(store.link.map { LabFormat.megabytes($0.dataUsedMB) } ?? "—").monospacedDigit()
                }
                LabeledContent("Rate") {
                    Text(store.link.map { "≈ \($0.mbPerHour) MB/h" } ?? "—").monospacedDigit()
                }
                LabeledContent("This month on cellular") {
                    Text("2.4 GB").monospacedDigit()
                }
                Toggle("Warn above 1 GB a day", isOn: $dataWarning)
            } header: {
                Text("Data usage")
            }

            Section {
                LabeledContent("Version", value: "0.6.0 (DesignLab)")
                Button {
                } label: {
                    Label("Share stats log", systemImage: "square.and.arrow.up")
                }
            }
        }
        .navigationTitle("Settings")
    }
}
