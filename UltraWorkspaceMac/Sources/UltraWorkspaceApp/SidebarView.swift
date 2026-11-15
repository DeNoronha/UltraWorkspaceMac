import SwiftUI
import UltraBarKit

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    private func has(_ type: String) -> Bool { model.modules.contains { $0.type == type } }

    var body: some View {
        List(selection: Binding(get: { model.nav as NavItem? }, set: { if let v = $0 { model.nav = v } })) {
            Section {
                row(.overview)
            }
            if model.selectedCoreBar != nil {
                Section("Bar") {
                    row(.coreBarPage)
                    if has("VIVO_CUBE") { row(.vivoCube, module: "VIVO_CUBE") }
                    if has("KNOB_KEY") || has("DOT_KEY") { row(.controls, module: has("KNOB_KEY") ? "KNOB_KEY" : "DOT_KEY") }
                    if has("SENSE_CUBE") { row(.senseCube, module: "SENSE_CUBE") }
                    row(.barSystem)
                    if model.modules.isEmpty {
                        Button { model.refreshModules() } label: { Label(model.isWorking ? "Looking for Modules…" : "Find Modules", systemImage: "magnifyingglass") }
                            .buttonStyle(.borderless).disabled(model.isWorking)
                            .help("Tap the bar's screen first so the modules are awake.")
                    }
                }
            }
            Section("Library") {
                row(.apps)
                row(.cubeCards)
                row(.screensavers)
            }
            Section {
                row(.logs)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        .safeAreaInset(edge: .top, spacing: 0) { BarChooser() }
        .safeAreaInset(edge: .bottom, spacing: 0) { SettingsRow() }
    }

    /// A page row; a module page says "asleep" when its module did not answer the last scan.
    private func row(_ item: NavItem, module type: String? = nil) -> some View {
        let m = type.flatMap { t in model.modules.first { $0.type == t } }
        return Label {
            HStack {
                Text(item.title)
                Spacer()
                if let m, !m.online { Text("Asleep").font(.caption).foregroundStyle(.secondary) }
            }
        } icon: { Image(systemName: item.symbol) }
        .tag(item)
        .help(m.map { "Serial \($0.serial)" } ?? "")
        .accessibilityLabel(m.map { $0.online ? item.title : "\(item.title), asleep" } ?? item.title)
    }
}

/// Settings at the foot of the sidebar: opens the Settings window (the same as ⌘, and Deckhand › Settings…), which
/// was hard to find from the menu alone (first test, 2026-11-15). A button, not a page: the window is separate.
private struct SettingsRow: View {
    var body: some View {
        Button { SettingsWindow.open() } label: {
            Label("Settings", systemImage: "gearshape")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 18).padding(.vertical, 10)
        .help("Open Deckhand's Settings (⌘,)")
        .accessibilityHint("Opens the Settings window")
    }
}

/// The paired CoreBar at the top of the sidebar, drawn straight on the sidebar's glass (no tile of its own). With more
/// than one paired bar it is a menu to switch between them; adding and forgetting bars is in Settings → Bars.
private struct BarChooser: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.paired.count > 1 {
                Menu {
                    ForEach(model.paired) { bar in
                        Button { select(bar) } label: {
                            if bar.serialNo == model.selectedSerial { Label(bar.name, systemImage: "checkmark") } else { Text(bar.name) }
                        }
                    }
                    Divider()
                    Button("Bar Settings…") { SettingsWindow.open(.bars) }
                } label: { label(switchable: true) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            } else {
                label(switchable: false)
            }
        }
        .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 8)
        .help(model.selectedCoreBar.map { "\($0.serialNo) · \(model.ipForSelected() ?? $0.lastIp)" } ?? "")
    }

    private func label(switchable: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle.angled").font(.title3).foregroundStyle(Color.accentColor).frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.selectedCoreBar?.name ?? "No CoreBar").fontWeight(.semibold).lineLimit(1)
                ConnectionText().font(.callout).lineLimit(1)
            }
            Spacer(minLength: 0)
            if switchable { Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary) }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func select(_ bar: Store.PairedCoreBar) {
        guard bar.serialNo != model.selectedSerial else { return }
        model.selectedSerial = bar.serialNo
        model.nav = .coreBarPage
        model.modules = []
        model.loadCachedModules()
    }
}
