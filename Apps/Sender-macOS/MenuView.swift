import AppKit
import Combine
import SwiftUI

/// Menu bar window: receiver IP, start/stop toggle, status.
struct MenuView: View {
    @AppStorage("receiverHost") private var host = ""
    @StateObject private var controller = SenderController()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mac Audio Bridge")
                .font(.headline)

            TextField("iPhone IP address", text: $host)
                .textFieldStyle(.roundedBorder)
                .disabled(controller.isRunning)

            Button(controller.isRunning ? "Stop" : "Start") {
                controller.toggle(host: host)
            }
            .keyboardShortcut(.return)

            status

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 320)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            controller.refreshStats()
        }
    }

    @ViewBuilder
    private var status: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch controller.phase {
            case .idle:
                Text("State: idle")
            case .running:
                Text("State: streaming")
                Text("Tap: \(Int(controller.tapSampleRate ?? 0)) Hz")
                Text("Packets: \(controller.packetsPerSecond)/s")
                Text("Seq: \(controller.currentSequence)")
                if let captureWarning = controller.captureWarning {
                    Text(captureWarning)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .failed(let message):
                Text("State: error")
                    .foregroundStyle(.red)
                Text(message)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
