import BridgeCore
import SwiftUI
import UIKit

/// Switches for UI that waits on a later milestone.
enum FeatureFlags {
    /// "Talk through iPhone": the mic card on Now and its Settings section.
    static let phoneMicrophone = true
}

/// The app icon's indigo → cyan gradient.
enum Brand {
    static let indigo = Color(red: 0.27, green: 0.22, blue: 0.87)
    static let blue = Color(red: 0.24, green: 0.42, blue: 0.92)
    static let cyan = Color(red: 0.09, green: 0.76, blue: 0.91)

    static var gradient: LinearGradient {
        LinearGradient(colors: [indigo, blue, cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension View {
    /// Liquid Glass on iOS 26+, a material card on older systems.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 24, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(
                interactive ? Glass.regular.interactive() : Glass.regular,
                in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.regularMaterial, in: .rect(cornerRadius: cornerRadius))
        }
    }

    @ViewBuilder
    func glassCircle() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(Glass.regular.interactive(), in: .circle)
        } else {
            background(.regularMaterial, in: .circle)
        }
    }

    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(Glass.regular.interactive(), in: .capsule)
        } else {
            background(.regularMaterial, in: .capsule)
        }
    }

    @ViewBuilder
    func glassButton() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    func glassProminentButton() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}

/// Small coloured status dot with a soft halo.
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 9

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .background(Circle().fill(color.opacity(0.25)).frame(width: size * 2, height: size * 2))
            .accessibilityHidden(true)
    }
}

/// The Mac's artwork (JPEG from Now Playing) or a gradient placeholder.
struct ArtworkView: View {
    let artwork: Data?
    var symbol = "music.note"
    var cornerRadius: CGFloat = 28

    var body: some View {
        Group {
            if let artwork, let image = UIImage(data: artwork) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Brand.gradient
                    .overlay {
                        GeometryReader { geometry in
                            Image(systemName: symbol)
                                .font(.system(size: geometry.size.width * 0.36, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.92))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
            }
        }
        .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Minimal line sparkline drawn with a Path (no axes).
struct Sparkline: View {
    let values: [Double]
    var color: Color = Brand.blue

    var body: some View {
        GeometryReader { geometry in
            let points = normalizedPoints(in: geometry.size)
            ZStack {
                if let first = points.first, let last = points.last {
                    Path { path in
                        path.move(to: CGPoint(x: first.x, y: geometry.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: last.x, y: geometry.size.height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                }
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    points.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }

    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        guard values.count > 1, let low = values.min(), let high = values.max() else { return [] }
        let span = max(high - low, 0.0001)
        let step = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            CGPoint(x: CGFloat(index) * step, y: size.height - CGFloat((value - low) / span) * (size.height - 4) - 2)
        }
    }
}

/// Horizontal stacked bar: jitter buffer / output (the network leg is not
/// measured on the phone).
struct DelayBar: View {
    let bufferMs: Int
    let outputMs: Int
    var height: CGFloat = 12

    static let bufferColor = Brand.cyan
    static let outputColor = Color.pink

    var body: some View {
        GeometryReader { geometry in
            let total = max(Double(bufferMs + outputMs), 1)
            let width = geometry.size.width - 3
            HStack(spacing: 3) {
                segment(Self.bufferColor, width * Double(bufferMs) / total)
                segment(Self.outputColor, width * Double(outputMs) / total)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Delay: buffer \(bufferMs) ms, output \(outputMs) ms")
    }

    private func segment(_ color: Color, _ width: CGFloat) -> some View {
        Capsule().fill(color.gradient).frame(width: max(width, height))
    }
}

struct DelayLegend: View {
    let bufferMs: Int
    let outputMs: Int

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            item(DelayBar.bufferColor, "Buffer", bufferMs)
            item(DelayBar.outputColor, "Output", outputMs)
        }
    }

    private func item(_ color: Color, _ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Text("\(value) ms")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Speaker button + slider + percentage for the active Mac's volume. The
/// slider keeps its own value while dragged so the Mac's echoes don't fight
/// the finger.
struct MacVolumeRow: View {
    @ObservedObject var sources: SourcesModel
    let sourceID: String
    let status: SourceStatus
    var showsPercent = true

    @State private var volume: Float = 1
    @State private var editing = false

    var body: some View {
        HStack(spacing: 12) {
            Button {
                sources.setMuted(!status.muted, for: sourceID)
            } label: {
                Image(systemName: status.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 28)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(status.muted ? "Unmute Mac" : "Mute Mac")
            Slider(value: $volume, in: 0...1) { isEditing in
                editing = isEditing
                if !isEditing { sources.setVolume(volume, for: sourceID) }
            }
            .onChange(of: volume) { _, newValue in
                if editing { sources.setVolume(newValue, for: sourceID) }
            }
            .accessibilityLabel("Mac volume")
            if showsPercent {
                Text("\(Int((volume * 100).rounded()))%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 42, alignment: .trailing)
            }
        }
        .onAppear { volume = status.volume }
        .onChange(of: status.volume) { _, newValue in
            if !editing { volume = newValue }
        }
    }
}

/// Quality picker for the active Mac (the requested quality; the WAN cap
/// note explains when the stream runs lower).
struct QualityPicker: View {
    @ObservedObject var sources: SourcesModel
    let sourceID: String
    let status: SourceStatus

    var body: some View {
        Picker(selection: Binding(get: { status.quality }, set: { sources.setQuality($0, for: sourceID) })) {
            ForEach(StreamQuality.allCases, id: \.self) { quality in
                Text(quality.menuName).tag(quality)
            }
        } label: {
            Label("Quality", systemImage: "dial.medium")
        }
        .pickerStyle(.menu)
    }
}

extension StreamQuality {
    /// Chip / segment label.
    var shortName: String {
        switch self {
        case .opus192: "Opus 192"
        case .opus128: "Opus 128"
        case .pcm: "PCM"
        }
    }

    /// Menu row: the name and what it costs.
    var menuName: String {
        switch self {
        case .opus192: "Opus 192 — best for Wi‑Fi"
        case .opus128: "Opus 128 — saves data"
        case .pcm: "PCM — uncompressed, Wi‑Fi only"
        }
    }
}

extension StreamPath {
    var symbol: String {
        switch self {
        case .local: "wifi"
        case .tailscaleDirect, .tailscale: "point.3.connected.trianglepath.dotted"
        case .tailscaleRelay: "arrow.triangle.branch"
        case .internet: "globe"
        }
    }

    /// One plain sentence on how the sound gets here.
    var explanation: String {
        switch self {
        case .local: "On this Wi‑Fi, straight from the Mac."
        case .tailscaleDirect: "Over the internet through a direct Tailscale link."
        case .tailscaleRelay: "Through a Tailscale relay. A bigger buffer keeps it from cutting out."
        case .tailscale: "Over the internet through Tailscale."
        case .internet: "Over the internet."
        }
    }
}

extension JitterLatencyMode {
    var symbol: String {
        switch self {
        case .low: "hare"
        case .balanced: "scalemass"
        case .safe: "tortoise"
        }
    }

    var shortExplanation: String {
        switch self {
        case .low: "Shortest delay, needs a strong network"
        case .balanced: "Grows only as much as the network needs"
        case .safe: "Never cuts out, a bit more delay"
        }
    }

    /// The buffer's starting target on `profile` (it grows from there when
    /// the network needs it).
    func minimumTargetMilliseconds(on profile: StreamProfile) -> Int {
        profile.jitterConfig(self).minTargetFrames * AudioFormat.frameDurationMs
    }
}

/// How the link is doing, from real recent counters.
struct LinkSummary {
    enum Health {
        case good, fair, poor

        var symbol: String {
            switch self {
            case .good: "checkmark.seal.fill"
            case .fair: "exclamationmark.triangle.fill"
            case .poor: "xmark.octagon.fill"
            }
        }

        var color: Color {
            switch self {
            case .good: .green
            case .fair: .orange
            case .poor: .red
            }
        }

        var verdict: String {
            switch self {
            case .good: "Excellent"
            case .fair: "Okay"
            case .poor: "Poor"
            }
        }
    }

    let health: Health
    let headline: String
    let explanation: String

    init(path: StreamPath, recentLossPercent: Double, recentRebuffers: Int) {
        if recentLossPercent >= 3 || recentRebuffers >= 2 {
            health = .poor
            headline = "Sound is breaking up"
        } else if recentLossPercent >= 0.5 || recentRebuffers >= 1 {
            health = .fair
            headline = "Playing, with some dropouts"
        } else if path == .tailscaleRelay {
            health = .fair
            headline = "Playing, with extra delay"
        } else {
            health = .good
            headline = "Streaming smoothly"
        }
        var text = path.explanation
        if recentLossPercent >= 0.5 {
            text += " " + String(format: "%.1f %% of packets lost in the last 10 s.", recentLossPercent)
        }
        explanation = text
    }
}

/// Status line for a Mac row (shared by Sources and the Now empty state).
enum SourcePresentation {
    static func detail(
        _ source: SourceArbiter.Source, isActive: Bool, isLastUsed: Bool, isIncompatible: Bool,
        remoteAddress: String?
    ) -> String {
        if !source.isOnline { return isLastUsed ? "Offline — last used" : "Offline" }
        if isIncompatible { return "Update Mac Audio Bridge (different version)" }
        guard source.connected, let status = source.status else { return "Connecting…" }
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

    static func isWarning(_ source: SourceArbiter.Source, isIncompatible: Bool) -> Bool {
        isIncompatible || source.status?.problem != nil
    }

    /// SF Symbol for a Mac from its name (no model identifier on the wire).
    static func symbol(for name: String) -> String {
        let lowered = name.lowercased()
        if lowered.contains("mini") { return "macmini" }
        if lowered.contains("studio") { return "macstudio" }
        if lowered.contains("imac") { return "desktopcomputer" }
        if lowered.contains("pro") && !lowered.contains("book") { return "macpro.gen3" }
        return "laptopcomputer"
    }
}

enum TimeFormat {
    /// "3:07" / "1:02:03".
    static func clock(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
