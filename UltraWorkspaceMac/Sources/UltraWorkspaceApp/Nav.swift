import Foundation

/// What the sidebar has selected / which detail view is shown.
enum NavItem: Hashable {
    case coreBar
    case module(String)   // module serial
    case addons
    case people
    case logs
}
