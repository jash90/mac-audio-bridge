import AppKit
import BridgeCore
import SwiftUI

/// Menu bar window: receiver picker, stream-quality picker, output-device
/// switcher, status, and a manual-address fallback. Streaming is automatic — it runs while
/// "iPhone (Mac Audio Bridge)" is the selected output device and a receiver
/// is known (see SenderController.evaluate). The controller (created in
/// SenderApp) owns the 1 Hz loop and the Bonjour browser; this view owns no
/// timers and only reads published state.
struct MenuView: View {
    @ObservedObject var controller: SenderController
    /// Text-field mirror of the manual host (persisted by the controller
    /// under the same `receiverHost` key).
    @AppStorage("receiverHost") private var manualHostText = ""
    /// Codec / bitrate choice, persisted; the controller reads the same key
    /// at launch and applies changes live.
    @AppStorage(SenderController.qualityKey) private var quality = StreamQuality.default
    @State private var manualSectionExpanded = false

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

            receiverPicker

            qualityPicker

            remoteStatus

            MediaMenuSection(media: controller.media)

            if controller.defaultOutputIsOurs {
                if controller.releasedHold {
                    Button("Resume streaming to iPhone") {
                        controller.resumeAfterRelease()
                    }
                }
                Button("Switch back to \(controller.previousDeviceName ?? "built-in output")") {
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

            manualAddress

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 340)
    }

    // MARK: - Remote control

    /// Who controls the stream: a phone, or another Mac that took it over.
    @ViewBuilder
    private var remoteStatus: some View {
        if let phone = controller.controllingPhone, controller.isStreaming {
            Label("Controlled from \(phone)", systemImage: "iphone.radiowaves.left.and.right")
                .font(.footnote)
                .foregroundStyle(.green)
        }
        if let other = controller.usedBy {
            Label("iPhone used by \(other)", systemImage: "arrow.left.arrow.right")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
        switch controller.controlServerStatus {
        case .localNetworkDenied:
            Text("The iPhone cannot find this Mac — allow Local Network for Mac Audio Bridge in System Settings")
                .font(.footnote)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Text("Remote control unavailable: \(message)")
                .font(.footnote)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .starting, .advertising:
            EmptyView()
        }
    }

    // MARK: - Receiver picker

    private var receiverPicker: some View {
        Picker("Receiver", selection: selectionBinding) {
            Text(automaticLabel).tag("")
            ForEach(pickerNames, id: \.self) { name in
                Text(controller.visibleReceivers.contains(name) ? name : "\(name) (not found)")
                    .tag(name)
            }
        }
        .pickerStyle(.menu)
    }

    private var selectionBinding: Binding<String> {
        Binding(
            get: { controller.selectedReceiver ?? "" },
            set: { controller.selectReceiver($0.isEmpty ? nil : $0) })
    }

    /// Visible receivers plus the stored selection while it is missing, so
    /// the picker can always show (and change) the current choice.
    private var pickerNames: [String] {
        var names = controller.visibleReceivers
        if let selected = controller.selectedReceiver, !names.contains(selected) {
            names.append(selected)
        }
        return names
    }

    private var automaticLabel: String {
        if case .target(.service(let name), automatic: true) = controller.selectionStatus {
            return "Automatic (\(name))"
        }
        return "Automatic"
    }

    // MARK: - Quality picker

    private var qualityPicker: some View {
        Picker("Quality", selection: $quality) {
            ForEach(StreamQuality.allCases, id: \.self) { quality in
                Text(quality.displayName).tag(quality)
            }
        }
        .pickerStyle(.menu)
        .onChange(of: quality) { _, newQuality in
            controller.setQuality(newQuality)
        }
    }

    // MARK: - Manual address

    /// Fallback for networks where Bonjour does not get through. Used only
    /// when no discovered receiver is selected; always editable.
    private var manualAddress: some View {
        DisclosureGroup(isExpanded: $manualSectionExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("iPhone IP address", text: $manualHostText)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: manualHostText) { _, newValue in
                        controller.setManualHost(newValue)
                    }
                Text("Used only when no discovered receiver is selected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        } label: {
            Text(manualAddressInUse ? "Manual address (in use)" : "Manual address")
                .font(.footnote)
        }
        .onChange(of: manualSectionExpanded) { _, expanded in
            if expanded {
                controller.enableManualAddress()
            }
        }
    }

    private var manualAddressInUse: Bool {
        if case .target(.host, _) = controller.selectionStatus { return true }
        return false
    }

    // MARK: - Status

    @ViewBuilder
    private var status: some View {
        VStack(alignment: .leading, spacing: 3) {
            receiverStatus
            switch controller.mode {
            case .streaming:
                Text("Streaming to \(controller.activeReceiver)")
                Text("Tap: \(Int(controller.tapSampleRate ?? 0)) Hz")
            case .waiting:
                if controller.selectionStatus.hasTarget {
                    Text("Waiting — select iPhone (Mac Audio Bridge) as output")
                }
            }
            Text("Volume: \(controller.volumePercent)%\(controller.deviceMuted ? " (muted)" : "")")
            Text("Packets: \(controller.packetsPerSecond)/s")
            if controller.isStreaming {
                Text("\(controller.quality.displayName) — \(String(format: "%.0f", controller.kilobytesPerSecond)) kB/s")
            }
            if controller.browserStatus == .localNetworkDenied {
                Text("Local Network access is off — allow Mac Audio Bridge in System Settings → Privacy & Security → Local Network")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

    /// One line on where the audio goes and whether the receiver answers.
    @ViewBuilder
    private var receiverStatus: some View {
        switch controller.selectionStatus {
        case .noReceiver:
            Text("Looking for receivers — open Mac Audio Bridge on the iPhone (same Wi-Fi)")
                .fixedSize(horizontal: false, vertical: true)
        case .chooseReceiver(let count):
            Text("\(count) receivers found — choose one above")
        case .looking(let name):
            Text("Looking for \(name)…")
                .foregroundStyle(.orange)
        case .target(let target, _):
            if controller.isStreaming {
                linkStatus(name: target.displayName)
            } else {
                Text("Receiver: \(target.displayName)")
            }
        }
    }

    @ViewBuilder
    private func linkStatus(name: String) -> some View {
        switch controller.link {
        case .alive:
            Text("Connected (keepalive OK)")
                .foregroundStyle(.green)
        case .noResponse:
            Text("No response from \(name) — reconnecting")
                .foregroundStyle(.orange)
        case .idle:
            Text("Connected — no audio playing")
        case .connecting, nil:
            Text("Connecting to \(name)…")
        }
    }
}

private extension ReceiverSelection.Status {
    var hasTarget: Bool {
        if case .target = self { return true }
        return false
    }
}
