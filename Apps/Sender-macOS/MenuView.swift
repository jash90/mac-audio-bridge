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

            MicMenuSection(controller: controller)

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
        .onAppear { controller.setMenuOpen(true) }
        .onDisappear { controller.setMenuOpen(false) }
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
                Text(receiverLabel(name)).tag(Self.serviceTag(name))
            }
            if !controller.tailscalePeers.isEmpty || chosenHostIsCustom {
                Divider()
            }
            ForEach(controller.tailscalePeers, id: \.id) { peer in
                Text(peerLabel(peer)).tag(Self.hostTag(peerHost(peer)))
            }
            if chosenHostIsCustom, let host = controller.storedHost {
                Text("\(host) (address)").tag(Self.hostTag(host))
            }
        }
        .pickerStyle(.menu)
    }

    private static func serviceTag(_ name: String) -> String { "service:" + name }
    private static func hostTag(_ host: String) -> String { "host:" + host }

    private var selectionBinding: Binding<String> {
        Binding(
            get: {
                if let host = controller.storedHost { return Self.hostTag(host) }
                return controller.selectedReceiver.map(Self.serviceTag) ?? ""
            },
            set: { tag in
                if tag.hasPrefix("host:") {
                    controller.chooseHost(String(tag.dropFirst(5)))
                } else if tag.hasPrefix("service:") {
                    controller.selectReceiver(String(tag.dropFirst(8)))
                } else {
                    controller.selectReceiver(nil)
                }
            })
    }

    /// Visible receivers, receivers known by their tailnet addresses, plus
    /// the stored selection while it is missing, so the picker can always
    /// show (and change) the current choice.
    private var pickerNames: [String] {
        var names = controller.visibleReceivers
        for name in controller.remoteReceivers where !names.contains(name) {
            names.append(name)
        }
        if let selected = controller.selectedReceiver, !names.contains(selected) {
            names.append(selected)
        }
        return names
    }

    private func receiverLabel(_ name: String) -> String {
        if controller.visibleReceivers.contains(name) { return name }
        if controller.remoteReceivers.contains(name) { return "\(name) (via Tailscale)" }
        return "\(name) (not found)"
    }

    /// The address a Tailscale peer is reached at (its IPv4, else its name).
    private func peerHost(_ peer: TailscaleStatus.Peer) -> String {
        peer.preferredAddress ?? peer.name
    }

    private func peerLabel(_ peer: TailscaleStatus.Peer) -> String {
        let name = controller.receiverName(for: peer) ?? peer.name
        return "\(name) — via Tailscale, \(peer.online ? "online" : "offline")"
    }

    /// A chosen host that is not one of the listed Tailscale peers.
    private var chosenHostIsCustom: Bool {
        guard let host = controller.storedHost else { return false }
        return !controller.tailscalePeers.contains { peerHost($0) == host }
    }

    private var automaticLabel: String {
        if case .target(.service(let name), automatic: true) = controller.selectionStatus {
            return "Automatic (\(name))"
        }
        return "Automatic"
    }

    // MARK: - Quality picker

    /// The LAN quality and, separately, the Internet quality (used whenever
    /// the stream runs the Internet profile), each with what it costs. Both
    /// are persisted by the controller and can also be changed from the phone.
    @ViewBuilder
    private var qualityPicker: some View {
        Picker(
            "Quality",
            selection: Binding(get: { controller.quality }, set: { controller.setQuality($0) })
        ) {
            ForEach(StreamQuality.lanChoices, id: \.self) { quality in
                Text(quality.displayName).tag(quality)
            }
        }
        .pickerStyle(.menu)
        Picker(
            "Internet quality",
            selection: Binding(get: { controller.internetQuality }, set: { controller.setInternetQuality($0) })
        ) {
            ForEach(InternetQuality.allCases, id: \.self) { quality in
                Text(quality.menuName).tag(quality)
            }
        }
        .pickerStyle(.menu)
    }

    // MARK: - Manual address

    /// An iPhone by address: an IP (LAN or Tailscale) or a host name such
    /// as a Tailscale MagicDNS name (`iphone171`). "Use this address" picks
    /// it even while receivers are found on Wi-Fi; typed alone, it is the
    /// fallback used when no discovered receiver is selected.
    private var manualAddress: some View {
        DisclosureGroup(isExpanded: $manualSectionExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    TextField("IP address or Tailscale name", text: $manualHostText)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: manualHostText) { _, newValue in
                            controller.setManualHost(newValue)
                        }
                        .onSubmit { useManualAddress() }
                    Button("Use") { useManualAddress() }
                        .disabled(manualHostText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Use streams to this address even when receivers are found on Wi-Fi (e.g. iphone171 over Tailscale).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if controller.storedHost != nil {
                    Button("Back to receivers on Wi-Fi") { controller.chooseHost(nil) }
                        .font(.caption)
                }
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

    private func useManualAddress() {
        let host = manualHostText.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        controller.chooseHost(host)
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
            tailscaleStatus
            if controller.isStreaming {
                Text("\(controller.streamProfile.encoding(lan: controller.quality, internet: controller.internetQuality).displayName) — \(String(format: "%.0f", controller.kilobytesPerSecond)) kB/s")
                internetStatus
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

    /// Path, profile and data use of the running stream.
    @ViewBuilder
    private var internetStatus: some View {
        let endpoint = controller.endpointName
        Text("Path: \(controller.streamPath.displayName)\(endpoint.isEmpty || endpoint == controller.activeReceiver ? "" : " (\(endpoint))")")
        if controller.streamProfile == .wan {
            Text("Internet profile: 20 ms Opus frames, 24 kbit/s backup copies, larger buffer")
        }
        if let note = controller.qualityNote {
            Text(note)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        Text("Data: \(String(format: "%.1f", controller.sessionMegabytes)) MB this session, ≈ \(String(format: "%.0f", controller.megabytesPerHour)) MB/h")
    }

    @ViewBuilder
    private var tailscaleStatus: some View {
        switch controller.tailscaleState {
        case .running:
            Text("Tailscale: on — \(controller.tailscalePeers.filter(\.online).count) of \(controller.tailscalePeers.count) iPhones online")
        case .notRunning(let reason):
            Text("Tailscale: \(reason)")
                .foregroundStyle(.secondary)
        case .notInstalled, .unknown:
            EmptyView()
        }
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
