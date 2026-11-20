import AppKit
import SwiftUI
import UltraBarKit

/// Where Deckhand shows itself on the Mac: the Dock, the menu bar, or both (Settings → General).
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

    /// Follows the Settings → General choice. Menu bar only takes the Dock icon away once no Deckhand window is open
    /// (`AppActivation`): while one is, Deckhand stays a regular app with its own menu bar.
    @MainActor static func applyDockIcon(_ p: MacPresence = .current) {
        if p.showsDockIcon { AppActivation.becomeRegular() } else { AppActivation.returnToMenuBarIfNoWindows() }
    }
}

/// Whether Deckhand is a regular app (Dock icon, its own menu bar: Deckhand, File, Edit, View, Window, Help) or an
/// accessory (menu bar icon only). An accessory app's windows can be in front and even key, but the menu bar keeps
/// showing the previous app's menus and ⌘, does nothing: the first test of 2026-11-15 hit exactly that in menu-bar-
/// only mode. So any open Deckhand window (main, Settings, Help, People) makes it regular and active; when the last
/// one closes in menu-bar-only mode it goes back to an accessory.
@MainActor
enum AppActivation {
    /// Windows that count: titled, normal-level windows. Not panels (About, alerts), menus or the status item.
    static func isAppWindow(_ w: NSWindow) -> Bool {
        w.styleMask.contains(.titled) && !(w is NSPanel) && w.level == .normal
    }

    /// Regular first, then active: activating an accessory app does not give it the menu bar.
    static func bringToFront() {
        becomeRegular()
        NSApp.activate(ignoringOtherApps: true)
    }

    static func becomeRegular() {
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
    }

    /// In menu-bar-only mode, back to an accessory once no Deckhand window is open or minimized (a minimized window
    /// lives in the Dock, so the Dock icon stays while there is one). `closing` is the window that is about to close.
    static func returnToMenuBarIfNoWindows(closing: NSWindow? = nil) {
        guard !MacPresence.current.showsDockIcon, NSApp.activationPolicy() != .accessory else { return }
        let open = NSApp.windows.contains { $0 !== closing && isAppWindow($0) && ($0.isVisible || $0.isMiniaturized) }
        if !open { NSApp.setActivationPolicy(.accessory) }
    }

    /// ⌘Q with the menu bar icon on: close every Deckhand window (minimized ones too); the app keeps running and,
    /// in menu-bar-only mode, gives up its Dock icon once the last one has closed (`returnToMenuBarIfNoWindows`).
    static func closeAllWindows() {
        for w in NSApp.windows where isAppWindow(w) && (w.isVisible || w.isMiniaturized) { w.close() }
    }

    /// A Deckhand window came forward some other way (opened at launch, clicked while Deckhand was an accessory):
    /// become regular. Switching while already active can leave the old menu bar up, so activate again afterwards.
    static func windowBecameKey(_ w: NSWindow) {
        guard isAppWindow(w), NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
    }
}

/// Owns what lives as long as the app rather than a window: the model, the settings, the background services and
/// the menu bar icon. Sets the Dock icon before the first window appears, so a menu-bar-only Deckhand never flashes
/// one in the Dock.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Lazy: created on first use (the window's body or launch), after the App's `init` (which may still quit for
    /// the developer snapshot mode before anything connects to a bar).
    lazy var model = AppModel()
    lazy var settings = AppSettings()
    /// The People window's contacts (one store for the app, not one per window).
    lazy var contacts = ContactStore()
    private var statusItem: NSStatusItem?
    private var statusItemVisibility: NSKeyValueObservation?
    private var defaultsObserver: NSObjectProtocol?
    private var windowObservers: [NSObjectProtocol] = []

    /// Started at login in menu-bar-only mode: the window SwiftUI opens at launch is closed again, so Deckhand starts
    /// in the menu bar without a window (and so without a Dock icon). Opened by hand it still shows its window.
    private var hideLaunchWindow = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        if !MacPresence.current.showsDockIcon {
            NSApp.setActivationPolicy(.accessory)
            hideLaunchWindow = Self.launchedAsLoginItem()
        }
    }

    /// Whether macOS started Deckhand as a login item (System Settings → General → Login Items, `LaunchAtLogin`):
    /// the open-application event then carries `keyAELaunchedAsLogInItem`.
    private static func launchedAsLoginItem() -> Bool {
        guard let e = NSAppleEventManager.shared().currentAppleEvent, e.eventID == AEEventID(kAEOpenApplication) else { return false }
        return e.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        startServices()
        applyMenuBarIcon()
        // Settings → General writes the choice to UserDefaults; follow it.
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyMenuBarIcon() }
        }
        watchWindows()
    }

    /// Keeps the activation policy in step with the open windows (`AppActivation`).
    private func watchWindows() {
        let nc = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            windowObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let w = note.object as? NSWindow else { return }
                // The launch window that is about to be closed again must not bring the Dock icon up first.
                MainActor.assumeIsolated { if self?.hideLaunchWindow != true { AppActivation.windowBecameKey(w) } }
            })
        }
        windowObservers.append(nc.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let w = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard AppActivation.isAppWindow(w) else { return }
                // After the close has finished, so the window no longer counts as visible.
                DispatchQueue.main.async { AppActivation.returnToMenuBarIfNoWindows(closing: w) }
            }
        })
        // A window SwiftUI opened at launch in menu-bar-only mode: give it the menu bar from the start, or close it
        // when Deckhand started at login.
        DispatchQueue.main.async { [weak self] in
            let launched = NSApp.windows.filter { AppActivation.isAppWindow($0) && $0.isVisible }
            let hide = self?.hideLaunchWindow == true
            self?.hideLaunchWindow = false
            guard !launched.isEmpty else { return }
            if hide { launched.forEach { $0.close() } } else { AppActivation.becomeRegular() }
        }
    }

    /// The `adb logcat` tail is a child process, and child processes outlive their parent on macOS: end it here, or
    /// every quit leaves one running on the Mac and a reader on the bar (`startPresence` also sweeps up the ones a
    /// crash or a forced quit left behind).
    func applicationWillTerminate(_ notification: Notification) {
        model.presenceLog?.terminate()
        model.presenceLog = nil
    }

    /// Without a Dock icon, closing the window must not quit Deckhand: the menu bar icon reopens it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// The background services, once per launch and without a window: the bar apps' data server and feeds, presence
    /// over ADB, the Music poll, the cover refresh, the Claude watch, the bar firewall and the cube's timed switching.
    /// Before 2026-11-15 they started from the window's onAppear, so nothing ran until the window opened, and every
    /// reopened window restarted all of them (the Haven socket reconnected, logcat was killed and spawned again).
    private func startServices() {
        let model = self.model, settings = self.settings
        _ = PowerState.shared   // starts watching sleep, screens and the lock screen
        model.serviceSettings = settings
        // The cube keeps its last package across restarts: let DotKey "next" wrap at that count.
        model.lastPublishedVivoLayers = max(model.lastPublishedVivoLayers, settings.vivoLayerCount)
        model.startMusicPolling(settings: settings)
        model.startDailyCoverRefresh(settings: settings)
        model.startClaudeWatch(settings: settings)
        model.startBarDataServer(settings: settings)
        model.startPresence(settings: settings)
        model.resumeCubeRotation()
        model.setBarFirewall(settings.barFirewall)
    }

    // MARK: Menu bar icon

    /// An AppKit status item rather than SwiftUI's MenuBarExtra: the MenuBarExtra re-rendered with every change of
    /// the model (about half of Deckhand's idle main-thread time, 2026-11-15). The image is set once and the menu is
    /// built only when it opens (`menuNeedsUpdate`).
    private func applyMenuBarIcon() {
        let want = MacPresence.current.showsMenuBarIcon
        if want, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = MenuBarIcon.image
            item.button?.toolTip = "Deckhand"
            item.behavior = .removalAllowed
            item.isVisible = true
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
            // The user removed the icon with ⌘-drag: keep the Dock icon so Deckhand stays reachable.
            // (The observation is dropped before Deckhand removes the item itself, so this only sees the user's removal.)
            statusItemVisibility = item.observe(\.isVisible, options: [.new]) { [weak self] _, change in
                guard change.newValue == false else { return }
                // After this callback returns: the switch removes the item that is reporting the change.
                Task { @MainActor in
                    guard let self, self.statusItem != nil else { return }
                    UserDefaults.standard.set(MacPresence.dock.rawValue, forKey: MacPresence.key)
                    MacPresence.applyDockIcon(.dock)
                    self.applyMenuBarIcon()
                }
            }
        } else if !want, let item = statusItem {
            statusItemVisibility = nil
            statusItem = nil
            NSStatusBar.system.removeStatusItem(item)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let line = NSMenuItem(title: MenuBarMenu.barLine(model), action: nil, keyEquivalent: "")
        line.isEnabled = false
        menu.addItem(line)
        menu.addItem(.separator())
        // The two pushes people do most, without opening the window.
        let publish = NSMenuItem(title: "Publish Deckhand Page", action: #selector(publishPage), keyEquivalent: "")
        publish.target = self
        publish.isEnabled = model.link.isConnected && !settings.coreCards.isEmpty && !model.pageProgress.isRunning
        menu.addItem(publish)
        let send = NSMenuItem(title: "Send to Cube", action: #selector(sendToCube), keyEquivalent: "")
        send.target = self
        send.isEnabled = model.modules.contains(where: { $0.isVivoCube }) && !settings.vivoCards.isEmpty && !model.cubeProgress.isRunning
        menu.addItem(send)
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Deckhand", action: #selector(openMain), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        let people = NSMenuItem(title: "People…", action: #selector(openPeople), keyEquivalent: "")
        people.target = self
        menu.addItem(people)
        let prefs = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Deckhand", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// Publishes at once, unless the bar has pages made in the official app (or it is the first publish): then the
    /// CoreBar page opens, where Publish asks first.
    @objc private func publishPage() {
        if model.publishNeedsConfirmation(settings: settings) { model.nav = .coreBarPage; MainWindow.bringForward() }
        else { model.publishDeckhandPage(settings: settings) }
    }
    @objc private func sendToCube() { model.sendToCube(settings: settings) }
    @objc private func openPeople() { PeopleWindow.open() }
    @objc private func openSettings() { SettingsWindow.open() }
    @objc private func openMain() { MainWindow.bringForward() }
}

/// The first line of the menu under Deckhand's menu bar icon (`AppDelegate.menuNeedsUpdate`).
enum MenuBarMenu {
    @MainActor static func barLine(_ model: AppModel) -> String {
        guard let s = model.selectedSerial else { return "No bar selected" }
        let name = model.paired.first { $0.serialNo == s }?.name ?? "CoreBar"
        switch model.link {
        case .connected: return "\(name): Connected"
        case .connecting: return "\(name): Connecting…"
        case .reconnecting: return "\(name): Reconnecting…"
        case .stopped: return "\(name): Not connected"
        }
    }
}

@MainActor
enum MainWindow {
    static let id = "main"
    /// SwiftUI's `openWindow` for the main window, handed over by ContentView when it appears.
    static var open: (() -> Void)?

    /// Brings the existing Deckhand window forward, or opens one when it was closed.
    static func bringForward() {
        AppActivation.bringToFront()
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(id) == true && $0.canBecomeMain }) {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else if let open {
            open()
        } else {
            // No window has appeared yet: ask the app the way a Dock click does, which opens the main window.
            _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
        }
    }

    /// Whether a Deckhand window can be seen right now (on screen, not minimized or fully covered). The window's
    /// refresh loops skip their work otherwise.
    static var isOnScreen: Bool {
        NSApp.windows.contains { $0.identifier?.rawValue.hasPrefix(id) == true && $0.isVisible && $0.occlusionState.contains(.visible) }
    }
}

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
