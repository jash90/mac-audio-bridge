import SwiftUI

@main
struct SenderApp: App {
    /// Created at app level, not in the menu content: MenuBarExtra's content
    /// view only exists while the menu is open, but the controller owns the
    /// 1 Hz state loop that must run from launch (see SenderController.init).
    @StateObject private var controller = SenderController()

    var body: some Scene {
        MenuBarExtra("Mac Audio Bridge", systemImage: "hifispeaker") {
            MenuView(controller: controller)
        }
        .menuBarExtraStyle(.window)
    }
}
