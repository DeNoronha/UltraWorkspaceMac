import SwiftUI
import UltraBarKit

/// Screensavers, laid out like Widgets and Apps: the list on the left (installed first), the chosen one on
/// the right with "Installed on the bar", "Use this screensaver" and the bar's screensaver settings.
/// Setting = GET/SET_COREBAR_CONFIG BASE_SET; installs = APP_MANAGER with the screensaver app type.
struct ScreensaversView: View {
    @EnvironmentObject var model: AppModel
    @MainActor final class UI: ObservableObject { @Published var selected: String? }
    @StateObject private var ui = UI()

    /// One entry: catalogue entry and/or installed app, merged by package.
    private struct Tile: Identifiable {
        let package: String, name: String, version: String, icon: URL?
        let installed: CoreBarSession.AppInfo?, store: BarAppStore.StoreApp?
        var id: String { package }
    }

    private var tiles: [Tile] {
        var out: [String: Tile] = [:]
        for s in model.storeScreensavers {
            out[s.package] = Tile(package: s.package, name: s.name, version: s.versionName, icon: s.iconURL, installed: nil, store: s)
        }
        for a in model.screensaverApps {
            let s = out[a.packageName]?.store
            out[a.packageName] = Tile(package: a.packageName, name: s?.name ?? a.appName, version: a.versionName,
                                      icon: s?.iconURL ?? a.iconUrl.flatMap(URL.init), installed: a, store: s)
        }
        return out.values.sorted { ($0.installed == nil ? 1 : 0, $0.name) < ($1.installed == nil ? 1 : 0, $1.name) }
    }
    private func isActive(_ t: Tile) -> Bool { t.installed.map(model.isActiveScreensaver) ?? false }
    private func updateAvailable(_ t: Tile) -> Bool {
        guard let s = t.store, t.installed != nil else { return false }
        let code = model.appStatus[t.package]?.versionCode ?? 0
        return code > 0 && s.versionCode > code
    }

    var body: some View {
        VStack(spacing: 0) {
            Header("Screensavers", "What the bar shows when nobody touches it. Switch one on to install it, then use it.") {
                Button { model.refreshAppStore() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(!model.link.isConnected)
            }
            Divider()
            HSplitView {
                List(selection: $ui.selected) {
                    Section {
                        if tiles.isEmpty { Text(model.link.isConnected ? "Nothing yet — press Refresh." : "Connect to the bar first.").font(.caption).foregroundStyle(.secondary) }
                        ForEach(tiles) { t in
                            LibraryRow(title: t.name, caption: t.installed == nil ? nil : (isActive(t) ? "\(t.version) · in use" : t.version), inUse: t.installed != nil, busy: model.appBusy == t.package, updateAvailable: updateAvailable(t)) {
                                AppIcon(url: t.icon, fallback: "sparkles.tv", size: 18)
                            }.tag(t.package)
                        }
                    } header: { Text("Screensavers") }
                }
                .frame(minWidth: 240, maxWidth: 300)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let e = model.appStoreError { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                        if let sel = ui.selected, let t = tiles.first(where: { $0.package == sel }) { detail(t) }
                        else { Text("Pick a screensaver on the left.").foregroundStyle(.secondary) }
                        Divider()
                        timing
                        Spacer()
                    }.padding(20).frame(minWidth: 360, maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            model.refreshAppStore()
            if ui.selected == nil { ui.selected = tiles.first(where: isActive)?.package ?? tiles.first?.package }
        }
    }

    @ViewBuilder private func detail(_ t: Tile) -> some View {
        let active = isActive(t), busy = model.appBusy == t.package, update = updateAvailable(t)
        let tag: (String, Color) = active ? ("in use", .green) : (update ? ("update \(t.store?.versionName ?? "")", .orange) : (t.installed == nil ? ("not installed", .secondary) : ("installed", .green)))
        HStack(alignment: .top, spacing: 20) {
            thumb(t.icon, width: 240, height: 135)
            VStack(alignment: .leading, spacing: 12) {
                DetailTitle(title: t.name, version: t.installed == nil ? t.store?.versionName : t.version, tag: tag, subtitle: t.package + (t.store == nil ? " · not in the marketplace" : "")) { EmptyView() }
                if let s = t.store, !s.summary.isEmpty { Text(s.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                InstalledToggle(title: "Installed on the bar", isOn: t.installed != nil, busy: busy,
                                disabled: model.appBusy != nil || !model.link.isConnected || (t.installed?.systemApp ?? false) || active || (t.installed == nil && t.store == nil),
                                note: (t.installed?.systemApp ?? false) ? "Part of the firmware." : (active ? "In use — pick another one first to remove it." : nil),
                                confirmOff: "Remove \(t.name) from the bar?") { on in
                    if on { model.installApp(t.package, name: t.name) } else if let a = t.installed { model.uninstallApp(a.packageName, name: a.appName) }
                }
                HStack(spacing: 12) {
                    if let a = t.installed, !active {
                        Button { model.setScreensaver(app: a) } label: { Label("Use this screensaver", systemImage: "sparkles.tv") }.buttonStyle(.borderedProminent).disabled(model.appBusy != nil)
                    }
                    if update, let s = t.store, !busy {
                        Button { model.installApp(t.package, name: t.name) } label: { Label("Update to \(s.versionName)", systemImage: "arrow.down.circle") }.buttonStyle(.bordered).disabled(model.appBusy != nil)
                    }
                }
            }
        }
    }

    /// The bar's screensaver settings: on/off and the idle time (one setting for whichever screensaver is in use).
    private var timing: some View {
        let c = model.screensaver, active = tiles.first(where: isActive)
        return Panel("Screensaver settings", footer: c?.featureEnabled == true
                     ? "The bar starts \(active?.name ?? "the screensaver") after \(AppModel.lockTimeLabel(c?.lockTime ?? "")) without a touch."
                     : "Off — the bar keeps showing its page. Pick a screensaver, press Use this screensaver and switch it on.") {
            HStack(spacing: 14) {
                Toggle("Start screensaver", isOn: Binding(get: { c?.featureEnabled ?? false }, set: { model.setScreensaver(enabled: $0) }))
                    .toggleStyle(.switch).disabled(c == nil || active == nil)
                Text("after").foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { c?.lockTime ?? "TIME_5MIN" }, set: { model.setScreensaver(lockTime: $0) })) {
                    ForEach(CoreBarSession.ScreensaverConfig.lockTimes, id: \.self) { Text(AppModel.lockTimeLabel($0)).tag($0) }
                }.labelsHidden().frame(width: 110).disabled(c == nil)
                if let active { Text("In use: \(active.name)").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func thumb(_ url: URL?, width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.6))
            AsyncImage(url: url) { img in img.resizable().aspectRatio(contentMode: .fit).padding(height * 0.15) } placeholder: { Image(systemName: "sparkles.tv").font(.largeTitle).foregroundStyle(.secondary) }
        }
        .frame(width: width, height: height).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
