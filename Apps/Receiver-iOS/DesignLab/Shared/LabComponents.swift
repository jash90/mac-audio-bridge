import SwiftUI

// Building blocks shared by the three DesignLab variants.

enum LabBrand {
    /// The app icon's indigo → cyan gradient.
    static let indigo = Color(red: 0.27, green: 0.22, blue: 0.87)
    static let blue = Color(red: 0.24, green: 0.42, blue: 0.92)
    static let cyan = Color(red: 0.09, green: 0.76, blue: 0.91)

    static var gradient: LinearGradient {
        LinearGradient(
            colors: [indigo, blue, cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension View {
    /// Liquid Glass on iOS 26+, a material card on older systems.
    @ViewBuilder
    func labGlass(cornerRadius: CGFloat = 24, tint: Color? = nil, interactive: Bool = false)
        -> some View
    {
        if #available(iOS 26.0, *) {
            self.glassEffect(
                interactive ? Glass.regular.tint(tint).interactive() : Glass.regular.tint(tint),
                in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial, in: .rect(cornerRadius: cornerRadius))
        }
    }

    /// Liquid Glass in a capsule / circle on iOS 26+.
    @ViewBuilder
    func labGlassCircle(tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(), in: .circle)
        } else {
            self.background(.regularMaterial, in: .circle)
        }
    }

    @ViewBuilder
    func labGlassCapsule(tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(), in: .capsule)
        } else {
            self.background(.regularMaterial, in: .capsule)
        }
    }

    /// A plain grouped card (no glass) for dense content.
    func labCard(cornerRadius: CGFloat = 20) -> some View {
        background(
            Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: cornerRadius))
    }
}

/// Glass button styles where available.
struct LabProminentButtonStyleModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

struct LabGlassButtonStyleModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

extension View {
    func labProminentButton() -> some View { modifier(LabProminentButtonStyleModifier()) }
    func labGlassButton() -> some View { modifier(LabGlassButtonStyleModifier()) }
}

/// Small coloured status dot with a soft halo.
struct LabStatusDot: View {
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

/// Segmented level meter (mic input).
struct LabLevelMeter: View {
    let level: Double
    var segments = 18
    var muted = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<segments, id: \.self) { index in
                let position = Double(index) / Double(segments - 1)
                Capsule()
                    .fill(color(at: position).opacity(position <= level && !muted ? 1 : 0.18))
            }
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityLabel("Microphone level")
        .accessibilityValue(muted ? "Muted" : "\(Int(level * 100)) percent")
    }

    private func color(at position: Double) -> Color {
        if position > 0.85 { return .red }
        if position > 0.65 { return .yellow }
        return .green
    }
}

/// Minimal line sparkline drawn with a Path (no axes).
struct LabSparkline: View {
    let values: [Double]
    var color: Color = .accentColor
    var filled = true

    var body: some View {
        GeometryReader { geometry in
            let points = normalizedPoints(in: geometry.size)
            ZStack {
                if filled, let first = points.first, let last = points.last {
                    Path { path in
                        path.move(to: CGPoint(x: first.x, y: geometry.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: last.x, y: geometry.size.height))
                        path.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.28), color.opacity(0)], startPoint: .top,
                            endPoint: .bottom))
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
            CGPoint(
                x: CGFloat(index) * step,
                y: size.height - CGFloat((value - low) / span) * (size.height - 4) - 2)
        }
    }
}

/// Horizontal stacked bar: network / buffer / output.
struct LabLatencyBar: View {
    let breakdown: LabLatencyBreakdown
    var height: CGFloat = 12

    static let networkColor = LabBrand.indigo
    static let bufferColor = LabBrand.cyan
    static let outputColor = Color.pink

    var body: some View {
        GeometryReader { geometry in
            let total = max(Double(breakdown.totalMs), 1)
            let spacing: CGFloat = 3
            let width = geometry.size.width - spacing * 2
            HStack(spacing: spacing) {
                segment(Self.networkColor, width * Double(breakdown.networkMs) / total)
                segment(Self.bufferColor, width * Double(breakdown.bufferMs) / total)
                segment(Self.outputColor, width * Double(breakdown.outputMs) / total)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(
            "Delay: network \(breakdown.networkMs) ms, buffer \(breakdown.bufferMs) ms, output \(breakdown.outputMs) ms"
        )
    }

    private func segment(_ color: Color, _ width: CGFloat) -> some View {
        Capsule().fill(color.gradient).frame(width: max(width, height))
    }
}

/// Legend row for the latency bar.
struct LabLatencyLegend: View {
    let breakdown: LabLatencyBreakdown

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            item(LabLatencyBar.networkColor, "Network", breakdown.networkMs)
            item(LabLatencyBar.bufferColor, "Buffer", breakdown.bufferMs)
            item(LabLatencyBar.outputColor, "Output", breakdown.outputMs)
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

/// Faux album art built from the brand gradient and an SF Symbol.
struct LabArtwork: View {
    let symbol: String
    var cornerRadius: CGFloat = 22
    var seed = 0

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: seed == 0
                        ? [Color(red: 0.93, green: 0.33, blue: 0.55), LabBrand.indigo, LabBrand.cyan]
                        : [Color(red: 0.98, green: 0.62, blue: 0.24), Color(red: 0.86, green: 0.25, blue: 0.4)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .overlay {
                GeometryReader { geometry in
                    Image(systemName: symbol)
                        .font(.system(size: geometry.size.width * 0.36, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .accessibilityHidden(true)
    }
}

/// previous / play-pause / next, sized by the caller.
struct LabTransport: View {
    @Binding var isPlaying: Bool
    var size: CGFloat = 30
    var glass = true
    var tint: Color = .primary

    var body: some View {
        HStack(spacing: size * 0.9) {
            button("backward.fill", label: "Previous", scale: 0.7) {}
            button(isPlaying ? "pause.fill" : "play.fill", label: isPlaying ? "Pause" : "Play", scale: 1) {
                isPlaying.toggle()
            }
            button("forward.fill", label: "Next", scale: 0.7) {}
        }
    }

    @ViewBuilder
    private func button(_ symbol: String, label: String, scale: CGFloat, action: @escaping () -> Void)
        -> some View
    {
        let diameter = size * (scale == 1 ? 2.2 : 1.7)
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * scale, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(tint)
                .frame(width: diameter, height: diameter)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .modifier(OptionalGlassCircle(enabled: glass))
        .accessibilityLabel(label)
    }
}

private struct OptionalGlassCircle: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled { content.labGlassCircle() } else { content }
    }
}

/// Section title used in scroll-based layouts.
struct LabSectionTitle: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.bold())
            Spacer()
            if let trailing {
                Text(trailing).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}
