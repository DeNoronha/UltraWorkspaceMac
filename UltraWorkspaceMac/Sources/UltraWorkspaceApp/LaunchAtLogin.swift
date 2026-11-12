import SwiftUI
import ServiceManagement

/// Settings → Deckhand on this Mac: start Deckhand when you log in. macOS keeps the login item itself
/// (`SMAppService.mainApp`, listed under System Settings → General → Login Items), so the toggle always shows what
/// macOS has, not a copy in settings.json. Registering only works from the installed, signed Deckhand.app.
struct LaunchAtLoginRow: View {
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        Toggle("Open Deckhand when you log in", isOn: Binding(get: { status == .enabled || status == .requiresApproval }, set: set))
        if status == .requiresApproval {
            HStack {
                Text("macOS is waiting for your approval in System Settings → General → Login Items.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
            }
        }
        if let error {
            Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func set(_ on: Bool) {
        error = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            self.error = "macOS did not accept that: \(error.localizedDescription)"
        }
        status = SMAppService.mainApp.status
    }
}
