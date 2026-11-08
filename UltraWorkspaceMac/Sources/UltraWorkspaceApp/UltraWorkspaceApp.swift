import SwiftUI

@main
struct UltraWorkspaceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @AppStorage(MacPresence.key) private var presence: MacPresence = .dock

    init() {
        // Scroll bars always visible in this app (per-app override of the system "Show scroll bars" setting).
        UserDefaults.standard.set("Always", forKey: "AppleShowScrollBars")
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--render-weather"), i + 1 < a.count {
            WeatherPreview.run(dir: a[i + 1])
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("Deckhand", id: MainWindow.id) {
            ContentView()
                .environmentObject(model)
                // Wider minimum when the Activity column is on, so page text never gets measured at a sliver.
                // Budget: sidebar up to 320 + divider + Activity 260 + the widest page (Apps / Screensavers:
                // list 240 + detail 360 = 600) = 1181; at 1100 the detail pane clipped (2026-11-05).
                .frame(minWidth: model.showActivity ? 1200 : 820, minHeight: 540)
                .onChange(of: presence) { MacPresence.applyDockIcon($0) }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About Deckhand") { model.nav = .about }
            }
        }

        MenuBarExtra("Deckhand", systemImage: "rectangle.on.rectangle", isInserted: Binding(
            get: { presence.showsMenuBarIcon },
            set: { inserted in
                // The user removed the icon with ⌘-drag: keep the Dock icon so Deckhand stays reachable.
                if !inserted { presence = .dock; MacPresence.applyDockIcon(.dock) }
            })) {
            MenuBarMenu().environmentObject(model)
        }
    }
}
