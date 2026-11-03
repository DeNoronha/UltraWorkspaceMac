import SwiftUI

@main
struct UltraWorkspaceApp: App {
    @StateObject private var model = AppModel()

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
        WindowGroup("Deckhand") {
            ContentView()
                .environmentObject(model)
                // Wider minimum when the Activity column is on, so page text never gets measured at a sliver.
                .frame(minWidth: model.showActivity ? 1100 : 820, minHeight: 540)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About Deckhand") { model.nav = .about }
            }
        }
    }
}
