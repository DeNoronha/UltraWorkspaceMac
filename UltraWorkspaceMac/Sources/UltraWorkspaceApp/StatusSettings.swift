import SwiftUI
import UltraBarKit

/// Apps → Cloud Status: which services the bar shows (up to twelve, in this order). The bar reads their public status
/// pages itself; this Mac only passes the list on with the bar's config (`apps.status.services`).
struct StatusSettings: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Section {
            ForEach(CloudStatus.known, id: \.id) { s in
                let on = settings.statusServices.contains(s.id)
                Toggle(isOn: Binding(get: { on }, set: { v in settings.statusServices = CloudStatus.toggled(settings.statusServices, s.id, on: v) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name)
                        Text(s.host).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(on ? settings.statusServices.count == 1 : settings.statusServices.count >= CloudStatus.maxServices)
            }
            HStack {
                Text("\(settings.statusServices.count) of \(CloudStatus.maxServices)").foregroundStyle(.secondary)
                Spacer()
                Button("Default Set") { settings.statusServices = CloudStatus.defaults }.disabled(settings.statusServices == CloudStatus.defaults)
            }
        } header: {
            Text("Services")
        } footer: {
            Footnote("The bar reads each service's public status page every few minutes while Cloud Status is open. No account needed. Microsoft shows only widespread incidents here; your own tenant's health is in the Microsoft 365 admin center.")
        }
    }
}
