import SwiftUI

/// Variant C details: reads like a short report. Three plain-language
/// answers (where the delay goes, how the link is doing, how much data),
/// each with its number, then the raw counters as a tidy two-column table.
struct VariantCDetails: View {
    @ObservedObject var store: LabStore
    @State private var showsRaw = true
    @Environment(\.labScrollAnchor) private var scrollAnchor

    var body: some View {
        Group {
            if let link = store.link {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        verdict(link)
                        delaySection(link)
                        linkSection(link)
                        dataSection(link)
                        rawSection(link)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                }
                .defaultScrollAnchor(scrollAnchor)
            } else {
                ContentUnavailableView(
                    "Nothing to show yet", systemImage: "waveform.slash",
                    description: Text("Details appear while a Mac is playing to this iPhone."))
            }
        }
        .background(alignment: .top) {
            LinearGradient(
                colors: [LabBrand.indigo.opacity(0.22), LabBrand.cyan.opacity(0.08), .clear],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 420)
            .ignoresSafeArea()
        }
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: "stats.jsonl") {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share stats log")
            }
        }
    }

    private func verdict(_ link: LabLink) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: link.health.symbol)
                .font(.title)
                .foregroundStyle(link.health.color)
            VStack(alignment: .leading, spacing: 4) {
                Text(link.headline)
                    .font(.title3.bold())
                Text(link.explanation)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Sections

    private func delaySection(_ link: LabLink) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            question("Where do the \(link.breakdown.totalMs) ms go?")
            budgetRow(
                "Network",
                link.path == .wifi ? "Your Wi‑Fi, Mac to iPhone" : "5G and the Tailscale relay",
                link.breakdown.networkMs,
                link.breakdown.totalMs, LabLatencyBar.networkColor)
            budgetRow(
                "Safety buffer", "\(store.latency.title) mode — absorbs hiccups", link.breakdown.bufferMs,
                link.breakdown.totalMs, LabLatencyBar.bufferColor)
            budgetRow(
                link.route,
                link.route.hasPrefix("AirPods") ? "Bluetooth headphones add the most" : "Built-in output, almost instant",
                link.breakdown.outputMs,
                link.breakdown.totalMs, LabLatencyBar.outputColor)
        }
    }

    private func linkSection(_ link: LabLink) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            question("How is the connection?")
            fact(
                link.path.symbol, link.path.title, link.pathDetail)
            fact(
                "shippingbox", "\(LabFormat.percent(link.lossPercent)) of packets lost",
                "\(link.recovered) rebuilt from spare copies, \(link.concealed) gaps smoothed over",
                tint: link.lossPercent > 1 ? .orange : .green)
            fact(
                "waveform.path", String(format: "Arrives within %.0f ms", link.delayP95Ms),
                String(format: "Usually %.0f ms, jitter ±%.0f ms", link.delayP50Ms, link.jitterMs))
            LabSparkline(values: link.delayHistory, color: link.health == .excellent ? .green : .orange)
                .frame(height: 50)
                .padding(.leading, 40)
            fact("hifispeaker", "\(link.codec) \(link.bitrateKbps) kbit/s", store.quality == .pcm ? "Lossless" : "High-quality compressed audio")
        }
    }

    private func dataSection(_ link: LabLink) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            question("How much data?")
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                bigFigure(LabFormat.megabytes(link.dataUsedMB), "in \(link.sessionMinutes) min")
                bigFigure("≈ \(link.mbPerHour) MB", "per hour")
            }
            if link.path != .wifi {
                Text("On cellular the Mac switches to Opus 128 to stay under ~200 MB an hour.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func rawSection(_ link: LabLink) -> some View {
        DisclosureGroup(isExpanded: $showsRaw) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                rawRow("Target buffer", "\(link.targetMs) ms")
                rawRow("Delay p50 / p95 / p99", String(format: "%.0f / %.0f / %.0f ms", link.delayP50Ms, link.delayP95Ms, link.delayP99Ms))
                rawRow("Jitter", String(format: "%.1f ms", link.jitterMs))
                rawRow("Late", "\(link.late)")
                rawRow("Rebuffers / underruns", "\(link.rebuffers) / \(link.underruns)")
                rawRow("Recovered / concealed", "\(link.recovered) / \(link.concealed)")
                rawRow("Redundant received", link.redundantReceived.formatted())
                rawRow("Malformed / other Macs", "\(link.malformed) / \(link.foreignDropped)")
                rawRow("Engine restarts", "\(link.engineRestarts)")
            }
            .padding(.top, 12)
        } label: {
            Text("Raw counters")
                .font(.headline)
        }
        .padding(16)
        .labGlass(cornerRadius: 20)
    }

    // MARK: Pieces

    private func question(_ text: String) -> some View {
        Text(text)
            .font(.title2.bold())
            .accessibilityAddTraits(.isHeader)
    }

    private func budgetRow(_ title: String, _ subtitle: String, _ value: Int, _ total: Int, _ color: Color)
        -> some View
    {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(value) ms")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(color.gradient)
                        .frame(width: max(8, geometry.size.width * Double(value) / Double(max(total, 1))))
                }
            }
            .frame(height: 8)
        }
        .accessibilityElement(children: .combine)
    }

    private func fact(_ symbol: String, _ title: String, _ subtitle: String, tint: Color = .secondary) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func bigFigure(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(.title, design: .rounded).weight(.bold))
                .monospacedDigit()
            Text(caption).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func rawRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
                .gridColumnAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.subheadline)
    }
}
