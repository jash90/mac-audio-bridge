import AppKit
import SwiftUI

/// Menu bar window: receiver IP, output-device switcher, status. Streaming is
/// automatic — it runs while "iPhone (Mac Audio Bridge)" is the selected
/// output device and an address is set (see SenderController.evaluate). The
/// controller (created in SenderApp) owns the 1 Hz loop; this view owns no
/// timers and only reads published state.
struct MenuView: View {
    @AppStorage("receiverHost") private var host = ""
    @ObservedObject var controller: SenderController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mac Audio Bridge")
                .font(.headline)

            if !controller.driverInstalled {
                Text("Driver not installed — run: ./scripts/install-driver.sh")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            TextField("iPhone IP address", text: $host)
                .textFieldStyle(.roundedBorder)
                .disabled(controller.isStreaming)
                .onChange(of: host) { _, newValue in
                    controller.setHost(newValue)
                }

            if controller.defaultOutputIsOurs {
                Button("Switch back to \(controller.previousDeviceName ?? "previous device")") {
                    controller.switchBackToPreviousOutput()
                }
                .disabled(!controller.hasPreviousDevice)
            } else {
                Button("Use iPhone as output") {
                    controller.useIPhoneAsOutput()
                }
                .disabled(!controller.driverInstalled)
            }

            status

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 340)
    }

    @ViewBuilder
    private var status: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch controller.mode {
            case .streaming:
                Text("Streaming to \(controller.activeHost)")
                Text("Tap: \(Int(controller.tapSampleRate ?? 0)) Hz")
            case .waiting:
                Text(controller.receiverHostIsEmpty
                    ? "Waiting — enter the iPhone's IP address"
                    : "Waiting — select iPhone (Mac Audio Bridge) as output")
            }
            Text("Volume: \(controller.volumePercent)%\(controller.deviceMuted ? " (muted)" : "")")
            Text("Packets: \(controller.packetsPerSecond)/s")
            if let captureWarning = controller.captureWarning {
                Text(captureWarning)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failureMessage = controller.failureMessage {
                Text(failureMessage)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
