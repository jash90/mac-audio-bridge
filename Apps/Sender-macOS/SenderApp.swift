import SwiftUI
import AppKit

@main
struct SenderApp: App {
    var body: some Scene {
        MenuBarExtra("Mac Audio Bridge", systemImage: "hifispeaker") {
            Text("Mac Audio Bridge")
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
