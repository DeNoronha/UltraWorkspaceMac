import SwiftUI

@main
struct UltraWorkspaceApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("UltraWorkspace") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 540)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
