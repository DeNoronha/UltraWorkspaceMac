import SwiftUI
import UltraBarKit

/// Everything in use, in one place: apps and screensavers on the bar (update, remove), cards on the cube
/// and on the CoreBar page (remove). Installing and settings live on the Widgets, Apps and Screensavers pages.
struct InstalledView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            Header("Installed", "What is on the bar and on the screens right now.") {
                HStack {
                    RefreshButton()
                    UpdateAllButton()
                }
            }
            // Errors stay put above the scroll, so a failed Remove far down the list is still seen (2026-11-04).
            LibraryErrorStrip()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    let n = model.updatesAvailable
                    if n > 0 { Label(n == 1 ? "1 update available" : "\(n) updates available", systemImage: "arrow.down.circle.fill").foregroundStyle(.orange).fontWeight(.medium) }

                    let ours = AppModel.barAppPages.filter { model.barAppVersion($0.page) != nil }
                    let userApps = model.barApps.filter { !$0.isScreensaver && !$0.systemApp && !$0.packageName.hasPrefix(BarPages.packagePrefix) }
                    let firmware = model.barApps.filter { !$0.isScreensaver && $0.systemApp }
                    Panel("Apps on the bar", footer: model.barApps.isEmpty ? (model.link.isConnected ? "Press Refresh." : "Connect to the bar first.") : "Deckhand's own apps go over ADB; the others are updated and removed by the bar itself. To install more, go to Apps.") {
                        if ours.isEmpty && userApps.isEmpty && !model.barApps.isEmpty { Text("Only the firmware's apps.").foregroundStyle(.secondary) }
                        ForEach(ours, id: \.page) { app in deckhandRow(app); Divider() }
                        ForEach(userApps, id: \.packageName) { a in barRow(a); Divider() }
                        ForEach(firmware, id: \.packageName) { a in barRow(a); Divider() }
                    }
                    Panel("Screensavers on the bar", footer: "The one in use cannot be removed; pick another on the Screensavers page first.") {
                        if model.screensaverApps.isEmpty { Text(model.barApps.isEmpty ? "—" : "None installed.").foregroundStyle(.secondary) }
                        ForEach(model.screensaverApps, id: \.packageName) { a in barRow(a); Divider() }
                    }
                    Panel("Cards on the VivoCube", footer: "Pictures this Mac draws and sends to the cube. Their settings are on the Widgets page.") {
                        if settings.vivoCards.isEmpty { Text("No cards yet.").foregroundStyle(.secondary) }
                        ForEach(settings.vivoCards, id: \.self) { t in
                            HStack(spacing: 12) {
                                Image(systemName: t.icon).frame(width: 32, height: 32)
                                Text(t.title).fontWeight(.medium)
                                Spacer()
                                RemoveButton(confirm: "Remove \(t.title) from the cube's cards?", help: "Takes the card out of the cube's list; the cube changes at the next Send to cube.") { settings.removeVivoCard(t) }
                            }.padding(.vertical, 4)
                            Divider()
                        }
                    }
                    Panel("Cards on the CoreBar page", footer: settings.deckhandPagePublished ? "Published to the bar. To add cards, go to the CoreBar page." : "Not published yet — open the CoreBar page and press Publish page.") {
                        if settings.coreCards.isEmpty { Text("No cards yet.").foregroundStyle(.secondary) }
                        ForEach(settings.coreCards, id: \.self) { id in
                            HStack(spacing: 12) {
                                if let c = model.coreCard(id) { CardIcon(card: c, size: 32); Text(c.title).fontWeight(.medium) } else { Image(systemName: "questionmark.square").frame(width: 32, height: 32); Text(id).fontWeight(.medium) }
                                Spacer()
                                RemoveButton(confirm: "Remove \(model.coreCard(id)?.title ?? id) from the CoreBar page?", help: "Takes the card off the page; the bar changes at the next Publish page.") { settings.coreCards.removeAll { $0 == id } }
                            }.padding(.vertical, 4)
                            Divider()
                        }
                    }
                }.padding(20)
            }
        }
        .onAppear { if model.storeApps.isEmpty { model.refreshAppStore() } }
    }

    private func deckhandRow(_ app: (page: String, label: String, apk: String)) -> some View {
        let v = model.barAppVersion(app.page), stale = model.barAppNeedsUpdate(app.page), busy = model.barAppBusy == app.page
        return HStack(spacing: 12) {
            AppIcon(url: model.barAppIconURL(app.page), fallback: AppsView.barAppIcon(app.page))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.label).fontWeight(.medium)
                    if let v { Text(v).font(.caption).foregroundStyle(.secondary) }
                    if stale { Tag("update \(AppModel.barAppsVersion)", .orange) } else { Tag("up to date", .green) }
                    Tag("Deckhand", .secondary)
                }
                Text(BarPages.package(for: app.page)).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            if stale {
                Button { model.installBarApp(app.page) } label: { Label("Update", systemImage: "arrow.down.circle") }.buttonStyle(.borderedProminent).disabled(model.barAppBusy != nil)
            }
            RemoveButton(confirm: "Remove \(app.label) from the bar?", help: "Uninstalls the app from the bar over ADB.", disabled: model.barAppBusy != nil) { model.uninstallBarApp(app.page) }
        }.padding(.vertical, 4)
    }

    private func barRow(_ a: CoreBarSession.AppInfo) -> some View {
        let store = (model.storeApps + model.storeScreensavers).first { $0.package == a.packageName }
        let code = model.appStatus[a.packageName]?.versionCode ?? 0
        let update = store.map { $0.versionCode > code && code > 0 } ?? false
        let busy = model.appBusy == a.packageName, active = a.isScreensaver && model.isActiveScreensaver(a)
        let webUI: URL? = {
            guard let port = a.port, let tok = a.sessionToken, let bar = model.selectedCoreBar else { return nil }
            let ip = model.address(for: bar.serialNo) ?? bar.lastIp
            return URL(string: "http://\(ip):\(port)/?sessionToken=\(tok)")
        }()
        return HStack(spacing: 12) {
            AppIcon(url: a.iconUrl.flatMap(URL.init), fallback: a.isScreensaver ? "sparkles.tv" : (a.systemApp ? "app.badge" : "app"))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(a.appName).fontWeight(.medium)
                    if !a.versionName.isEmpty { Text(a.versionName).font(.caption).foregroundStyle(.secondary) }
                    if update, let store { Tag("update \(store.versionName)", .orange) } else if store != nil { Tag("up to date", .green) }
                    if active { Tag("in use", .green) }
                    if a.systemApp { Tag("built in", .secondary) }
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
                RemoveButton(confirm: "Remove \(a.appName) from the bar?", help: active ? "The screensaver in use cannot be removed; pick another on the Screensavers page first." : "The bar uninstalls the app.", disabled: model.appBusy != nil || active) { model.uninstallApp(a.packageName, name: a.appName) }
            }
        }.padding(.vertical, 4)
    }
}
