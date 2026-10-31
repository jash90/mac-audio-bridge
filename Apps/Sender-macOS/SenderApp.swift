import SwiftUI

@main
struct SenderApp: App {
    var body: some Scene {
        MenuBarExtra("Mac Audio Bridge", systemImage: "hifispeaker") {
            MenuView()
        }
        .menuBarExtraStyle(.window)
    }
}
