import BridgeCore
import SwiftUI

/// The bottom tab bar's tabs.
enum AppTab: Hashable {
    case now, sources, details, settings
}

/// The app: Now · Sources · Details · Settings in the system tab bar
/// (Liquid Glass on iOS 26). Owns the receiver model and starts it.
struct RootView: View {
    @StateObject private var model = ReceiverModel()
    @AppStorage("latencyMode") private var latencyMode: JitterLatencyMode = .balanced
    @State private var tab: AppTab = .now

    var body: some View {
        TabView(selection: $tab) {
            Tab("Now", systemImage: "play.circle.fill", value: AppTab.now) {
                NowView(model: model, sources: model.sources, tab: $tab)
            }
            Tab("Sources", systemImage: "laptopcomputer.and.iphone", value: AppTab.sources) {
                NavigationStack {
                    SourcesList(sources: model.sources)
                        .navigationTitle("Sources")
                }
            }
            Tab("Details", systemImage: "waveform.path.ecg", value: AppTab.details) {
                NavigationStack {
                    DetailsView(model: model, sources: model.sources)
                }
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                NavigationStack {
                    SettingsView(model: model, sources: model.sources, latencyMode: $latencyMode)
                }
            }
        }
        .tint(Brand.blue)
        .task {
            model.setLatencyMode(latencyMode)
            model.start()
        }
        .onChange(of: latencyMode) { _, mode in
            model.setLatencyMode(mode)
        }
    }
}
