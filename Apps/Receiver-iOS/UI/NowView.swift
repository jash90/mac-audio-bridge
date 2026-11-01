import BridgeCore
import SwiftUI

/// The Now tab: the player card for the active Mac, one card on how the
/// link is doing, and (later) the mic. Without a source: pick a Mac.
struct NowView: View {
    @ObservedObject var model: ReceiverModel
    @ObservedObject var sources: SourcesModel
    @Binding var tab: AppTab

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let active = sources.active {
                        PlayerCard(sources: sources, source: active)
                        ConnectionCard(model: model, source: active) { tab = .details }
                        if FeatureFlags.phoneMicrophone {
                            MicCard(mic: model.mic, macSupportsMic: sources.activeSupportsMic)
                        }
                    } else {
                        EmptyNowState(sources: sources) { tab = .sources }
                    }
                    if case .failed(let message) = model.phase {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .background { NowBackdrop(connected: sources.active != nil) }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { sourcePill }
            }
        }
    }

    private var sourcePill: some View {
        Button {
            tab = .sources
        } label: {
            HStack(spacing: 6) {
                StatusDot(color: pillColor, size: 7)
                Text(sources.active?.name ?? "Choose a Mac")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Source: \(sources.active?.name ?? "none"). Change source")
    }

    private var pillColor: Color {
        guard let active = sources.active else { return .gray }
        return active.isStreamingToUs ? .green : .yellow
    }
}

/// Soft colour wash behind the cards.
private struct NowBackdrop: View {
    let connected: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color(uiColor: .systemGroupedBackground)
            LinearGradient(
                colors: connected
                    ? [Brand.indigo.opacity(0.35), Brand.cyan.opacity(0.12), .clear]
                    : [Brand.blue.opacity(0.18), .clear],
                startPoint: .top, endPoint: .center)
        }
        .ignoresSafeArea()
    }
}

/// Artwork, title, artist and player app from the Mac's Now Playing,
/// transport when the Mac takes commands, then volume and quality.
private struct PlayerCard: View {
    @ObservedObject var sources: SourcesModel
    let source: SourceArbiter.Source

    /// When the current Now Playing message arrived (its `elapsed` is the
    /// position at that moment).
    @State private var trackReceivedAt = Date()

    var body: some View {
        let track = sources.activeNowPlaying
        VStack(spacing: 16) {
            ArtworkView(
                artwork: track?.artwork,
                symbol: track == nil ? SourcePresentation.symbol(for: source.name) : "music.note")
                .frame(width: 196, height: 196)
                .shadow(color: Brand.indigo.opacity(0.35), radius: 24, y: 12)
                .padding(.top, 8)

            titles(track)

            if let track, let duration = track.duration, duration > 0, let elapsed = track.elapsed {
                progress(elapsed: elapsed, duration: duration, isPlaying: track.isPlaying)
            }

            if let track {
                if sources.activeCanControl {
                    transport(isPlaying: track.isPlaying)
                } else if !track.canControl {
                    Text("Allow Accessibility for Mac Audio Bridge on the Mac to control playback")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            }

            if let status = source.status {
                HStack(spacing: 10) {
                    MacVolumeRow(sources: sources, sourceID: source.id, status: status, showsPercent: false)
                    qualityChip(status)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .glassCard(cornerRadius: 32)
        .onChange(of: track) { _, _ in trackReceivedAt = Date() }
    }

    @ViewBuilder
    private func titles(_ track: NowPlayingInfo?) -> some View {
        VStack(spacing: 4) {
            if let track {
                Text(track.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if let artist = track.artist, !artist.isEmpty {
                    Text(artist)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Label(
                    track.app.map { "\($0) on \(source.name)" } ?? source.name,
                    systemImage: "laptopcomputer")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            } else {
                Text(source.name)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(source.status?.audioPlaying == true ? "Playing" : "Nothing playing")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func progress(elapsed: Double, duration: Double, isPlaying: Bool) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let moved = isPlaying ? context.date.timeIntervalSince(trackReceivedAt) : 0
            let position = min(max(elapsed + moved, 0), duration)
            VStack(spacing: 4) {
                ProgressView(value: position, total: duration)
                    .tint(.primary.opacity(0.7))
                HStack {
                    Text(TimeFormat.clock(position))
                    Spacer()
                    Text("-" + TimeFormat.clock(duration - position))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Position \(TimeFormat.clock(position)) of \(TimeFormat.clock(duration))")
        }
    }

    private func transport(isPlaying: Bool) -> some View {
        HStack(spacing: 24) {
            transportButton("backward.fill", label: "Previous", size: 20) { sources.media(.previousTrack) }
            transportButton(isPlaying ? "pause.fill" : "play.fill", label: isPlaying ? "Pause" : "Play", size: 28) {
                sources.media(.togglePlayPause)
            }
            transportButton("forward.fill", label: "Next", size: 20) { sources.media(.nextTrack) }
        }
    }

    private func transportButton(_ symbol: String, label: String, size: CGFloat, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(.primary)
                .frame(width: size * 2.1, height: size * 2.1)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassCircle()
        .accessibilityLabel(label)
    }

    /// The quality chip: on the Internet profile it picks the Internet
    /// quality (with its MB/h), otherwise the Wi‑Fi quality.
    private func qualityChip(_ status: SourceStatus) -> some View {
        let effective = status.effectiveQuality
        return Menu {
            if status.profile == .wan, sources.supportsInternetQuality(source.id) {
                Picker(
                    "Internet quality",
                    selection: Binding(
                        get: { status.internetQuality ?? .default },
                        set: { sources.setInternetQuality($0, for: source.id) })
                ) {
                    ForEach(InternetQuality.allCases, id: \.self) { quality in
                        Text(quality.menuName).tag(quality)
                    }
                }
                Text("Now ≈ \(Int((status.megabytesPerHour ?? 0).rounded())) MB/h")
            } else {
                Picker("Quality", selection: Binding(get: { status.quality }, set: { sources.setQuality($0, for: source.id) })) {
                    ForEach(StreamQuality.lanChoices, id: \.self) { quality in
                        Text(quality.menuName).tag(quality)
                    }
                }
                if let note = status.qualityNote {
                    Text(note)
                }
            }
        } label: {
            Text(effective.shortName)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassCapsule()
        }
        .accessibilityLabel("Quality: \(effective.shortName)")
    }
}

/// One card that says how the link is in plain words, with path, total
/// delay and data rate. Opens Details.
private struct ConnectionCard: View {
    @ObservedObject var model: ReceiverModel
    let source: SourceArbiter.Source
    let openDetails: () -> Void

    var body: some View {
        Button(action: openDetails) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: headline.symbol)
                        .font(.title2)
                        .foregroundStyle(headline.color)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(headline.title)
                            .font(.headline)
                        Text(headline.text)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                if let path = model.streamPath {
                    HStack(spacing: 0) {
                        fact(path.symbol, path.displayName, "Path")
                        Divider().frame(height: 30)
                        fact("timer", "≈ \(model.totalMilliseconds) ms", "Delay")
                        Divider().frame(height: 30)
                        fact("chart.bar.fill", "≈ \(Int(model.megabytesPerHour.rounded())) MB/h", "Data")
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassCard(cornerRadius: 26)
        .accessibilityHint("Shows connection details")
    }

    private var headline: (symbol: String, color: Color, title: String, text: String) {
        if let problem = source.status?.problem {
            return ("exclamationmark.triangle.fill", .orange, "Needs attention on the Mac", problem)
        }
        guard let path = model.streamPath else {
            if source.status == nil || !source.connected {
                return ("hourglass", .secondary, "Connecting…", "Reaching \(source.name).")
            }
            return ("speaker.zzz.fill", .secondary, "Waiting for sound", "The Mac streams as soon as something plays.")
        }
        let summary = LinkSummary(
            path: path, recentLossPercent: model.recentLossPercent, recentRebuffers: model.recentRebuffers)
        return (summary.health.symbol, summary.health.color, summary.headline, summary.explanation)
    }

    private func fact(_ symbol: String, _ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Label(value, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
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

/// "Talk through iPhone": arm the mic (foreground only), see the level,
/// mute. The Mac asks for the audio when a call opens its "iPhone Mic".
private struct MicCard: View {
    @ObservedObject var mic: MicrophoneModel
    let macSupportsMic: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: armedBinding.animation(.snappy)) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Talk through iPhone")
                            .font(.headline)
                        Text(MicPresentation.subtitle(mic.phase, muted: mic.muted, macSupportsMic: macSupportsMic))
                            .font(.subheadline)
                            .foregroundStyle(MicPresentation.isWarning(mic.phase) ? .orange : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: MicPresentation.symbol(mic.phase, muted: mic.muted))
                        .foregroundStyle(mic.isArmed ? (mic.muted ? .orange : Brand.blue) : .secondary)
                }
            }
            .disabled(mic.phase == .arming)
            if mic.isArmed {
                HStack(spacing: 12) {
                    MicLevelMeter(level: mic.muted ? 0 : mic.level)
                    Button {
                        mic.muted.toggle()
                    } label: {
                        Label(mic.muted ? "Unmute" : "Mute", systemImage: mic.muted ? "mic.slash.fill" : "mic.fill")
                            .labelStyle(.iconOnly)
                            .font(.title3)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(mic.muted ? .orange : Brand.blue)
                    .accessibilityLabel(mic.muted ? "Unmute microphone" : "Mute microphone")
                }
            }
        }
        .padding(18)
        .glassCard(cornerRadius: 26)
    }

    private var armedBinding: Binding<Bool> {
        Binding(
            get: { mic.isArmed || mic.phase == .arming },
            set: { on in Task { await mic.setArmed(on) } })
    }
}

/// Texts and symbols shared by the mic card and the Settings section.
enum MicPresentation {
    static func subtitle(_ phase: MicrophoneModel.Phase, muted: Bool, macSupportsMic: Bool) -> String {
        switch phase {
        case .off:
            macSupportsMic
                ? "Use the iPhone as your Mac's microphone in calls"
                : "Update Mac Audio Bridge on the Mac to use the iPhone mic"
        case .arming: "Starting the microphone…"
        case .armed: "Ready — pick “iPhone Mic (Mac Audio Bridge)” in your call"
        case .live(let name): muted ? "Muted — \(name) hears silence" : "Live — \(name) hears you"
        case .unavailable(let message): message
        }
    }

    static func symbol(_ phase: MicrophoneModel.Phase, muted: Bool) -> String {
        switch phase {
        case .live: muted ? "mic.slash.fill" : "mic.fill"
        case .armed, .arming: "mic"
        case .unavailable: "mic.badge.xmark"
        case .off: "mic.slash"
        }
    }

    static func isWarning(_ phase: MicrophoneModel.Phase) -> Bool {
        if case .unavailable = phase { return true }
        return false
    }
}

/// Input level, RMS mapped to −60…0 dBFS.
struct MicLevelMeter: View {
    let level: Float

    var body: some View {
        let db = level > 0 ? 20 * log10(Double(level)) : -60
        let fraction = min(max((db + 60) / 60, 0), 1)
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(Brand.gradient).frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 8)
        .animation(.linear(duration: 0.1), value: fraction)
        .accessibilityLabel("Microphone level")
        .accessibilityValue("\(Int(db.rounded())) decibels")
    }
}

/// No active Mac: the online Macs to play from, a reconnect shortcut and
/// the way to Sources.
private struct EmptyNowState: View {
    @ObservedObject var sources: SourcesModel
    let openSources: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 44, style: .continuous)
                    .fill(Brand.gradient)
                    .frame(width: 168, height: 168)
                    .shadow(color: Brand.indigo.opacity(0.35), radius: 28, y: 14)
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
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if sources.activeID == nil, let last = sources.lastUsed, last.connected {
                Button {
                    sources.reconnectLast()
                } label: {
                    Label("Reconnect to \(last.name)", systemImage: "arrow.clockwise")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .glassProminentButton()
            }

            let online = sources.sources.filter(\.isOnline)
            if online.isEmpty {
                Label("Looking for Macs on this Wi‑Fi and your tailnet…", systemImage: "dot.radiowaves.left.and.right")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(online) { source in
                        macButton(source)
                    }
                }
            }

            Button("All sources", action: openSources)
                .font(.subheadline.weight(.semibold))
            Label("Don't see your Mac? Open Mac Audio Bridge on it.", systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func macButton(_ source: SourceArbiter.Source) -> some View {
        let incompatible = sources.incompatibleIDs.contains(source.id)
        let enabled = source.connected && !incompatible
        return Button {
            sources.connect(source.id)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: SourcePresentation.symbol(for: source.name))
                    .font(.title3)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name).font(.headline)
                    Text(
                        SourcePresentation.detail(
                            source, isActive: false, isLastUsed: source.id == sources.lastUsedID,
                            isIncompatible: incompatible, remoteAddress: sources.remoteAddresses[source.id])
                    )
                    .font(.subheadline)
                    .foregroundStyle(SourcePresentation.isWarning(source, isIncompatible: incompatible) ? .orange : .secondary)
                    .lineLimit(2)
                }
                Spacer()
                Image(systemName: "play.fill")
                    .foregroundStyle(enabled ? Brand.blue : .secondary)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .glassCard(cornerRadius: 22, interactive: true)
    }
}
