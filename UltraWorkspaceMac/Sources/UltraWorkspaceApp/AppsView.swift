import SwiftUI
import UltraBarKit

/// Apps: what is installed on the bar (update / remove / web UI) and what the marketplace still offers.
/// The bar does the downloading itself (APP_MANAGER 30600); Deckhand only asks and watches.
struct AppsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Header("Apps", "Apps run on the bar itself; Deckhand installs, updates and removes them.") {
                HStack {
                    Button { model.refreshAppStore() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(!model.link.isConnected)
                    let updates = pendingUpdates
                    Button { model.updateAll(updates) } label: { Label(updates.isEmpty ? "Update all" : "Update all (\(updates.count))", systemImage: "arrow.down.circle") }
                        .buttonStyle(.borderedProminent).disabled(updates.isEmpty || model.appBusy != nil)
                        .help(updates.isEmpty ? "Everything is up to date." : "Updates one app after another: " + updates.map(\.name).joined(separator: ", "))
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let e = model.appStoreError {
                        Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    Panel("Installed", footer: "Everything the bar reports as installed. Apps the bar offers as a page card appear under Widgets → Apps on the bar; add them to the page from there or from the CoreBar page.") {
                        if model.barApps.isEmpty { Text(model.link.isConnected ? "Press Refresh." : "Connect to the bar first.").foregroundStyle(.secondary) }
                        ForEach(model.barApps.filter { !$0.isScreensaver }, id: \.packageName) { a in installedRow(a); Divider() }
                    }
                    screensavers
                    Panel("Marketplace", footer: "The vendor's catalogue. The bar downloads and installs the app itself (it needs internet), one at a time, in about ten seconds.") {
                        let available = model.storeApps.filter { s in !model.barApps.contains { $0.packageName == s.package } && !(model.appStatus[s.package]?.installed ?? false) }
                        if model.storeApps.isEmpty { Text(model.link.isConnected ? "Press Refresh to load the catalogue." : "Connect to the bar first.").foregroundStyle(.secondary) }
                        else if available.isEmpty { Text("Everything in the marketplace is installed.").foregroundStyle(.secondary) }
                        ForEach(available) { a in storeRow(a); Divider() }
                    }
                }.padding(20)
            }
        }
        .onAppear { if model.storeApps.isEmpty { model.refreshAppStore() } }
    }

    private var screensavers: some View {
        let c = model.screensaver
        return Panel("Screensavers", footer: "The bar starts the chosen screensaver app after the idle time. Screensaver apps are installed from the bar itself (Settings → Screensaver on the bar); Deckhand can only pick, time and remove them.") {
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

    /// Installed apps for which the marketplace has a higher versionCode.
    private var pendingUpdates: [(package: String, name: String)] {
        model.barApps.compactMap { a in
            guard let s = model.storeApps.first(where: { $0.package == a.packageName }) else { return nil }
            let code = model.appStatus[a.packageName]?.versionCode ?? 0
            return (code > 0 && s.versionCode > code) ? (a.packageName, a.appName) : nil
        }
    }

    private func installedRow(_ a: CoreBarSession.AppInfo) -> some View {
        let store = model.storeApps.first { $0.package == a.packageName }
        let installedCode = model.appStatus[a.packageName]?.versionCode ?? 0
        let update = store.map { $0.versionCode > installedCode && installedCode > 0 } ?? false
        let busy = model.appBusy == a.packageName
        let webUI: URL? = {
            guard let port = a.port, let tok = a.sessionToken, let bar = model.selectedCoreBar else { return nil }
            let ip = model.discovered.first(where: { $0.serialNo == bar.serialNo })?.ip ?? bar.lastIp
            return URL(string: "http://\(ip):\(port)/?sessionToken=\(tok)")
        }()
        return HStack(spacing: 12) {
            icon(url: a.iconUrl.flatMap(URL.init), fallback: a.isScreensaver ? "sparkles.tv" : "app.badge")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(a.appName).fontWeight(.medium)
                    if !a.versionName.isEmpty { Text(a.versionName).font(.caption).foregroundStyle(.secondary) }
                    if update, let store { tag("update \(store.versionName)", .orange) }
                    if a.isScreensaver { tag("screensaver", .secondary) }
                    if a.systemApp { tag("built in", .secondary) }
                }
                Text(a.packageName + (store == nil ? " · not in the marketplace" : "")).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            if let webUI { Link(destination: webUI) { Label("Web UI", systemImage: "safari") }.buttonStyle(.bordered).help("Opens the app's own web page on the bar in your browser.") }
            if update, let store {
                Button { model.installApp(a.packageName, name: a.appName) } label: { Label("Update", systemImage: "arrow.down.circle") }
                    .buttonStyle(.borderedProminent).disabled(model.appBusy != nil).help("Update to \(store.versionName)")
            }
            if a.systemApp {
                Text("part of the firmware").font(.caption).foregroundStyle(.secondary).help("Built into the bar's system image; it cannot be removed, only updated.")
            } else {
                Button { model.uninstallApp(a.packageName, name: a.appName) } label: { Label("Remove", systemImage: "trash") }
                    .buttonStyle(.bordered).tint(.red).disabled(model.appBusy != nil)
            }
        }.padding(.vertical, 4)
    }

    private func storeRow(_ a: BarAppStore.StoreApp) -> some View {
        let busy = model.appBusy == a.package
        return HStack(spacing: 12) {
            icon(url: a.iconURL, fallback: "app")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) { Text(a.name).fontWeight(.medium); Text(a.versionName).font(.caption).foregroundStyle(.secondary) }
                if !a.summary.isEmpty { Text(a.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
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
