import SwiftUI
import ServiceManagement

/// Settings → General: start Deckhand when you log in. macOS keeps the login item itself
/// (`SMAppService.mainApp`, listed under System Settings → General → Login Items), so the toggle always shows what
/// macOS has, not a copy in settings.json. Registering only works from the installed, signed Deckhand.app.
struct LaunchAtLoginRow: View {
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        Toggle("Open Deckhand when you log in", isOn: Binding(get: { status == .enabled || status == .requiresApproval }, set: set))
        if status == .requiresApproval {
            HStack {
                StatusLabel("macOS is waiting for your approval in Login Items.", .attention)
                Spacer()
                Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
            }
        }
        if let error {
            StatusLabel(error, .failed)
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
