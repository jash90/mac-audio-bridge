import SwiftUI

@main
struct ReceiverApp: App {
    var body: some Scene {
        WindowGroup {
            // DesignLab mockups (`-DesignLab A|B|C`); the real UI otherwise.
            if let designLab = DesignLabLaunch.current {
                DesignLabRoot(launch: designLab)
            } else {
                ContentView()
            }
        }
    }
}
