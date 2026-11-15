import Foundation

/// Sidebar destinations: one home per thing (design pass 2026-11-15). Settings, About, People and Help are not pages
/// any more: they are the Settings window (⌘,), the standard About panel, the People window and the Help window.
enum NavItem: String, Hashable {
    case overview         // how everything is doing (was Status)
    case coreBarPage      // Bar
    case vivoCube
    case controls         // KnobKey + DotKey
    case senseCube
    case barSystem        // the bar's software, home screen, screen and launcher (was in Settings)
    case apps             // Library
    case cubeCards        // (was Widgets)
    case screensavers
    case logs

    /// The page's window title.
    var title: String {
        switch self {
        case .overview: return "Overview"
        case .coreBarPage: return "CoreBar"
        case .vivoCube: return "VivoCube"
        case .controls: return "Controls"
        case .senseCube: return "SenseCube"
        case .barSystem: return "Bar System"
        case .apps: return "Apps"
        case .cubeCards: return "Cube Cards"
        case .screensavers: return "Screensavers"
        case .logs: return "Logs"
        }
    }

    /// One symbol per page, the same in the sidebar and wherever the page is linked (outline, no `.fill`).
    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .coreBarPage: return "rectangle.on.rectangle.angled"
        case .vivoCube: return "circle.circle"
        case .controls: return "dial.medium"
        case .senseCube: return "sensor"
        case .barSystem: return "cpu"
        case .apps: return "square.grid.2x2"
        case .cubeCards: return "square.on.square"
        case .screensavers: return "sparkles.tv"
        case .logs: return "doc.text.magnifyingglass"
        }
    }

    /// Pages that need a paired bar to show anything.
    var needsBar: Bool { [.coreBarPage, .vivoCube, .controls, .senseCube, .barSystem].contains(self) }
}
