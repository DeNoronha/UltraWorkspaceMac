import SwiftUI
import UltraBarKit

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var ui = UI()
    private final class UI: ObservableObject { @Published var confirmForget = false }

    private func has(_ type: String) -> Bool { model.modules.contains { $0.type == type } }

    var body: some View {
        List(selection: Binding(get: { model.nav as NavItem? }, set: { if let v = $0 { model.nav = v } })) {
            if model.selectedCoreBar != nil {
                Section("Screens") {
                    Label("CoreBar", systemImage: "rectangle.on.rectangle.angled").tag(NavItem.coreBarPage)
                    if has("VIVO_CUBE") { row("VivoCube", "circle.circle", "VIVO_CUBE").tag(NavItem.vivoCube) }
                }
                if has("KNOB_KEY") || has("DOT_KEY") {
                    Section("Controls") {
                        if has("KNOB_KEY") { row("KnobKey", "dial.min", "KNOB_KEY").tag(NavItem.knobKey) }
                        if has("DOT_KEY") { row("DotKey", "square.grid.3x1.below.line.grid.1x2", "DOT_KEY").tag(NavItem.dotKey) }
                    }
                }
                if has("SENSE_CUBE") {
                    Section("Sensors") { row("SenseCube", "sensor.fill", "SENSE_CUBE").tag(NavItem.senseCube) }
                }
                if model.modules.isEmpty {
                    Section {
                        Button { model.refreshModules() } label: { Label(model.isWorking ? "Looking for modules…" : "Find modules", systemImage: "magnifyingglass") }
                            .buttonStyle(.borderless).disabled(model.isWorking)
                    } footer: { Text("Tap the bar's screen first so the modules are awake.").font(.caption) }
                }
            }
            Section("Library") {
                Label("Installed", systemImage: "checkmark.circle").tag(NavItem.installed)
                Label("Widgets", systemImage: "puzzlepiece.extension").tag(NavItem.widgets)
                Label("Apps", systemImage: "bag").tag(NavItem.apps)
                Label("Screensavers", systemImage: "sparkles.tv").tag(NavItem.screensavers)
                Label("People", systemImage: "person.2").tag(NavItem.people)
            }
            Section("Health") {
                Label("Status", systemImage: "stethoscope").tag(NavItem.status)
                Label("Logs", systemImage: "doc.text.magnifyingglass").tag(NavItem.logs)
            }
            Section("Deckhand") {
                Label("Settings", systemImage: "gearshape").tag(NavItem.settings)
                Label("About Deckhand", systemImage: "info.circle").tag(NavItem.about)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
        .safeAreaInset(edge: .top, spacing: 0) { deviceChooser }
        .alert("Forget this CoreBar?", isPresented: $ui.confirmForget) {
            Button("Forget", role: .destructive) { if let b = model.selectedCoreBar { model.unpair(b) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Deckhand removes its pairing key for \(model.selectedCoreBar?.name ?? "this bar"). The bar itself is not changed.") }
    }

    private func row(_ title: String, _ icon: String, _ type: String) -> some View {
        let online = model.modules.first { $0.type == type }?.online ?? false
        return Label {
            HStack { Text(title); Spacer(); if !online { Text("asleep").font(.caption2).foregroundStyle(.secondary) } }
        } icon: { Image(systemName: icon) }
        .help(model.modules.first { $0.type == type }.map { "Serial \($0.serial)" } ?? "")
    }

    /// The paired CoreBar(s): one row with a menu, instead of a sidebar section.
    private var deviceChooser: some View {
        Menu {
            ForEach(model.paired) { bar in
                Button { select(bar) } label: {
                    if bar.serialNo == model.selectedSerial { Label(bar.name, systemImage: "checkmark") } else { Text(bar.name) }
                }
            }
            Divider()
            Button("Add another CoreBar…") { model.showingConnect = true }
            if model.selectedCoreBar != nil {
                Button { model.refreshModules() } label: { Label("Find modules", systemImage: "magnifyingglass") }.disabled(model.isWorking)
                Button("Forget this CoreBar…", role: .destructive) { ui.confirmForget = true }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.on.rectangle.angled").font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.selectedCoreBar?.name ?? "No CoreBar").fontWeight(.semibold)
                    LinkBadge()
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .background(.bar)
        .help(model.selectedCoreBar.map { "\($0.serialNo) · \(model.ipForSelected() ?? $0.lastIp)" } ?? "")
    }

    private func select(_ bar: Store.PairedCoreBar) {
        guard bar.serialNo != model.selectedSerial else { return }
        model.selectedSerial = bar.serialNo
        model.nav = .coreBarPage
        model.modules = []
        model.loadCachedModules()
    }
}
