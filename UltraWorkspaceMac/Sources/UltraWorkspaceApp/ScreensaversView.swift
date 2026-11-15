import SwiftUI
import UltraBarKit

/// Screensavers, laid out like Apps: the list on the left (installed first, with the same All / On the Bar / Updates
/// filter), the chosen one on the right with Install / Update / Remove…, Use This Screensaver, and the bar's
/// screensaver settings (one setting for whichever is in use).
/// Setting = GET/SET_COREBAR_CONFIG BASE_SET; installs = APP_MANAGER with the screensaver app type.
struct ScreensaversView: View {
    @EnvironmentObject var model: AppModel
    @MainActor final class UI: ObservableObject { @Published var selected: String?; @Published var filter: LibraryFilter = .all; @Published var search = "" }
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
            out[a.packageName] = Tile(package: a.packageName, name: a.appName.isEmpty ? (s?.name ?? a.packageName) : a.appName, version: a.versionName,
                                      icon: s?.iconURL ?? a.iconUrl.flatMap(URL.init), installed: a, store: s)
        }
        return out.values.sorted { ($0.installed == nil ? 1 : 0, $0.name) < ($1.installed == nil ? 1 : 0, $1.name) }
    }
    private func isActive(_ t: Tile) -> Bool { t.installed.map(model.isActiveScreensaver) ?? false }
    private func updateAvailable(_ t: Tile) -> Bool { t.installed != nil && model.marketUpdate(for: t.package) != nil }

    var body: some View {
        LibraryLayout {
            LibraryFilterBar(filter: $ui.filter, search: $ui.search)
        } list: {
            List(selection: $ui.selected) {
                let q = ui.search.trimmingCharacters(in: .whitespaces)
                let shown = tiles.filter { t in
                    guard q.isEmpty || t.name.localizedCaseInsensitiveContains(q) else { return false }
                    switch ui.filter { case .all: return true; case .onBar: return t.installed != nil; case .updates: return updateAvailable(t) }
                }
                Section("Screensavers") {
                    if shown.isEmpty {
                        Text(!q.isEmpty ? "No screensaver matches “\(q)”." : ui.filter == .updates ? "Everything is up to date." : model.link.isConnected ? "Nothing yet. Press Refresh." : "Connect to the bar first.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(shown) { t in
                        LibraryRow(title: t.name, caption: t.installed == nil ? nil : (isActive(t) ? "\(t.version) · In use" : t.version), installed: t.installed != nil, busy: model.appBusy == t.package, updateAvailable: updateAvailable(t)) {
                            AppIcon(url: t.icon, title: t.name, size: 22)
                        }.tag(t.package)
                    }
                }
            }
            .listStyle(.inset)
        } detail: {
            Form {
                LibraryErrorSection(includeBarApps: false)
                timing
                if let sel = ui.selected, let t = tiles.first(where: { $0.package == sel }) { detail(t) }
                else { Section { Text("Choose a screensaver on the left.").foregroundStyle(.secondary) } }
            }
            .formStyle(.grouped)
        }
        .navigationSubtitle("What the bar shows when nobody touches it")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { UpdateAllButton(screensavers: true) }
        }
        .onAppear {
            model.refreshAppStore()
            if ui.selected == nil { ui.selected = tiles.first(where: isActive)?.package ?? tiles.first?.package }
        }
    }

    @ViewBuilder private func detail(_ t: Tile) -> some View {
        let active = isActive(t), busy = model.appBusy == t.package, update = updateAvailable(t)
        let system = t.installed?.systemApp ?? false
        let tag: (String, StatusKind) = active ? ("In use", .ok) : (update ? ("Update \(t.store?.versionName ?? "")", .update) : (model.staleCatalogueNote(t.package).map { ($0, .info) } ?? (t.installed == nil ? ("Not installed", .info) : ("On the bar", .ok))))
        Section {
            HStack(alignment: .top, spacing: 16) {
                thumb(t.icon, name: t.name, width: 200, height: 112)
                VStack(alignment: .leading, spacing: 8) {
                    DetailTitle(title: t.name, version: t.installed == nil ? t.store?.versionName : t.version, tag: tag) { EmptyView() }
                    if let s = t.store, !s.summary.isEmpty { Text(s.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
            }
            InstallControls(name: t.name, installed: t.installed != nil, updateTo: update ? t.store?.versionName : nil, busy: busy,
                            canInstall: model.appBusy == nil && model.link.isConnected && (t.installed != nil || t.store != nil),
                            canRemove: !system && !active,
                            note: system ? "Part of the firmware: it cannot be removed." : (active && t.installed != nil ? "In use: choose another screensaver before removing this one." : nil),
                            install: { model.installApp(t.package, name: t.name) },
                            remove: { if let a = t.installed { model.uninstallApp(a.packageName, name: a.appName) } })
            if let a = t.installed, !active {
                Button("Use This Screensaver") { model.setScreensaver(app: a) }.disabled(model.appBusy != nil)
            }
        }
        AppDetailsSection(package: t.package, inMarketplace: t.store != nil)
    }

    /// The bar's screensaver settings: on/off and the idle time (one setting for whichever screensaver is in use).
    private var timing: some View {
        let c = model.screensaver, active = tiles.first(where: isActive)
        return Section {
            Toggle("Start a screensaver", isOn: Binding(get: { c?.featureEnabled ?? false }, set: { model.setScreensaver(enabled: $0) }))
                .disabled(c == nil || active == nil)
            Picker("After", selection: Binding(get: { c?.lockTime ?? "TIME_5MIN" }, set: { model.setScreensaver(lockTime: $0) })) {
                ForEach(CoreBarSession.ScreensaverConfig.lockTimes, id: \.self) { Text(AppModel.lockTimeLabel($0)).tag($0) }
            }
            .disabled(c == nil)
            LabeledContent("In use", value: active?.name ?? "None")
        } header: {
            Text("On the bar")
        } footer: {
            Footnote(c?.featureEnabled == true
                 ? "The bar starts \(active?.name ?? "the screensaver") after \(AppModel.lockTimeLabel(c?.lockTime ?? "")) without a touch."
                 : "Off: the bar keeps showing its page. Choose a screensaver, press Use This Screensaver and switch it on.")
        }
    }

    private func thumb(_ url: URL?, name: String, width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black)
            AppIcon(url: url, title: name, size: height * 0.7)
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }
}
