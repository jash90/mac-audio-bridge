import SwiftUI

/// Variant C — "Glance". One screen, no scrolling: a big status orb that
/// says how it sounds in one word and one number, one latency control, a
/// glass control dock. Everything else lives in Details.
struct VariantCRoot: View {
    @ObservedObject var store: LabStore
    @State private var path: [LabScreen]

    init(store: LabStore, initialScreen: LabScreen) {
        self.store = store
        _path = State(initialValue: initialScreen == .home ? [] : [initialScreen])
    }

    var body: some View {
        NavigationStack(path: $path) {
            VariantCHome(store: store, path: $path)
                .navigationDestination(for: LabScreen.self) { screen in
                    switch screen {
                    case .details: VariantCDetails(store: store)
                    case .sources:
                        LabSourcesList(store: store)
                            .navigationTitle("Sources")
                    case .home: EmptyView()
                    }
                }
        }
    }
}

struct VariantCHome: View {
    @ObservedObject var store: LabStore
    @Binding var path: [LabScreen]

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 8)
            Spacer(minLength: 12)
            VariantCOrb(store: store)
            Spacer(minLength: 12)
            if store.isConnected {
                nowPlaying
                    .padding(.bottom, 18)
                VariantCLatencyControl(store: store)
                    .padding(.bottom, 16)
                VariantCDock(store: store) { path.append(.details) }
            } else {
                idleActions
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .background { VariantCBackground(health: store.link?.health ?? .none) }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        HStack {
            Button {
                path.append(.sources)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: store.activeMac?.symbol ?? "laptopcomputer.slash")
                    Text(store.activeMac?.name ?? "No Mac")
                        .font(.headline)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .opacity(0.6)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .labGlassCapsule()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Source: \(store.activeMac?.name ?? "none"). Change source")
            Spacer()
            if let link = store.link {
                Label(link.path.title, systemImage: link.path.symbol)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .labGlassCapsule()
            }
        }
    }

    @ViewBuilder
    private var nowPlaying: some View {
        if let track = store.nowPlaying {
            VStack(spacing: 10) {
                VStack(spacing: 2) {
                    Text(track.title)
                        .font(.title3.bold())
                        .lineLimit(1)
                    Text("\(track.artist) · \(track.app)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                LabTransport(isPlaying: $store.isPlaying, size: 22, glass: false)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var idleActions: some View {
        VStack(spacing: 12) {
            Text("Studio Mac mini is streaming to Bart's iPad · iMac (Office) is offline")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 4)
            ForEach(store.snapshot.macs.filter { $0.online && !$0.playing }) { mac in
                Button {
                } label: {
                    Label("Play from \(mac.name)", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .labProminentButton()
                .controlSize(.large)
            }
            Button {
                path.append(.sources)
            } label: {
                Text("Other Macs")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .labGlassButton()
            .controlSize(.large)
        }
        .padding(.bottom, 12)
    }
}

/// Full-bleed mesh background tinted by link health.
private struct VariantCBackground: View {
    let health: LabHealth
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let accent: Color =
            switch health {
            case .excellent: LabBrand.cyan
            case .fair: .orange
            case .none: .gray
            }
        let base: Color = colorScheme == .dark ? .black : .white
        MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.45], [0.6, 0.4], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ],
            colors: [
                LabBrand.indigo.opacity(0.55), LabBrand.blue.opacity(0.45), accent.opacity(0.5),
                LabBrand.indigo.opacity(0.25), accent.opacity(0.35), LabBrand.blue.opacity(0.25),
                base, base, base,
            ]
        )
        .background(base)
        .ignoresSafeArea()
    }
}

/// The big status: one word, one number.
struct VariantCOrb: View {
    @ObservedObject var store: LabStore

    private let bars: [CGFloat] = [0.3, 0.55, 0.8, 1, 0.7, 0.9, 0.5, 0.75, 0.4, 0.6, 0.35]

    var body: some View {
        let health = store.link?.health ?? .none
        ZStack {
            Circle()
                .fill(.clear)
                .labGlassCircle()
                .frame(width: 280, height: 280)
            Circle()
                .stroke(health.color.opacity(health == .none ? 0.25 : 0.6), lineWidth: 3)
                .frame(width: 248, height: 248)
            VStack(spacing: 10) {
                HStack(alignment: .center, spacing: 4) {
                    ForEach(bars.indices, id: \.self) { index in
                        Capsule()
                            .fill(health == .none ? AnyShapeStyle(.tertiary) : AnyShapeStyle(LabBrand.gradient))
                            .frame(width: 5, height: health == .none ? 6 : 34 * bars[index])
                    }
                }
                .frame(height: 36)
                if let link = store.link {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(link.breakdown.totalMs)")
                            .font(.system(size: 64, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("ms")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Label(link.health.title, systemImage: link.health.symbol)
                        .font(.headline)
                        .foregroundStyle(link.health.color)
                } else {
                    Text("Not connected")
                        .font(.title2.bold())
                    Text("Choose a Mac to listen")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .overlay(alignment: .bottom) {
            if let link = store.link {
                Text(link.headline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .offset(y: 34)
            }
        }
        .padding(.bottom, store.link == nil ? 0 : 34)
    }
}

/// One latency control as a 3-stop glass slider with a plain sentence.
struct VariantCLatencyControl: View {
    @ObservedObject var store: LabStore
    @Namespace private var thumb

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                ForEach(LabLatency.allCases) { mode in
                    let selected = mode == store.latency
                    Button {
                        withAnimation(.spring(duration: 0.35, bounce: 0.25)) { store.latency = mode }
                    } label: {
                        Label(mode.title, systemImage: mode.symbol)
                            .font(.subheadline.weight(.semibold))
                            .labelStyle(.titleAndIcon)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .foregroundStyle(selected ? .white : .primary)
                            .background {
                                if selected {
                                    Capsule()
                                        .fill(LabBrand.gradient)
                                        .matchedGeometryEffect(id: "thumb", in: thumb)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(4)
            .labGlassCapsule()
            Text(store.latency.explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 34, alignment: .top)
        }
    }
}

/// Bottom dock: volume + mute, quality, mic, details.
struct VariantCDock: View {
    @ObservedObject var store: LabStore
    let openDetails: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    store.muted.toggle()
                } label: {
                    Image(systemName: store.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 24)
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
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.quaternary, in: .capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Quality: \(store.quality.title)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .labGlassCapsule()

            HStack(spacing: 10) {
                micButton
                if store.micEnabled {
                    Button {
                        store.micMuted.toggle()
                    } label: {
                        Image(systemName: store.micMuted ? "mic.slash.fill" : "mic.slash")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(store.micMuted ? .red : .primary)
                            .frame(width: 48, height: 48)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .labGlassCircle()
                    .accessibilityLabel(store.micMuted ? "Unmute microphone" : "Mute microphone")
                }
                Button(action: openDetails) {
                    Label("Details", systemImage: "chart.bar.doc.horizontal")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .labGlassCapsule()
            }
        }
    }

    private var micButton: some View {
        Button {
            withAnimation(.snappy) { store.micEnabled.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: store.micEnabled ? "mic.fill" : "mic.slash")
                    .foregroundStyle(store.micEnabled ? .red : .primary)
                if store.micEnabled {
                    LabLevelMeter(level: store.snapshot.mic.level, segments: 8, muted: store.micMuted)
                        .frame(width: 56)
                } else {
                    Text("Talk through iPhone")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .labGlassCapsule(tint: store.micEnabled ? .red.opacity(0.15) : nil)
        .accessibilityLabel(store.micEnabled ? "Talk through iPhone, on" : "Talk through iPhone, off")
    }
}
