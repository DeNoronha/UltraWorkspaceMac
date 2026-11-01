import SwiftUI

@main
struct UltraWorkspaceApp: App {
    @StateObject private var model = AppModel()

    init() {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--render-weather"), i + 1 < a.count {
            WeatherPreview.run(dir: a[i + 1])
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("UltraWorkspace") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 540)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About UltraWorkspace") { model.showingAbout = true }
            }
        }
    }
}
