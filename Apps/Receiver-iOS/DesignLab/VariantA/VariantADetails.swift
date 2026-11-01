import SwiftUI

/// Variant A details: a calm, native grouped list. A summary header that
/// answers "is it fine?", then "where does the delay come from", then the
/// raw numbers grouped by what they mean (network, audio, data, engine).
struct VariantADetails: View {
    @ObservedObject var store: LabStore
    @Environment(\.labScrollAnchor) private var scrollAnchor

    var body: some View {
        Group {
            if let link = store.link {
                content(link)
            } else {
                ContentUnavailableView(
                    "No Mac connected", systemImage: "waveform.slash",
                    description: Text("Details appear while a Mac is playing to this iPhone."))
            }
        }
        .navigationTitle("Details")
    }

    private func content(_ link: LabLink) -> some View {
        List {
            Section {
                summary(link)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(link.breakdown.totalMs)")
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))
                            .monospacedDigit()
                        Text("ms from Mac to your ears")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    LabLatencyBar(breakdown: link.breakdown)
                    LabLatencyLegend(breakdown: link.breakdown)
                }
                .padding(.vertical, 6)
                row("Delay setting", "\(store.latency.title) · target \(link.targetMs) ms")
            } header: {
                Text("Delay")
            } footer: {
                Text(
                    link.breakdown.outputMs > 100
                        ? "Most of the delay is the Bluetooth link to \(link.route). Wired or speaker output is faster."
                        : "Most of the delay is the buffer that smooths out the cellular connection.")
            }

            Section("Network") {
                row("Path", link.path.title, symbol: link.path.symbol)
                row("Route", link.pathDetail)
                row("Jitter", String(format: "%.1f ms", link.jitterMs))
                row(
                    "Packet delay",
                    String(format: "%.0f / %.0f / %.0f ms", link.delayP50Ms, link.delayP95Ms, link.delayP99Ms),
                    caption: "typical / p95 / p99")
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Last 40 seconds")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "p95 %.0f ms", link.delayP95Ms))
                            .monospacedDigit()
                    }
                    .font(.footnote)
                    LabSparkline(
                        values: link.delayHistory, color: link.health == .excellent ? .green : .orange)
                        .frame(height: 44)
                }
                .padding(.vertical, 4)
            }

            Section("Packets") {
                row("Lost", LabFormat.percent(link.lossPercent), tint: link.lossPercent > 1 ? .orange : nil)
                row("Recovered", "\(link.recovered)", caption: "rebuilt from redundancy")
                row("Filled in", "\(link.concealed) × 5 ms", caption: "hidden gaps")
                row("Late", "\(link.late)")
                row("Rebuffers", "\(link.rebuffers)")
                row("Underruns", "\(link.underruns)")
            }

            Section("Audio") {
                row("Codec", "\(link.codec) \(link.bitrateKbps) kbit/s")
                row("Output", link.route, symbol: link.route.hasPrefix("AirPods") ? "airpodspro" : "iphone")
                row("Audio engine", link.engineRestarts == 0 ? "Running" : "Running · \(link.engineRestarts) restart")
            }

            Section("Data") {
                row("This session", LabFormat.megabytes(link.dataUsedMB), caption: "\(link.sessionMinutes) min")
                row("Rate", "≈ \(link.mbPerHour) MB/h")
            }

            Section {
                row("Malformed", "\(link.malformed)")
                row("Other Macs (dropped)", "\(link.foreignDropped)")
                row("Redundant copies", link.redundantReceived.formatted())
                Button {
                } label: {
                    Label("Share stats log", systemImage: "square.and.arrow.up")
                }
            } header: {
                Text("Advanced")
            }
        }
        .listStyle(.insetGrouped)
        .defaultScrollAnchor(scrollAnchor)
    }

    private func summary(_ link: LabLink) -> some View {
        HStack(spacing: 14) {
            Image(systemName: link.health.symbol)
                .font(.largeTitle)
                .foregroundStyle(link.health.color)
            VStack(alignment: .leading, spacing: 3) {
                Text(link.health.title)
                    .font(.title2.bold())
                Text(link.explanation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .labGlass(cornerRadius: 24, tint: link.health.color.opacity(0.12))
    }

    private func row(
        _ label: String, _ value: String, symbol: String? = nil, caption: String? = nil, tint: Color? = nil
    ) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).foregroundStyle(.secondary)
                }
                Text(value)
                    .monospacedDigit()
                    .foregroundStyle(tint ?? .primary)
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                if let caption {
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
