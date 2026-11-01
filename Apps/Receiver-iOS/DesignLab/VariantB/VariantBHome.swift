import SwiftUI

/// Variant B — "Control panel". Dense and glanceable for a power user: a tab
/// bar (Now / Sources / Details), the Now tab is a grid of link-quality
/// tiles with live numbers, every control one tap away.
struct VariantBRoot: View {
    @ObservedObject var store: LabStore
    @State private var tab: LabScreen

    init(store: LabStore, initialScreen: LabScreen) {
        self.store = store
        _tab = State(initialValue: initialScreen)
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Now", systemImage: "gauge.with.dots.needle.67percent", value: LabScreen.home) {
                NavigationStack { VariantBDashboard(store: store) }
            }
            Tab("Sources", systemImage: "laptopcomputer.and.iphone", value: LabScreen.sources) {
                NavigationStack {
                    LabSourcesList(store: store)
                        .navigationTitle("Sources")
                }
            }
            Tab("Details", systemImage: "chart.xyaxis.line", value: LabScreen.details) {
                NavigationStack { VariantBDetails(store: store) }
            }
        }
    }
}

struct VariantBDashboard: View {
    @ObservedObject var store: LabStore
    @Environment(\.labScrollAnchor) private var scrollAnchor

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if store.isConnected {
                    VariantBNowPlayingStrip(store: store)
                    VariantBHealthTile(store: store)
                    LazyVGrid(columns: columns, spacing: 12) {
                        latencyTile
                        lossTile
                        codecTile
                        dataTile
                    }
                } else {
                    VariantBIdleBanner(store: store)
                    LazyVGrid(columns: columns, spacing: 12) {
                        placeholderTile("Delay", "timer")
                        placeholderTile("Loss", "waveform.badge.exclamationmark")
                        placeholderTile("Quality", "dial.medium")
                        placeholderTile("Data", "chart.bar.fill")
                    }
                }
                VariantBLatencyPicker(store: store)
                VariantBVolumeTile(store: store)
                VariantBMicTile(store: store)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .defaultScrollAnchor(scrollAnchor)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(store.activeMac?.name ?? "Mac Audio Bridge")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(store.snapshot.macs.filter(\.online)) { mac in
                        Button(mac.name, systemImage: mac.active ? "checkmark" : mac.symbol) {}
                    }
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .accessibilityLabel("Switch Mac")
            }
        }
    }

    // MARK: Tiles

    private var latencyTile: some View {
        VariantBTile(title: "Delay", symbol: "timer", accent: LabBrand.blue) {
            if let link = store.link {
                VariantBBigNumber(value: "\(link.breakdown.totalMs)", unit: "ms")
                LabSparkline(values: link.delayHistory, color: LabBrand.blue)
                    .frame(height: 26)
                Text("buffer \(link.targetMs) ms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var lossTile: some View {
        VariantBTile(
            title: "Loss", symbol: "waveform.badge.exclamationmark",
            accent: (store.link?.lossPercent ?? 0) > 1 ? .orange : .green
        ) {
            if let link = store.link {
                VariantBBigNumber(value: String(format: "%.1f", link.lossPercent), unit: "%")
                LabSparkline(
                    values: link.lossHistory, color: link.lossPercent > 1 ? .orange : .green)
                    .frame(height: 26)
                Text("\(link.recovered) recovered · \(link.concealed) filled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    private var codecTile: some View {
        VariantBTile(title: "Quality", symbol: "dial.medium", accent: .purple) {
            if let link = store.link {
                VariantBBigNumber(value: "\(link.bitrateKbps)", unit: "kbit/s")
                Menu {
                    Picker("Quality", selection: $store.quality) {
                        ForEach(LabQuality.allCases) { quality in
                            Text("\(quality.title) — \(quality.subtitle)").tag(quality)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(store.quality.title)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .font(.subheadline.weight(.semibold))
                }
                Text(link.path == .wifi ? "Lossless available" : "Lossless off on cellular")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var dataTile: some View {
        VariantBTile(title: "Data", symbol: "chart.bar.fill", accent: .teal) {
            if let link = store.link {
                VariantBBigNumber(value: "\(link.mbPerHour)", unit: "MB/h")
                ProgressView(value: link.dataUsedMB, total: 1_000)
                    .tint(.teal)
                Text("\(LabFormat.megabytes(link.dataUsedMB)) this session")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func placeholderTile(_ title: String, _ symbol: String) -> some View {
        VariantBTile(title: title, symbol: symbol, accent: .secondary) {
            VariantBBigNumber(value: "—", unit: "")
            Text("Waiting for a Mac")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Generic dashboard tile.
struct VariantBTile<Content: View>: View {
    let title: String
    let symbol: String
    let accent: Color
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title.uppercased(), systemImage: symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(accent)
                .labelStyle(.titleAndIcon)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .labCard(cornerRadius: 22)
        .accessibilityElement(children: .combine)
    }
}

struct VariantBBigNumber: View {
    let value: String
    let unit: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(.system(.title, design: .rounded).weight(.bold))
                .monospacedDigit()
            Text(unit)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

struct VariantBNowPlayingStrip: View {
    @ObservedObject var store: LabStore

    var body: some View {
        if let track = store.nowPlaying {
            HStack(spacing: 12) {
                LabArtwork(
                    symbol: track.appSymbol, cornerRadius: 12,
                    seed: store.snapshot.scenario == .cellular ? 1 : 0)
                    .frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.headline).lineLimit(1)
                    Text("\(track.artist) · \(track.app)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                LabTransport(isPlaying: $store.isPlaying, size: 17, glass: false)
            }
            .padding(12)
            .labGlass(cornerRadius: 22)
        }
    }
}

/// The headline tile: overall link score as a ring plus path and verdict.
struct VariantBHealthTile: View {
    @ObservedObject var store: LabStore

    var body: some View {
        if let link = store.link {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .stroke(link.health.color.opacity(0.18), lineWidth: 9)
                    Circle()
                        .trim(from: 0, to: link.score)
                        .stroke(
                            link.health.color.gradient,
                            style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(Int(link.score * 100))")
                            .font(.system(.title2, design: .rounded).weight(.bold))
                            .monospacedDigit()
                        Text("score")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 84, height: 84)
                .accessibilityLabel("Link score \(Int(link.score * 100)) of 100")

                VStack(alignment: .leading, spacing: 6) {
                    Text(link.health.title)
                        .font(.title3.bold())
                        .foregroundStyle(link.health.color)
                    Text(link.headline)
                        .font(.subheadline)
                    HStack(spacing: 6) {
                        chip(link.path.title, link.path.symbol)
                        chip(String(format: "±%.0f ms", link.jitterMs), "waveform.path")
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .labCard(cornerRadius: 22)
        }
    }

    private func chip(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: .capsule)
    }
}

/// Three big buttons: one simple latency control.
struct VariantBLatencyPicker: View {
    @ObservedObject var store: LabStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("DELAY MODE", systemImage: "slider.horizontal.3")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(LabBrand.blue)
                Spacer()
                Text(store.latency.shortExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(LabLatency.allCases) { mode in
                    let selected = mode == store.latency
                    Button {
                        withAnimation(.snappy) { store.latency = mode }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: mode.symbol)
                                .font(.title3)
                            Text(mode.title)
                                .font(.subheadline.weight(.semibold))
                            Text("\(store.targetMs(for: mode)) ms")
                                .font(.caption.monospacedDigit())
                                .opacity(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(selected ? .white : .primary)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(selected ? AnyShapeStyle(LabBrand.gradient) : AnyShapeStyle(.quaternary)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityHint(mode.explanation)
                }
            }
        }
        .padding(14)
        .labCard(cornerRadius: 22)
    }
}

struct VariantBVolumeTile: View {
    @ObservedObject var store: LabStore

    var body: some View {
        HStack(spacing: 12) {
            Button {
                store.muted.toggle()
            } label: {
                Image(systemName: store.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 40)
                    .background(.quaternary, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.muted ? "Unmute Mac" : "Mute Mac")
            Slider(value: $store.volume, in: 0...1)
                .accessibilityLabel("Mac volume")
            Text("\(Int((store.volume * 100).rounded()))")
                .font(.system(.headline, design: .rounded).monospacedDigit())
                .frame(minWidth: 34, alignment: .trailing)
        }
        .padding(12)
        .labCard(cornerRadius: 22)
        .disabled(!store.isConnected)
        .opacity(store.isConnected ? 1 : 0.5)
    }
}

struct VariantBMicTile: View {
    @ObservedObject var store: LabStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("MIC", systemImage: "mic.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(store.micEnabled ? .red : .secondary)
                if store.micEnabled {
                    Text(store.micMuted ? "MUTED" : "LIVE")
                        .font(.caption2.weight(.heavy))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(.white)
                        .background(store.micMuted ? Color.gray : Color.red, in: .capsule)
                }
                Spacer()
                Toggle("Talk through iPhone", isOn: $store.micEnabled.animation(.snappy))
                    .font(.subheadline)
                    .fixedSize()
            }
            if store.micEnabled {
                HStack(spacing: 10) {
                    LabLevelMeter(level: store.snapshot.mic.level, segments: 24, muted: store.micMuted)
                    Button {
                        store.micMuted.toggle()
                    } label: {
                        Image(systemName: store.micMuted ? "mic.slash.fill" : "mic.fill")
                            .frame(width: 34, height: 34)
                            .background(store.micMuted ? Color.red.opacity(0.2) : Color.secondary.opacity(0.15), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(store.micMuted ? "Unmute microphone" : "Mute microphone")
                }
                Text(store.snapshot.mic.source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .labCard(cornerRadius: 22)
    }
}

struct VariantBIdleBanner: View {
    @ObservedObject var store: LabStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No Mac connected").font(.headline)
                    Text("Pick a Mac to start streaming.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.snapshot.macs) { mac in
                        Button {
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: mac.symbol)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(mac.name).font(.subheadline.weight(.semibold))
                                    Text(mac.online ? (mac.playing ? "Busy" : "Ready") : "Offline")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.quaternary, in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .disabled(!mac.online)
                        .opacity(mac.online ? 1 : 0.5)
                    }
                }
            }
        }
        .padding(16)
        .labCard(cornerRadius: 22)
    }
}
