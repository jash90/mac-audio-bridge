import Charts
import SwiftUI

/// Variant B details: an instrument panel. Live charts for packet delay and
/// loss on top, the delay budget, then every raw counter as a compact
/// spec-sheet grid grouped by subsystem.
struct VariantBDetails: View {
    @ObservedObject var store: LabStore
    @Environment(\.labScrollAnchor) private var scrollAnchor

    private let columns = [
        GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        Group {
            if let link = store.link {
                ScrollView {
                    VStack(spacing: 12) {
                        delayChart(link)
                        budget(link)
                        group("Network", symbol: "network", items: [
                            ("Path", link.path.title), ("Jitter", String(format: "%.1f ms", link.jitterMs)),
                            ("p50", String(format: "%.0f ms", link.delayP50Ms)),
                            ("p95", String(format: "%.0f ms", link.delayP95Ms)),
                            ("p99", String(format: "%.0f ms", link.delayP99Ms)),
                            ("Late", "\(link.late)"),
                        ])
                        group("Packets", symbol: "shippingbox", items: [
                            ("Lost", LabFormat.percent(link.lossPercent)), ("Recovered", "\(link.recovered)"),
                            ("Concealed", "\(link.concealed)"), ("Rebuffers", "\(link.rebuffers)"),
                            ("Underruns", "\(link.underruns)"), ("Malformed", "\(link.malformed)"),
                        ])
                        group("Audio", symbol: "hifispeaker", items: [
                            ("Codec", "\(link.codec) \(link.bitrateKbps)"), ("Frame", "5 ms"),
                            ("Output", link.route), ("Engine", link.engineRestarts == 0 ? "OK" : "\(link.engineRestarts) restart"),
                            ("Other Macs", "\(link.foreignDropped)"),
                            ("Redundant", link.redundantReceived.formatted(.number.notation(.compactName))),
                        ])
                        group("Data", symbol: "chart.bar", items: [
                            ("Session", LabFormat.megabytes(link.dataUsedMB)), ("Rate", "\(link.mbPerHour) MB/h"),
                            ("Time", "\(link.sessionMinutes) min"),
                        ])
                        Text(link.pathDetail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .defaultScrollAnchor(scrollAnchor)
                .background(Color(uiColor: .systemGroupedBackground))
            } else {
                ContentUnavailableView(
                    "No live data", systemImage: "chart.xyaxis.line",
                    description: Text("Connect a Mac to see live link metrics."))
            }
        }
        .navigationTitle("Details")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share stats log")
            }
        }
    }

    private func delayChart(_ link: LabLink) -> some View {
        let color: Color = link.health == .excellent ? LabBrand.blue : .orange
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("PACKET DELAY", systemImage: "waveform.path.ecg")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(color)
                Spacer()
                Text("last 40 s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Chart {
                ForEach(Array(link.delayHistory.enumerated()), id: \.offset) { index, value in
                    AreaMark(x: .value("Second", index), y: .value("Delay", value))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [color.opacity(0.3), color.opacity(0)], startPoint: .top,
                                endPoint: .bottom))
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("Second", index), y: .value("Delay", value))
                        .foregroundStyle(color)
                        .interpolationMethod(.catmullRom)
                }
                RuleMark(y: .value("Buffer", Double(link.targetMs)))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("buffer \(link.targetMs) ms")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) {
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .frame(height: 130)

            Chart {
                ForEach(Array(link.lossHistory.enumerated()), id: \.offset) { index, value in
                    BarMark(x: .value("Second", index), y: .value("Loss", value))
                        .foregroundStyle(value > 3 ? Color.red : value > 0 ? Color.orange : Color.green)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...8)
            .frame(height: 32)
            HStack {
                Text("Loss per second")
                Spacer()
                Text("\(LabFormat.percent(link.lossPercent)) avg").monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .labCard(cornerRadius: 22)
    }

    private func budget(_ link: LabLink) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("DELAY BUDGET", systemImage: "timer")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(LabBrand.blue)
                Spacer()
                VariantBBigNumber(value: "\(link.breakdown.totalMs)", unit: "ms")
            }
            LabLatencyBar(breakdown: link.breakdown, height: 14)
            LabLatencyLegend(breakdown: link.breakdown)
        }
        .padding(14)
        .labCard(cornerRadius: 22)
    }

    private func group(_ title: String, symbol: String, items: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title.uppercased(), systemImage: symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(items, id: \.0) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.0)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(item.1)
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 12))
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(14)
        .labCard(cornerRadius: 22)
    }
}
