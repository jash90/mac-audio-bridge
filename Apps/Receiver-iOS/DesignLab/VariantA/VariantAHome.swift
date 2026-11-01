import SwiftUI

/// Variant A — "Now Playing first". Calm, music-app-like: the big player
/// card is the Now tab, the link is one plain sentence under it. Sources,
/// Details and Settings (delay, quality, mic, data) are tabs in the bottom
/// Liquid Glass tab bar.
struct VariantAHome: View {
    @ObservedObject var store: LabStore
    @State private var tab: LabScreen

    init(store: LabStore, initialScreen: LabScreen) {
        self.store = store
        _tab = State(initialValue: initialScreen)
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Now", systemImage: "play.circle.fill", value: LabScreen.home) {
                VariantANow(store: store, tab: $tab)
            }
            Tab("Sources", systemImage: "laptopcomputer.and.iphone", value: LabScreen.sources) {
                NavigationStack {
                    LabSourcesList(store: store)
                        .navigationTitle("Sources")
                }
            }
            Tab("Details", systemImage: "waveform.path.ecg", value: LabScreen.details) {
                NavigationStack { VariantADetails(store: store) }
            }
            Tab("Settings", systemImage: "gearshape", value: LabScreen.settings) {
                NavigationStack { LabSettingsForm(store: store) }
            }
        }
    }
}

/// The Now tab: player, link sentence, mic.
struct VariantANow: View {
    @ObservedObject var store: LabStore
    @Binding var tab: LabScreen
    @Environment(\.labScrollAnchor) private var scrollAnchor

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if store.isConnected {
                        VariantAPlayer(store: store)
                        VariantAConnectionCard(store: store) { tab = .details }
                        VariantAMicCard(store: store)
                    } else {
                        VariantAEmptyState(store: store) { tab = .sources }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .defaultScrollAnchor(scrollAnchor)
            .background { VariantABackdrop(connected: store.isConnected) }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    sourcePill
                }
            }
        }
    }

    private var sourcePill: some View {
        Button {
            tab = .sources
        } label: {
            HStack(spacing: 6) {
                LabStatusDot(color: store.isConnected ? .green : .gray, size: 7)
                Text(store.activeMac?.name ?? "Choose a Mac")
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Source: \(store.activeMac?.name ?? "none"). Change source")
    }
}

/// Soft colour wash behind the player (artwork tint when playing).
private struct VariantABackdrop: View {
    let connected: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color(uiColor: .systemGroupedBackground)
            LinearGradient(
                colors: connected
                    ? [LabBrand.indigo.opacity(0.35), LabBrand.cyan.opacity(0.12), .clear]
                    : [LabBrand.blue.opacity(0.18), .clear],
                startPoint: .top, endPoint: .center)
        }
        .ignoresSafeArea()
    }
}

struct VariantAPlayer: View {
    @ObservedObject var store: LabStore

    var body: some View {
        if let track = store.nowPlaying {
            VStack(spacing: 16) {
                LabArtwork(
                    symbol: track.appSymbol, cornerRadius: 28,
                    seed: store.snapshot.scenario == .cellular ? 1 : 0)
                    .frame(width: 196, height: 196)
                    .shadow(color: LabBrand.indigo.opacity(0.35), radius: 24, y: 12)
                    .padding(.top, 8)

                VStack(spacing: 4) {
                    Text(track.title)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text(track.artist)
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Label("\(track.app) on \(store.activeMac?.name ?? "Mac")", systemImage: "laptopcomputer")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }

                VStack(spacing: 4) {
                    ProgressView(value: track.elapsed, total: track.duration)
                        .tint(.primary.opacity(0.7))
                    HStack {
                        Text(LabFormat.time(track.elapsed))
                        Spacer()
                        Text("-" + LabFormat.time(track.duration - track.elapsed))
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }

                LabTransport(isPlaying: $store.isPlaying, size: 26)

                HStack(spacing: 12) {
                    Button {
                        store.muted.toggle()
                    } label: {
                        Image(systemName: store.muted ? "speaker.slash.fill" : "speaker.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(store.muted ? "Unmute Mac" : "Mute Mac")
                    Slider(value: $store.volume, in: 0...1)
                        .accessibilityLabel("Mac volume")
                    Menu {
                        Picker("Quality", selection: $store.quality) {
                            ForEach(LabQuality.allCases) { quality in
                                Text("\(quality.title) — \(quality.subtitle)").tag(quality)
                            }
                        }
                    } label: {
                        Text(store.quality.title)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .labGlassCapsule()
                    }
                    .accessibilityLabel("Quality: \(store.quality.title)")
                }
                .foregroundStyle(.secondary)
            }
            .padding(20)
            .labGlass(cornerRadius: 32)
        }
    }
}

struct VariantAConnectionCard: View {
    @ObservedObject var store: LabStore
    let openDetails: () -> Void

    var body: some View {
        if let link = store.link {
            Button(action: openDetails) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: link.health.symbol)
                            .font(.title2)
                            .foregroundStyle(link.health.color)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(link.headline)
                                .font(.headline)
                            Text(link.explanation)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 0) {
                        fact(link.path.symbol, link.path.title, "Path")
                        Divider().frame(height: 30)
                        fact("timer", "\(link.breakdown.totalMs) ms", "Delay")
                        Divider().frame(height: 30)
                        fact("chart.bar.fill", "≈ \(link.mbPerHour) MB/h", "Data")
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .labGlass(cornerRadius: 26)
            .accessibilityHint("Shows connection details")
        }
    }

    private func fact(_ symbol: String, _ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Label(value, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct VariantALatencyCard: View {
    @ObservedObject var store: LabStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Delay")
                    .font(.headline)
                Spacer()
                Text("buffer ≈ \(store.targetMs(for: store.latency)) ms")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Picker("Delay", selection: $store.latency.animation(.snappy)) {
                ForEach(LabLatency.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text(store.latency.explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
        .padding(18)
        .labGlass(cornerRadius: 26)
    }
}

struct VariantAMicCard: View {
    @ObservedObject var store: LabStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $store.micEnabled.animation(.snappy)) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Talk through iPhone")
                            .font(.headline)
                        Text(store.micEnabled ? "Your Mac hears this iPhone's microphone" : "Use the iPhone as your Mac's microphone")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: store.micEnabled && !store.micMuted ? "mic.fill" : "mic.slash")
                        .foregroundStyle(store.micEnabled ? LabBrand.blue : .secondary)
                }
            }
            if store.micEnabled {
                HStack(spacing: 12) {
                    LabLevelMeter(level: store.snapshot.mic.level, muted: store.micMuted)
                    Button(store.micMuted ? "Unmute" : "Mute") {
                        store.micMuted.toggle()
                    }
                    .font(.subheadline.weight(.semibold))
                    .labGlassButton()
                    .tint(store.micMuted ? .red : nil)
                }
            }
        }
        .padding(18)
        .labGlass(cornerRadius: 26)
    }
}

struct VariantAEmptyState: View {
    @ObservedObject var store: LabStore
    let openSources: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 44, style: .continuous)
                    .fill(LabBrand.gradient)
                    .frame(width: 168, height: 168)
                    .shadow(color: LabBrand.indigo.opacity(0.35), radius: 28, y: 14)
                HStack(spacing: 6) {
                    Image(systemName: "dot.radiowaves.right")
                        .font(.system(size: 44, weight: .semibold))
                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 70, weight: .regular))
                }
                .foregroundStyle(.white)
            }
            .padding(.top, 36)
            .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Listen to your Mac")
                    .font(.title.bold())
                Text("Pick a Mac to play its sound on this iPhone and your AirPods.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 10) {
                ForEach(store.snapshot.macs.filter(\.online)) { mac in
                    Button {
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: mac.symbol)
                                .font(.title3)
                                .frame(width: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mac.name).font(.headline)
                                Text(mac.detail).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "play.fill")
                                .foregroundStyle(LabBrand.blue)
                        }
                        .padding(16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .labGlass(cornerRadius: 22, interactive: true)
                }
            }

            Button("All sources", action: openSources)
                .font(.subheadline.weight(.semibold))
            Label("Don't see your Mac? Open Mac Audio Bridge on it.", systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
