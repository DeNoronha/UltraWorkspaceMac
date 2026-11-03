import SwiftUI
import UltraBarKit

/// Apps: install or update from the vendor marketplace, remove apps from the bar.
/// The bar does the downloading itself (APP_MANAGER 30600); Deckhand only asks and watches.
struct AppsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Header("Apps", "Install from the marketplace, or remove apps from the bar.") {
                Button { model.refreshAppStore() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(!model.link.isConnected)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let e = model.appStoreError {
                        Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    Panel("Marketplace", footer: "The bar downloads and installs the app itself (it needs internet access), one at a time. Installed apps get an “Open <app>” card in Widgets.") {
                        if model.storeApps.isEmpty {
                            Text(model.link.isConnected ? "Press Refresh to load the catalogue." : "Connect to the bar first.").foregroundStyle(.secondary)
                        }
                        ForEach(model.storeApps) { a in storeRow(a); Divider() }
                    }
                    Panel("On the bar", footer: "Everything the bar lists as installed, including apps that are not in the marketplace. Removing one also drops its card from the page at the next publish.") {
                        if model.barApps.isEmpty { Text("No apps read from the bar yet.").foregroundStyle(.secondary) }
                        ForEach(model.barApps, id: \.packageName) { a in barRow(a); Divider() }
                    }
                }.padding(20)
            }
        }
        .onAppear { if model.storeApps.isEmpty { model.refreshAppStore() } }
    }

    private func storeRow(_ a: BarAppStore.StoreApp) -> some View {
        let st = model.appStatus[a.package]
        let busy = model.appBusy == a.package
        let update = (st?.installed ?? false) && (st?.versionCode ?? 0) < a.versionCode
        return HStack(spacing: 12) {
            AsyncImage(url: a.iconURL) { img in img.resizable() } placeholder: { Image(systemName: "app").foregroundStyle(.secondary) }
                .frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(a.name).fontWeight(.medium)
                    Text(a.versionName).font(.caption).foregroundStyle(.secondary)
                    if let st, st.installed {
                        Text(update ? "installed \(st.versionName) · update available" : "installed").font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1).background((update ? Color.orange : Color.green).opacity(0.2)).clipShape(Capsule())
                    }
                }
                if !a.summary.isEmpty { Text(a.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                Text(a.package).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            if let st, st.installed {
                if update { Button("Update") { model.installApp(a.package, name: a.name) }.disabled(model.appBusy != nil) }
                Button("Remove", role: .destructive) { model.uninstallApp(a.package, name: a.name) }.disabled(model.appBusy != nil)
            } else {
                Button("Install") { model.installApp(a.package, name: a.name) }.disabled(model.appBusy != nil || !model.link.isConnected)
            }
        }.padding(.vertical, 4)
    }

    private func barRow(_ a: CoreBarSession.AppInfo) -> some View {
        let inStore = model.storeApps.contains { $0.package == a.packageName }
        return HStack(spacing: 12) {
            Image(systemName: "app.badge").foregroundStyle(.secondary).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(a.appName).fontWeight(.medium)
                Text(a.packageName + (inStore ? "" : " · not in the marketplace")).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if model.appBusy == a.packageName { ProgressView().controlSize(.small) }
            Button("Remove", role: .destructive) { model.uninstallApp(a.packageName, name: a.appName) }.disabled(model.appBusy != nil)
        }.padding(.vertical, 4)
    }
}
