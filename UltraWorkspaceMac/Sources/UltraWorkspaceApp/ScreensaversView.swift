import SwiftUI
import UltraBarKit

/// Screensavers, laid out like macOS: the active one large at the top with the idle time, then a grid of
/// every screensaver — installed ones select on click, catalogue ones install on click.
/// Setting = GET/SET_COREBAR_CONFIG BASE_SET; installs = APP_MANAGER with the screensaver app type.
struct ScreensaversView: View {
    @EnvironmentObject var model: AppModel

    /// One tile: catalogue entry and/or installed app, merged by package.
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
        // installed first, then by name
        return out.values.sorted { ($0.installed == nil ? 1 : 0, $0.name) < ($1.installed == nil ? 1 : 0, $1.name) }
    }
    private var active: Tile? { tiles.first { t in t.installed.map(model.isActiveScreensaver) ?? false } }

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
                    hero
                    Panel("All screensavers", footer: "Click a screensaver to use it. Ones with a download badge are in the vendor's catalogue and install on click (about ten seconds, the bar fetches them itself). Right-click an installed one to remove it.") {
                        if tiles.isEmpty { Text(model.link.isConnected ? "Nothing yet — press Refresh." : "Connect to the bar first.").foregroundStyle(.secondary) }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 14)], alignment: .leading, spacing: 16) {
                            ForEach(tiles) { t in tile(t) }
                        }
                    }
                }.padding(20)
            }
        }
        .onAppear { model.refreshAppStore() }
    }

    // MARK: hero

    private var hero: some View {
        let c = model.screensaver
        return Panel(nil) {
            HStack(alignment: .top, spacing: 20) {
                thumb(active?.icon, width: 240, height: 135)
                VStack(alignment: .leading, spacing: 12) {
                    Text(active?.name ?? (c == nil ? "Not read yet" : "No screensaver chosen")).font(.title3).bold()
                    HStack(spacing: 14) {
                        Toggle("Start screensaver", isOn: Binding(get: { c?.featureEnabled ?? false }, set: { model.setScreensaver(enabled: $0) }))
                            .toggleStyle(.switch).disabled(c == nil || active == nil)
                        Text("after").foregroundStyle(.secondary)
                        Picker("", selection: Binding(get: { c?.lockTime ?? "TIME_5MIN" }, set: { model.setScreensaver(lockTime: $0) })) {
                            ForEach(CoreBarSession.ScreensaverConfig.lockTimes, id: \.self) { Text(AppModel.lockTimeLabel($0)).tag($0) }
                        }.labelsHidden().frame(width: 110).disabled(c == nil)
                    }
                    Text(c?.featureEnabled == true
                         ? "The bar starts \(active?.name ?? "the screensaver") after \(AppModel.lockTimeLabel(c?.lockTime ?? "")) without a touch."
                         : "Off — the bar keeps showing its page. Pick a screensaver below and switch it on.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        }
    }

    // MARK: grid

    private func tile(_ t: Tile) -> some View {
        let isActive = t.installed.map(model.isActiveScreensaver) ?? false
        let busy = model.appBusy == t.package
        return VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                thumb(t.icon, width: 160, height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(isActive ? Color.accentColor : Color.clear, lineWidth: 3))
                if busy { ProgressView().controlSize(.small).padding(6) }
                else if t.installed == nil { Image(systemName: "arrow.down.circle.fill").font(.title3).foregroundStyle(.white, .blue).padding(6).help("Install from the catalogue") }
                else if isActive { Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.white, Color.accentColor).padding(6) }
            }
            VStack(spacing: 1) {
                Text(t.name).font(.callout).lineLimit(1)
                Text(t.installed == nil ? "not installed" : t.version).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 160)
        .contentShape(Rectangle())
        .onTapGesture {
            guard model.appBusy == nil else { return }
            if let a = t.installed { model.setScreensaver(app: a) } else { model.installApp(t.package, name: t.name) }
        }
        .contextMenu {
            if let a = t.installed {
                Button("Use \(t.name)") { model.setScreensaver(app: a) }
                if !a.systemApp { Button("Remove from the bar", role: .destructive) { model.uninstallApp(a.packageName, name: a.appName) }.disabled(isActive) }
            } else { Button("Install") { model.installApp(t.package, name: t.name) } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(t.installed == nil ? "Install \(t.name)" : (isActive ? "\(t.name), active" : "Use \(t.name)"))
    }

    private func thumb(_ url: URL?, width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.6))
            AsyncImage(url: url) { img in img.resizable().aspectRatio(contentMode: .fit).padding(height * 0.15) } placeholder: { Image(systemName: "sparkles.tv").font(.largeTitle).foregroundStyle(.secondary) }
        }
        .frame(width: width, height: height).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
