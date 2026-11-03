import Foundation

/// Sidebar destinations, grouped by what the user wants to change
/// (Screens / Controls / Sensors / Library / Health) — not by protocol.
enum NavItem: Hashable {
    case coreBarPage      // Screens
    case vivoCube
    case knobKey          // Controls
    case dotKey
    case senseCube        // Sensors
    case widgets          // Library
    case people
    case status           // Health
    case logs
    case settings         // Deckhand
    case about
}
