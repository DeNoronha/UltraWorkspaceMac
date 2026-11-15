import SwiftUI

@main
struct UltraWorkspaceApp: App {
    /// Owns the model and the settings (`AppDelegate`). The App only hands them to the windows and does not observe
    /// them: a `@StateObject` here re-evaluated the whole scene, menu bar icon included, on every change of the model.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(MacPresence.key) private var presence: MacPresence = .dock

    init() {
        Snapshots.runIfRequested()   // dev only: DECKHAND_SNAPSHOTS=<folder> writes page screenshots and quits (Snapshots.swift)
        // Scroll bars always visible in this app (per-app override of the system "Show scroll bars" setting).
        UserDefaults.standard.set("Always", forKey: "AppleShowScrollBars")
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--render-weather"), i + 1 < a.count {
            WeatherPreview.run(dir: a[i + 1])
            exit(0)
        }
    }

    var body: some Scene {
        // The window menu lists it as "Deckhand"; the title bar shows the page (navigationTitle).
        WindowGroup("Deckhand", id: MainWindow.id) {
            ContentView()
                .environmentObject(appDelegate.model)
                .environmentObject(appDelegate.settings)
                .onChange(of: presence) { MacPresence.applyDockIcon($0) }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About Deckhand") { AboutPanel.show() }
            }
            CommandGroup(after: .windowList) {
                PeopleCommand()
            }
            HelpCommands()
        }

        Settings {
            SettingsWindowView()
                .environmentObject(appDelegate.model)
                .environmentObject(appDelegate.settings)
        }

        Window("Deckhand Help", id: HelpWindow.id) {
            HelpView()
        }
        .defaultSize(width: 760, height: 560)

        Window("People", id: PeopleWindow.id) {
            PeopleView().environmentObject(appDelegate.contacts)
        }
        .defaultSize(width: 520, height: 480)
        // The menu bar icon is an AppKit status item owned by AppDelegate (applyMenuBarIcon).
    }
}

/// Window › People (⌥⌘P).
private struct PeopleCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("People") { openWindow(id: PeopleWindow.id) }
            .keyboardShortcut("p", modifiers: [.command, .option])
    }
}

/// The standard About panel, with the repository, contact and the independence note as credits.
@MainActor
enum AboutPanel {
    static let repoURL = URL(string: "https://github.com/DeNoronha/UltraWorkspaceMac")!
    static let contactEmail = "ramon@denoronha.nl"

    static func show() {
        let credits = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.labelColor]
        let note: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor]
        let centred = NSMutableParagraphStyle(); centred.alignment = .center
        credits.append(NSAttributedString(string: "A native macOS app for the UltraBar X.\n\n", attributes: body))
        credits.append(NSAttributedString(string: "Source code", attributes: body.merging([.link: repoURL]) { $1 }))
        credits.append(NSAttributedString(string: "  ·  ", attributes: body))
        credits.append(NSAttributedString(string: "Contact", attributes: body.merging([.link: URL(string: "mailto:\(contactEmail)")!]) { $1 }))
        credits.append(NSAttributedString(string: "  ·  MIT License\n\n", attributes: body))
        credits.append(NSAttributedString(string: "Independent community software, not affiliated with or endorsed by Sanytron, the maker of UltraBar X.", attributes: note))
        credits.addAttribute(.paragraphStyle, value: centred, range: NSRange(location: 0, length: credits.length))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 Ramon de Noronha",
        ])
    }
}
