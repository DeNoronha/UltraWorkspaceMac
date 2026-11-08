import AppKit
import SwiftUI
import UltraBarKit

/// Where Deckhand shows itself on the Mac: the Dock, the menu bar, or both (Settings → Deckhand on this Mac).
/// Kept in UserDefaults rather than AppSettings because the app needs it before any window exists.
enum MacPresence: String, CaseIterable, Identifiable {
    case dock, menuBar, both
    static let key = "macPresence"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dock: return "Dock"
        case .menuBar: return "Menu bar"
        case .both: return "Dock and menu bar"
        }
    }
    var showsDockIcon: Bool { self != .menuBar }
    var showsMenuBarIcon: Bool { self != .dock }

    static var current: MacPresence { MacPresence(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .dock }

    /// Shows or hides the Dock icon. Hiding it makes Deckhand an accessory app: no Dock icon and no app menu,
    /// but its windows stay open, so the window is brought back to the front after the switch.
    @MainActor static func applyDockIcon(_ p: MacPresence = .current) {
        let policy: NSApplication.ActivationPolicy = p.showsDockIcon ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Sets the Dock icon before the first window appears, so a menu-bar-only Deckhand never flashes one in the Dock.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        if !MacPresence.current.showsDockIcon { NSApp.setActivationPolicy(.accessory) }
    }
    /// Without a Dock icon, closing the window must not quit Deckhand: the menu bar icon reopens it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// The menu under Deckhand's menu bar icon.
struct MenuBarMenu: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(barLine)
        Divider()
        Button("Open Deckhand") { openMain() }
            .keyboardShortcut("o")
        Button("Settings…") { model.nav = .settings; openMain() }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Deckhand") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var barLine: String {
        guard let s = model.selectedSerial else { return "No bar selected" }
        let name = model.paired.first { $0.serialNo == s }?.name ?? "CoreBar"
        switch model.link {
        case .connected: return "\(name): connected"
        case .connecting: return "\(name): connecting…"
        case .reconnecting: return "\(name): reconnecting…"
        case .stopped: return "\(name): not connected"
        }
    }

    /// Brings the existing Deckhand window forward, or opens one when it was closed.
    private func openMain() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(MainWindow.id) == true && $0.canBecomeMain }) {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: MainWindow.id)
        }
    }
}

enum MainWindow { static let id = "main" }
