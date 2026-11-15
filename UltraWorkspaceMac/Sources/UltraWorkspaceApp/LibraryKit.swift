import SwiftUI
import UltraBarKit

/// Pieces the library pages (Apps, Cube Cards, Screensavers) share, so they look and behave alike.

/// The list filter of Apps and Screensavers, in their filter bar (it replaced the Installed page).
enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, onBar, updates
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All"
        case .onBar: return "On the Bar"
        case .updates: return "Updates"
        }
    }
}

/// A library page: the list on the left, the chosen item's detail (a grouped Form) on the right. A plain list column
/// with a divider, not a nested split view; the window keeps one sidebar and one inspector.
struct LibraryLayout<Bar: View, ListContent: View, Detail: View>: View {
    @ViewBuilder let bar: Bar
    @ViewBuilder let list: ListContent
    @ViewBuilder let detail: Detail
    init(@ViewBuilder bar: () -> Bar, @ViewBuilder list: () -> ListContent, @ViewBuilder detail: () -> Detail) {
        self.bar = bar(); self.list = list(); self.detail = detail()
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) { bar; list }.frame(width: 240)
            Divider()
            detail.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension LibraryLayout where Bar == EmptyView {
    /// A library page without filters (Cube Cards).
    init(@ViewBuilder list: () -> ListContent, @ViewBuilder detail: () -> Detail) {
        self.init(bar: { EmptyView() }, list: list, detail: detail)
    }
}

/// The filter bar of Apps and Screensavers: All / On the Bar / Updates, a name filter, and Refresh.
struct LibraryFilterBar: View {
    @EnvironmentObject var model: AppModel
    @Binding var filter: LibraryFilter
    @Binding var search: String
    var body: some View {
        FilterBar(scopes: LibraryFilter.allCases, scopeTitle: { $0.title }, scope: $filter, search: $search, searchPrompt: "Filter",
                  refresh: { model.refreshAppStore() }, refreshDisabled: !model.link.isConnected,
                  refreshHelp: model.link.isConnected ? "Read the apps on the bar and the marketplace catalogue again (⌘R)" : "Connect to the bar first.")
    }
}

/// A row in a library list: icon, name, a caption, and the state as a symbol with words for VoiceOver.
struct LibraryRow<Icon: View>: View {
    let title: String; var caption: String? = nil; var installed = false; var busy = false; var updateAvailable = false
    @ViewBuilder let icon: Icon
    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).lineLimit(1)
                if let caption { Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 4)
            if busy { ProgressView().controlSize(.mini) }
            else if updateAvailable { Image(systemName: StatusKind.update.symbol).foregroundStyle(StatusKind.update.color).help("Update available") }
            else if installed { Image(systemName: "checkmark.circle").foregroundStyle(.secondary).help("On the bar") }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([title, caption, busy ? "working" : updateAvailable ? "on the bar, update available" : installed ? "on the bar" : nil].compactMap { $0 }.joined(separator: ", "))
    }
}

/// Title block of a detail pane: icon, name, version and a state tag. Package names are not shown here (Details).
struct DetailTitle<Icon: View>: View {
    let title: String; var version: String? = nil; var tag: (String, StatusKind)? = nil
    @ViewBuilder let icon: Icon
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2).bold()
                HStack(spacing: 8) {
                    if let version, !version.isEmpty { Text(version).foregroundStyle(.secondary) }
                    if let tag { Tag(tag.0, tag.1) }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Install / Update / Remove… for an app or screensaver on the bar. Buttons, not a switch: installing takes ten
/// seconds or more and is watched, removing asks first (a switch flipped before the work was done; review P6).
struct InstallControls: View {
    let name: String
    let installed: Bool
    var updateTo: String? = nil
    var busy = false
    var canInstall = true
    var canRemove = true
    /// Why Install or Remove is not offered, shown under the buttons.
    var note: String? = nil
    let install: () -> Void
    let remove: () -> Void
    @State private var confirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if busy {
                    BusyLabel("Working on the bar…")
                } else {
                    if !installed { Button("Install", action: install).primaryInline().disabled(!canInstall) }
                    if installed, let updateTo { Button("Update to \(updateTo)", action: install).primaryInline().disabled(!canInstall) }
                    if installed, canRemove { Button("Remove…") { confirm = true } }
                }
            }
            if let note { StatusLabel(note, .info) }
        }
        .confirmationDialog("Remove \(name) from the bar?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Remove", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        } message: { Text("The app is uninstalled from the bar. You can install it again later.") }
    }
}

/// Turn Off… / Turn On for an app that is part of the bar's firmware (Android's own switch, over the debug bridge).
struct FirmwareControls: View {
    let name: String
    let isOn: Bool
    var busy = false
    var disabled = false
    var note: String? = nil
    let set: (Bool) -> Void
    @State private var confirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if busy { BusyLabel("Working on the bar…") }
                else if isOn { Button("Turn Off…") { confirm = true }.disabled(disabled) }
                else { Button("Turn On") { set(true) }.disabled(disabled) }
            }
            if let note { StatusLabel(note, .info) }
        }
        .confirmationDialog("Turn off \(name)?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Turn Off", role: .destructive) { set(false) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("It disappears from the bar and does not run until you turn it on again here.") }
    }
}

/// A catalogue or install error at the top of a library detail, so it is seen whichever row caused it.
struct LibraryErrorSection: View {
    @EnvironmentObject var model: AppModel
    var includeBarApps = true     // Screensavers has no Deckhand apps, so no barAppError
    var body: some View {
        let errors = [model.appStoreError, includeBarApps ? model.barAppError : nil].compactMap { $0 }
        if !errors.isEmpty {
            Section {
                ForEach(errors, id: \.self) { e in StatusLabel(e, .failed).textSelection(.enabled) }
            }
        }
    }
}

/// "Package", "Web UI": the technical details of an app, folded away.
struct AppDetailsSection: View {
    let package: String
    var inMarketplace = true
    var webUI: URL? = nil
    var body: some View {
        Section {
            DisclosureGroup("Details") {
                LabeledContent("Package") { Text(package).textSelection(.enabled) }
                if !inMarketplace { LabeledContent("Marketplace", value: "Not listed") }
                if let webUI {
                    LabeledContent("Web page on the bar") { Link("Open in Browser", destination: webUI) }
                }
            }
        }
    }
}

/// "Update All (n)": counts only what its page lists (apps on Apps, screensavers on Screensavers; review S6).
struct UpdateAllButton: View {
    @EnvironmentObject var model: AppModel
    let screensavers: Bool
    var body: some View {
        let n = screensavers ? model.screensaverUpdates.count : model.appUpdateCount
        let busy = model.barAppBusy != nil || model.appBusy != nil
        Button { screensavers ? model.updateScreensavers() : model.updateApps() } label: {
            Label(n == 0 ? "Update All" : "Update All (\(n))", systemImage: "arrow.down.circle")
        }
        .labelStyle(.titleAndIcon)
        .prominentAction()
        .disabled(n == 0 || busy)
        .help(busy ? "Waiting for the current install to finish." : n == 0 ? "Everything is up to date." : "Install the newer versions one after another.")
    }
}
