import BridgeCore
import SwiftUI

/// The Details tab: a calm grouped list — a verdict, where the delay comes
/// from, then network, packets, audio, data and this iPhone.
struct DetailsView: View {
    @ObservedObject var model: ReceiverModel
    @ObservedObject var sources: SourcesModel
    @ObservedObject private var advertisement = ReceiverAdvertisement.shared

    var body: some View {
        List {
            summary

            Section {
                if model.streamPath == nil {
                    Text("Shows where the delay comes from once sound arrives.")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("≈ \(model.totalMilliseconds)")
                                .font(.system(size: 40, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            Text("ms on this iPhone")
                                .foregroundStyle(.secondary)
                        }
                        DelayBar(bufferMs: model.bufferMilliseconds, outputMs: model.outputMilliseconds)
                        DelayLegend(bufferMs: model.bufferMilliseconds, outputMs: model.outputMilliseconds)
                    }
                    .padding(.vertical, 6)
                }
                row("Buffer target", "\(model.targetMilliseconds) ms")
                row("Delay setting", model.latencyMode.displayName)
            } header: {
                Text("Delay")
            } footer: {
                Text(delayFooter)
            }

            Section("Network") {
                row("Path", model.streamPath?.displayName ?? "—", symbol: model.streamPath?.symbol)
                row("Profile", model.streamProfile.displayName)
                if model.streamPath != nil {
                    row("Jitter", String(format: "%.1f ms", model.jitterMilliseconds))
                    row(
                        "Packet delay",
                        String(
                            format: "%.0f / %.0f / %.0f ms", model.delayP50Milliseconds, model.delayP95Milliseconds,
                            model.delayP99Milliseconds),
                        caption: "typical / p95 / p99")
                }
                if model.streamPath != nil, model.delayHistory.count > 1 {
                    VStack(alignment: .leading, spacing: 6) {
                        Sparkline(values: model.delayHistory)
                            .frame(height: 44)
                        HStack {
                            Text("Last \(model.delayHistory.count) seconds")
                            Spacer()
                            Text(String(format: "p95 %.0f ms", model.delayHistory.last ?? 0))
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Packets") {
                row("Lost", String(format: "%.1f %%", model.lostPercent), caption: "this session")
                row("Lost, last 10 s", String(format: "%.1f %%", model.recentLossPercent))
                row("Recovered", "\(model.recoveredCount)", caption: "rebuilt from spare copies")
                row("Concealed", "\(model.concealedCount * AudioFormat.frameDurationMs) ms", caption: "smoothed over")
                row("Late", "\(model.lateCount)")
                row("Rebuffers", "\(model.rebufferCount)")
                row("Underruns", "\(model.underrunCount)")
            }

            Section {
                row("Codec", model.codecDescription ?? "—")
                if let note = sources.active?.status?.qualityNote {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                row("Output", model.outputRoute ?? "—")
                row("Output latency", "\(model.outputMilliseconds) ms")
            } header: {
                Text("Audio")
            }

            Section("Data") {
                row("This session", String(format: "%.1f MB", model.sessionMegabytes))
                row("Rate", "≈ \(Int(model.megabytesPerHour.rounded())) MB/h")
            }

            Section {
                row("Visible as", advertisement.registeredName ?? "—")
                row("Address", "\(model.ipAddress ?? "no Wi‑Fi address") · UDP \(advertisement.port.map(String.init) ?? "—")")
                row("Network", sources.network.network + (sources.network.isExpensive ? " (metered)" : ""))
                DisclosureGroup("Advanced") {
                    row("Malformed", "\(model.malformedCount)")
                    row("Other Macs (dropped)", "\(model.foreignCount)")
                    row("Audio engine", "\(model.engineRunning ? "running" : "stopped") · restarts \(model.engineRestarts)")
                }
            } header: {
                Text("This iPhone")
            } footer: {
                if case .localNetworkDenied = advertisement.status {
                    Text("Local Network access is off: your Mac can't find this iPhone. Turn on Mac Audio Bridge in Settings → Privacy & Security → Local Network.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Details")
    }

    @ViewBuilder
    private var summary: some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: verdict.symbol)
                    .font(.largeTitle)
                    .foregroundStyle(verdict.color)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verdict.title)
                        .font(.title2.bold())
                    Text(verdict.text)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 6)
            .listRowBackground(verdict.color.opacity(0.14))
        }
    }

    private var verdict: (symbol: String, color: Color, title: String, text: String) {
        guard let path = model.streamPath else {
            if sources.active == nil {
                return ("pause.circle.fill", .secondary, "Not streaming", "Pick a Mac in Sources to start.")
            }
            return ("speaker.zzz.fill", .secondary, "Waiting for sound", "The Mac streams as soon as something plays.")
        }
        let summary = LinkSummary(
            path: path, recentLossPercent: model.recentLossPercent, recentRebuffers: model.recentRebuffers)
        return (summary.health.symbol, summary.health.color, summary.health.verdict, summary.explanation)
    }

    private var delayFooter: String {
        let output = model.outputRoute.map { "Output is \($0)." } ?? ""
        return "From sound arriving on the iPhone to your ears; the network leg comes on top. \(output) Bluetooth headphones add the most."
    }

    private func row(_ label: String, _ value: String, caption: String? = nil, symbol: String? = nil) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
