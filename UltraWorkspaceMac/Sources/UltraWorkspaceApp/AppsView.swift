import SwiftUI
import UltraBarKit

/// Apps: what is installed on the bar (update / remove / web UI) and what the marketplace still offers.
/// The bar does the downloading itself (APP_MANAGER 30600); Deckhand only asks and watches.
struct AppsView: View {
    static func barAppIcon(_ page: String) -> String {
        switch page {
        case "claude": return "sparkles"; case "crypto": return "bitcoinsign.circle"; case "weather": return "cloud.sun"; case "music": return "music.note"; case "calendar": return "calendar"
        case "flights": return "airplane"; case "sky": return "moon.stars"; case "news": return "newspaper"; case "verse": return "book.closed"; case "tasks": return "checklist"
        default: return "waveform.path.ecg" }
    }
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            Header("Apps", "Apps run on the bar itself; Deckhand installs, updates and removes them. Screensavers have their own page.") {
                HStack {
                    Button { model.refreshAppStore() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(!model.link.isConnected)
                    let updates = pendingUpdates, ours = deckhandUpdates
                    Button { model.updateAll(updates); model.updateBarApps(ours) } label: { Label(updates.isEmpty && ours.isEmpty ? "Update all" : "Update all (\(updates.count + ours.count))", systemImage: "arrow.down.circle") }
                        .buttonStyle(.borderedProminent).disabled((updates.isEmpty && ours.isEmpty) || model.appBusy != nil || model.barAppBusy != nil)
                        .help(updates.isEmpty ? "Everything is up to date." : "Updates one app after another: " + updates.map(\.name).joined(separator: ", "))
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let e = model.appStoreError {
                        Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    if let e = model.barAppError {
                        Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    let updates = pendingUpdates.count + deckhandUpdates.count
                    if updates > 0 {
                        Label(updates == 1 ? "1 update available" : "\(updates) updates available", systemImage: "arrow.down.circle.fill").foregroundStyle(.orange).fontWeight(.medium)
                    }
                    let isOurs: (CoreBarSession.AppInfo) -> Bool = { $0.packageName.hasPrefix(BarPages.packagePrefix) }
                    let userApps = model.barApps.filter { !$0.isScreensaver && !$0.systemApp && !isOurs($0) }
                    let firmwareApps = model.barApps.filter { !$0.isScreensaver && $0.systemApp }
                    Panel("Installed", footer: "Apps you installed from the marketplace. Deckhand asks the bar to update or remove them; the bar does the work itself.") {
                        if model.barApps.isEmpty { Text(model.link.isConnected ? "Press Refresh." : "Connect to the bar first.").foregroundStyle(.secondary) }
                        else if userApps.isEmpty { Text("Nothing installed beyond the firmware and Deckhand's own apps.").foregroundStyle(.secondary) }
                        ForEach(userApps, id: \.packageName) { a in installedRow(a); Divider() }
                    }
                    Panel("Deckhand apps", footer: "Small apps for the bar, one card each, showing full-width live pages served by this Mac. Installing and updating goes over ADB (Wi-Fi ADB on in the bar's Developer options). After installing: CoreBar page → Add a card → Publish page. ✕ or a long press on the bar returns to the cards. The pages are plain HTTP on this network and only exist while the switch is on.") {
                        HStack(spacing: 12) {
                            Toggle("Serve the pages from this Mac", isOn: $settings.monitorServe)
                                .onChange(of: settings.monitorServe) { _ in model.startMonitor(settings: settings) }
                            if let url = model.monitorURL { Text(String(url.dropLast("/monitor".count))).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                            if let e = model.monitorError { Text(e).foregroundStyle(.red).font(.caption) }
                            Spacer()
                            Text("Deckhand ships version \(AppModel.barAppsVersion)").font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                        ForEach(AppModel.barAppPages, id: \.page) { app in deckhandRow(app); Divider() }
                        appSettings
                    }
                    Panel("Marketplace", footer: "The vendor's catalogue. The bar downloads and installs the app itself (it needs internet), one at a time, in about ten seconds.") {
                        let available = model.storeApps.filter { s in !model.barApps.contains { $0.packageName == s.package } && !(model.appStatus[s.package]?.installed ?? false) }
                        if model.storeApps.isEmpty { Text(model.link.isConnected ? "Press Refresh to load the catalogue." : "Connect to the bar first.").foregroundStyle(.secondary) }
                        else if available.isEmpty { Text("Everything in the marketplace is installed.").foregroundStyle(.secondary) }
                        ForEach(available) { a in storeRow(a); Divider() }
                    }
                    Panel("Built into the firmware", footer: "Part of the bar's system image: they can be updated from the marketplace but not removed.") {
                        ForEach(firmwareApps, id: \.packageName) { a in installedRow(a); Divider() }
                    }
                }.padding(20)
            }
        }
        .onAppear { if model.storeApps.isEmpty { model.refreshAppStore() } }
    }

    /// Installed apps for which the marketplace has a higher versionCode.
    private var pendingUpdates: [(package: String, name: String)] {
        model.barApps.compactMap { a in
            guard let s = (model.storeApps + model.storeScreensavers).first(where: { $0.package == a.packageName }) else { return nil }
            let code = model.appStatus[a.packageName]?.versionCode ?? 0
            return (code > 0 && s.versionCode > code) ? (a.packageName, a.appName) : nil
        }
    }

    /// Deckhand apps on the bar that are older than the bundled APKs.
    private var deckhandUpdates: [String] { AppModel.barAppPages.map(\.page).filter { model.barAppNeedsUpdate($0) } }

    private func deckhandRow(_ app: (page: String, label: String, apk: String)) -> some View {
        let installed = model.barAppVersion(app.page), stale = model.barAppNeedsUpdate(app.page)
        return HStack(spacing: 12) {
            icon(url: model.barAppIconURL(app.page), fallback: Self.barAppIcon(app.page))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.label).fontWeight(.medium)
                    if let v = installed { Text(v).font(.caption).foregroundStyle(.secondary) }
                    if stale { tag("update \(AppModel.barAppsVersion)", .orange) }
                    else if installed != nil { tag("up to date", .green) }
                    else { tag("not installed", .secondary) }
                }
                Text(BarPages.package(for: app.page)).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if model.barAppBusy == app.page { ProgressView().controlSize(.small) }
            else if installed == nil || stale {
                Button { model.installBarApp(app.page) } label: { Label(installed == nil ? "Install" : "Update", systemImage: "arrow.down.circle") }
                    .buttonStyle(.borderedProminent).disabled(model.barAppBusy != nil || AppModel.bundledAPK(app.apk) == nil)
                    .help(installed == nil ? "Install version \(AppModel.barAppsVersion) over ADB" : "Update to \(AppModel.barAppsVersion) over ADB")
            }
        }.padding(.vertical, 4)
    }

    /// Settings for the apps that have any: Flights radius, Headlines source, the Linear key for Tasks.
    private var appSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("App settings").font(.headline).padding(.top, 4)
            HStack {
                Label("Flights", systemImage: "airplane").frame(width: 130, alignment: .leading)
                Stepper("within \(settings.flightsRadiusKm) km", value: $settings.flightsRadiusKm, in: 1...25)
                Text("of the weather location (Widgets → Weather).").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Label("Headlines", systemImage: "newspaper").frame(width: 130, alignment: .leading)
                Picker("", selection: $settings.newsSource) { ForEach(NewsFeed.sources) { s in Text(s.name).tag(s.id) } }.labelsHidden().frame(width: 180)
            }
            HStack {
                Label("Tasks", systemImage: "checklist").frame(width: 130, alignment: .leading)
                SecureField("Linear personal API key (lin_api_…)", text: $model.linearKey).frame(width: 300)
                if let e = model.linearError { Text(e).font(.caption).foregroundStyle(.orange) }
                else { Text(model.linearKey.isEmpty ? "Linear → Settings → Security & access → Personal API keys. Stored in a user-only file." : "Saved.").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func installedRow(_ a: CoreBarSession.AppInfo) -> some View {
        let store = (model.storeApps + model.storeScreensavers).first { $0.package == a.packageName }
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
