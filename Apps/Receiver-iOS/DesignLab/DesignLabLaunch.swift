import SwiftUI

/// Launch configuration for the DesignLab mockups. Launch arguments become
/// UserDefaults entries (`-DesignLab A` → "DesignLab" = "A"), so:
///
///     -DesignLab <A|B|C> [-DesignState <wifi|cellular|idle>]
///                        [-DesignScreen <home|sources|details|settings>]
///                        [-DesignAppearance <light|dark>]
///                        [-DesignScroll end]   (home/details open scrolled to the bottom)
///
/// Without `-DesignLab` the real app runs untouched.
struct DesignLabLaunch: Sendable {
    enum Variant: String, Sendable {
        case a = "A"
        case b = "B"
        case c = "C"
    }

    let variant: Variant
    let scenario: LabScenario
    let screen: LabScreen
    let colorScheme: ColorScheme?
    let scrolledToEnd: Bool

    static var current: DesignLabLaunch? {
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: "DesignLab")?.uppercased(),
            let variant = Variant(rawValue: raw)
        else { return nil }
        let scenario = defaults.string(forKey: "DesignState").flatMap(LabScenario.init) ?? .wifi
        let screen = defaults.string(forKey: "DesignScreen").flatMap(LabScreen.init) ?? .home
        let colorScheme: ColorScheme? =
            switch defaults.string(forKey: "DesignAppearance") {
            case "dark": .dark
            case "light": .light
            default: nil
            }
        return DesignLabLaunch(
            variant: variant, scenario: scenario, screen: screen, colorScheme: colorScheme,
            scrolledToEnd: defaults.string(forKey: "DesignScroll") == "end")
    }
}

/// Root of a DesignLab run.
struct DesignLabRoot: View {
    let launch: DesignLabLaunch
    @StateObject private var store: LabStore

    init(launch: DesignLabLaunch) {
        self.launch = launch
        _store = StateObject(wrappedValue: LabStore(scenario: launch.scenario))
    }

    var body: some View {
        Group {
            switch launch.variant {
            case .a: VariantAHome(store: store, initialScreen: launch.screen)
            case .b: VariantBRoot(store: store, initialScreen: launch.screen)
            case .c: VariantCRoot(store: store, initialScreen: launch.screen)
            }
        }
        .tint(LabBrand.blue)
        .preferredColorScheme(launch.colorScheme)
        .environment(\.labScrollAnchor, launch.scrolledToEnd ? .bottom : .top)
    }
}

extension EnvironmentValues {
    /// Where scrollable home screens start (screenshots of the lower half).
    @Entry var labScrollAnchor: UnitPoint = .top
}
