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

/// The app icon's bar (knob, three screen tiles, cube, slider) as a single-colour template image for the menu bar,
/// so macOS tints it for light and dark menu bars like every other menu bar icon.
enum MenuBarIcon {
    static let image: NSImage = {
        let size = NSSize(width: 30, height: 16)
        let img = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            // The bar's outline.
            let bar = NSBezierPath(roundedRect: NSRect(x: 0.75, y: 2.75, width: 28.5, height: 10.5), xRadius: 3.5, yRadius: 3.5)
            bar.lineWidth = 1.5
            bar.stroke()
            // Knob: a ring.
            let knob = NSBezierPath(ovalIn: NSRect(x: 3, y: 5, width: 6, height: 6))
            knob.appendOval(in: NSRect(x: 4.75, y: 6.75, width: 2.5, height: 2.5))
            knob.windingRule = .evenOdd
            knob.fill()
            // Screen: three tiles.
            for i in 0..<3 {
                NSBezierPath(roundedRect: NSRect(x: 10.5 + Double(i) * 3.5, y: 6, width: 2.75, height: 4), xRadius: 0.75, yRadius: 0.75).fill()
            }
            // Cube with its round screen cut out, then the slider.
            let cube = NSBezierPath(roundedRect: NSRect(x: 21.5, y: 4.75, width: 4.5, height: 6.5), xRadius: 1.25, yRadius: 1.25)
            cube.appendOval(in: NSRect(x: 22.4, y: 6.15, width: 2.7, height: 3.7))
            cube.windingRule = .evenOdd
            cube.fill()
            NSBezierPath(roundedRect: NSRect(x: 26.75, y: 5.25, width: 1.25, height: 5.5), xRadius: 0.6, yRadius: 0.6).fill()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Deckhand"
        return img
    }()
}
