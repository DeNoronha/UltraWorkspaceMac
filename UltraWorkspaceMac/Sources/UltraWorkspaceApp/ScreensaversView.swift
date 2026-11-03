import SwiftUI
import UltraBarKit

/// Screensavers: on/off, idle time, the active screensaver app, and the vendor catalogue to install more.
/// Setting = GET/SET_COREBAR_CONFIG BASE_SET; installs = APP_MANAGER with the screensaver app type.
struct ScreensaversView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Header("Screensavers", "What the bar shows when nobody touches it.") {
                Button { model.refreshAppStore() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(!model.link.isConnected)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let e = model.appStoreError {
                        Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    panel
                }.padding(20)
            }
        }
        .onAppear { model.refreshAppStore() }
    }

    private var panel: some View {
        let c = model.screensaver
        return Panel(nil, footer: "The bar starts the chosen screensaver app after the idle time. Install more from the vendor's screensaver catalogue above; pick the active one with the radio button.") {
            HStack(spacing: 14) {
                Toggle("Screensaver", isOn: Binding(get: { c?.featureEnabled ?? false }, set: { model.setScreensaver(enabled: $0) }))
                    .toggleStyle(.switch).disabled(c == nil || model.screensaverApps.isEmpty)
                Text("after").foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { c?.lockTime ?? "TIME_5MIN" }, set: { model.setScreensaver(lockTime: $0) })) {
                    ForEach(CoreBarSession.ScreensaverConfig.lockTimes, id: \.self) { Text(AppModel.lockTimeLabel($0)).tag($0) }
                }.labelsHidden().frame(width: 110).disabled(c == nil)
                if c == nil { Text("not read yet").font(.caption).foregroundStyle(.secondary) }
            }
            if model.screensaverApps.isEmpty { Text("No screensaver app on the bar.").foregroundStyle(.secondary) }
            let available = model.storeScreensavers.filter { s in !model.barApps.contains { $0.packageName == s.package } }
            if !available.isEmpty {
                Text("Available").font(.subheadline).foregroundStyle(.secondary).padding(.top, 4)
                ForEach(available) { a in storeRow(a); Divider() }
                Text("Installed").font(.subheadline).foregroundStyle(.secondary).padding(.top, 4)
            }
            ForEach(model.screensaverApps, id: \.packageName) { a in
                let active = model.isActiveScreensaver(a)
                HStack(spacing: 12) {
                    Button { model.setScreensaver(app: a) } label: { Image(systemName: active ? "largecircle.fill.circle" : "circle") }
                        .buttonStyle(.borderless).accessibilityLabel(active ? "\(a.appName) is the active screensaver" : "Use \(a.appName)")
                    icon(url: a.iconUrl.flatMap(URL.init), fallback: "sparkles.tv")
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(a.appName).fontWeight(.medium)
                            if !a.versionName.isEmpty { Text(a.versionName).font(.caption).foregroundStyle(.secondary) }
                            if active { tag("active", .green) }
                        }
                        Text(a.packageName).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if model.appBusy == a.packageName { ProgressView().controlSize(.small) }
                    if a.systemApp { Text("part of the firmware").font(.caption).foregroundStyle(.secondary) }
                    else {
                        Button { model.uninstallApp(a.packageName, name: a.appName) } label: { Label("Remove", systemImage: "trash") }
                            .buttonStyle(.bordered).tint(.red).disabled(model.appBusy != nil || active)
                            .help(active ? "Pick another screensaver first." : "")
                    }
                }.padding(.vertical, 4)
                Divider()
            }
        }
    }


    private func storeRow(_ a: BarAppStore.StoreApp) -> some View {
        let busy = model.appBusy == a.package
        return HStack(spacing: 12) {
            icon(url: a.iconURL, fallback: "sparkles.tv")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) { Text(a.name).fontWeight(.medium); Text(a.versionName).font(.caption).foregroundStyle(.secondary) }
                Text(a.package).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Button { model.installApp(a.package, name: a.name) } label: { Label("Install", systemImage: "arrow.down.circle") }
                .buttonStyle(.borderedProminent).disabled(model.appBusy != nil || !model.link.isConnected)
        }.padding(.vertical, 4)
    }

    private func icon(url: URL?, fallback: String) -> some View {
        AsyncImage(url: url) { img in img.resizable() } placeholder: { Image(systemName: fallback).foregroundStyle(.secondary) }
            .frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 7))
    }
    private func tag(_ s: String, _ c: Color) -> some View {
        Text(s).font(.caption2).padding(.horizontal, 6).padding(.vertical, 1).background(c.opacity(0.2)).clipShape(Capsule())
    }
}
