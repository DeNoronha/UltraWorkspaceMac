import SwiftUI
import UltraBarKit

/// Pieces the four library pages (Installed, Widgets, Apps, Screensavers) share, so they look alike.

/// App icon from the bar (or the catalogue), with a symbol while it loads or when there is none.
struct AppIcon: View {
    let url: URL?; let fallback: String; var size: CGFloat = 32
    var body: some View {
        AsyncImage(url: url) { img in img.resizable() } placeholder: { Image(systemName: fallback).font(.system(size: size * 0.55)).foregroundStyle(.secondary) }
            .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.22))
    }
}

/// Small capsule: "up to date", "update 1.3", "not installed", "built in"…
struct Tag: View {
    let text: String; let color: Color
    init(_ text: String, _ color: Color) { self.text = text; self.color = color }
    var body: some View { Text(text).font(.caption2).padding(.horizontal, 6).padding(.vertical, 1).background(color.opacity(0.2)).clipShape(Capsule()) }
}

/// The one control every library item has: is it installed (on the bar) / in use (on a screen).
/// Switching it on installs or adds; switching it off asks first, then removes.
struct InstalledToggle: View {
    let title: String
    let isOn: Bool
    var busy = false
    var disabled = false
    var note: String? = nil
    var confirmOff: String? = nil      // nil = no confirmation when switching off
    let onChange: (Bool) -> Void
    @State private var confirm = false
    var body: some View {
        HStack(spacing: 10) {
            Toggle(title, isOn: Binding(get: { isOn }, set: { on in
                if on { onChange(true) } else if confirmOff != nil { confirm = true } else { onChange(false) }
            }))
            .toggleStyle(.switch).disabled(disabled || busy)
            if busy { ProgressView().controlSize(.small) }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .alert(confirmOff ?? "", isPresented: $confirm) {
            Button("Remove", role: .destructive) { onChange(false) }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// Title row of a detail pane: icon, name, version and status tag.
struct DetailTitle<Icon: View>: View {
    let title: String; var version: String? = nil; var tag: (String, Color)? = nil; var subtitle: String? = nil
    @ViewBuilder let icon: Icon
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title).font(.title3).bold()
                    if let version { Text(version).foregroundStyle(.secondary) }
                    if let tag { Tag(tag.0, tag.1) }
                }
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.tertiary).textSelection(.enabled) }
            }
        }
    }
}

/// A row in one of the left-hand lists: name, optional version, and a mark when installed / in use.
struct LibraryRow<Icon: View>: View {
    let title: String; var caption: String? = nil; var inUse = false; var busy = false; var updateAvailable = false
    @ViewBuilder let icon: Icon
    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                if let caption { Text(caption).font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
            if busy { ProgressView().controlSize(.mini) }
            else if updateAvailable { Image(systemName: "arrow.down.circle.fill").font(.caption).foregroundStyle(.orange).help("Update available") }
            else if inUse { Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green).help("Installed") }
        }
    }
}

/// "Refresh" (⌘R) — the same button on the Installed, Apps and Screensavers pages.
struct RefreshButton: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Button { model.refreshAppStore() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!model.link.isConnected)
            .help(model.link.isConnected ? "Read the apps on the bar and the marketplace catalogue again (⌘R)" : "Connect to the bar first.")
    }
}

/// "Update all (n)" — the same button on the Installed, Apps and Screensavers pages.
struct UpdateAllButton: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let n = model.updatesAvailable
        let busyName: String? = model.barAppBusy.flatMap { p in AppModel.barAppPages.first { $0.page == p }?.label }
            ?? model.appBusy.map { pkg in (model.barApps.first { $0.packageName == pkg }?.appName) ?? (model.storeApps + model.storeScreensavers).first { $0.package == pkg }?.name ?? pkg }
        HStack(spacing: 8) {
            if let busyName {
                ProgressView().controlSize(.small)
                Text("Installing \(busyName)…").font(.caption).foregroundStyle(.secondary)
            }
            Button { model.updateEverything() } label: { Label(n == 0 ? "Update all" : "Update all (\(n))", systemImage: "arrow.down.circle") }
                .buttonStyle(.borderedProminent).disabled(n == 0 || busyName != nil)
                .help(busyName.map { "Waiting for \($0) to finish installing." } ?? model.updateAllHelp)
        }
    }
}
