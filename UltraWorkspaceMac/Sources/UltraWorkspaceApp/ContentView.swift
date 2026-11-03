import SwiftUI
import UltraBarKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var contacts = ContactStore()
    @StateObject private var settings = AppSettings()

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            HStack(spacing: 0) {
                DetailRouter()
                if model.showActivity {
                    Divider()
                    ActivityLog().frame(width: 280)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar() }
        }
        .environmentObject(contacts)
        .environmentObject(settings)
        .onAppear {
            model.startMusicPolling(); model.startDailyCoverRefresh(settings: settings); model.startClaudeWatch(settings: settings)
            // Resume timed switching if it was on when the app last quit.
            if settings.vivoRotationOn, settings.vivoSwitchMode == .timed, !model.themeRunning { model.sendToCube(settings: settings) }
        }
        .toolbar {
            ToolbarItem { Button { model.showActivity.toggle() } label: { Label("Activity", systemImage: "sidebar.trailing") }
                .help("Show or hide the activity list") }
        }
        .sheet(isPresented: $model.showingConnect) { ConnectView(asSheet: true).environmentObject(model).frame(width: 520, height: 520) }
        .sheet(isPresented: $model.showingAddIP) { ConnectByAddressSheet().environmentObject(model) }
        .sheet(isPresented: Binding(get: { model.pairingPrompt != nil }, set: { if !$0 { model.pairingPrompt = nil } })) {
            PairingSheet().environmentObject(model)
        }
    }
}

// MARK: - Detail router

private struct DetailRouter: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.selectedCoreBar == nil, [.coreBarPage, .vivoCube, .knobKey, .dotKey, .senseCube].contains(model.nav) {
            ConnectView(asSheet: false)
        } else {
            switch model.nav {
            case .coreBarPage: CoreBarPageView()
            case .vivoCube: moduleView("VIVO_CUBE", "VivoCube") { VivoCubeView(module: $0) }
            case .knobKey: moduleView("KNOB_KEY", "KnobKey") { KnobKeyView(module: $0) }
            case .dotKey: moduleView("DOT_KEY", "DotKey") { DotKeyView(module: $0) }
            case .senseCube: moduleView("SENSE_CUBE", "SenseCube") { SenseCubeView(module: $0) }
            case .widgets: WidgetsView()
            case .people: PeopleView()
            case .settings: SettingsView()
            case .about: AboutView()
            case .status: StatusView()
            case .logs: LogsView()
            }
        }
    }

    @ViewBuilder private func moduleView<V: View>(_ type: String, _ name: String, _ make: (AttachedModule) -> V) -> some View {
        if let m = model.modules.first(where: { $0.type == type }) { make(m) }
        else { MissingModule(name: name) }
    }
}

private struct MissingModule: View {
    @EnvironmentObject var model: AppModel
    let name: String
    var body: some View {
        EmptyState(icon: "cube", title: "No \(name) found", text: "Tap the bar's screen so the modules are awake, then look again.") {
            Button { model.refreshModules() } label: { Label("Find modules", systemImage: "magnifyingglass") }.disabled(model.isWorking)
        }
    }
}

// MARK: - First run / add a CoreBar

struct ConnectView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let asSheet: Bool
    @StateObject private var ui = UI()
    private final class UI: ObservableObject { @Published var showWhy = false }

    private var unpaired: [CoreBar] { model.discovered.filter { d in !model.paired.contains { $0.serialNo == d.serialNo } } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(asSheet ? "Add a CoreBar" : "Connect your UltraBar").font(.title2).bold()
                    Text("The bar and this Mac must be on the same Wi-Fi. The USB cable only powers the bar.").foregroundStyle(.secondary)
                }
                Panel("1 · Find the bar") {
                    if model.isScanning, let t0 = model.scanStartedAt {
                        TimelineView(.periodic(from: t0, by: 0.25)) { ctx in
                            ProgressView(value: min(1, ctx.date.timeIntervalSince(t0) / 8)) { Text("Looking on your network…") }
                        }
                    } else {
                        Button { model.scan() } label: { Label(model.discovered.isEmpty ? "Look for CoreBars" : "Look again", systemImage: "antenna.radiowaves.left.and.right") }
                            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    }
                    ForEach(unpaired) { bar in
                        HStack {
                            Image(systemName: "rectangle.on.rectangle.angled")
                            VStack(alignment: .leading) {
                                Text(bar.name.isEmpty ? bar.serialNo : bar.name).fontWeight(.medium)
                                Text(bar.ip).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Pair") { model.pair(bar) }.buttonStyle(.borderedProminent).disabled(model.isWorking)
                        }.padding(.vertical, 2)
                    }
                    if !model.isScanning, model.scanStartedAt == nil, unpaired.isEmpty, !model.paired.isEmpty, asSheet {
                        Text("All CoreBars found so far are already paired.").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 14) {
                        Button("Can't see it? Connect by address…") { model.showingAddIP = true }.buttonStyle(.link)
                        Button("Local Network permission…") {
                            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") { NSWorkspace.shared.open(u) }
                        }.buttonStyle(.link).help("macOS asks for Local Network access the first time. If you declined, allow Deckhand there.")
                    }.font(.caption)
                }
                Panel("2 · Approve on the bar") {
                    Text("After you press Pair, the bar shows an Approve button for 30 seconds. Tap it; Deckhand then finds the modules on its own.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Power the bar from its PC-LINK port via your Mac — never a fast charger.").font(.callout)
                    Button("Why?") { ui.showWhy.toggle() }.buttonStyle(.link).font(.callout)
                        .popover(isPresented: $ui.showWhy) { ConnectionHelp().padding().frame(width: 420) }
                }
                if asSheet { HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) } }
            }.padding(24).frame(maxWidth: 560, alignment: .leading)
        }
        .onAppear { if model.discovered.isEmpty, !model.isScanning { model.scan() } }
    }
}

/// Reusable connection + USB-port guidance. The vendor's two-port design is
/// easy to get dangerously wrong, so we surface it prominently.
struct ConnectionHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Connecting your UltraBar", systemImage: "cable.connector").font(.headline)
            Text("Deckhand controls the CoreBar over your **Wi-Fi / local network** — the Mac and the CoreBar must be on the same network. The USB cable is only for power; there is no USB data link.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Use the correct USB port", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.subheadline.bold())
                    Text("• **PC-LINK** (5 V only) → connect to your Mac / computer USB. Safe and correct.")
                    Text("• **USB-OTG** → charging only (a PD/QC or 12 V adapter).")
                    Text("• ⚠️ Never plug a laptop/PD fast-charger into PC-LINK — it can permanently damage the mainboard.")
                        .foregroundStyle(.orange)
                }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct PairingSheet: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 16) {
            if let t0 = model.pairingStartedAt {
                TimelineView(.periodic(from: t0, by: 1)) { ctx in
                    let left = max(0, 30 - Int(ctx.date.timeIntervalSince(t0)))
                    ZStack {
                        ProgressView(value: Double(left), total: 30).progressViewStyle(.circular).controlSize(.large)
                        Text("\(left)").font(.caption.monospacedDigit())
                    }
                }
            } else { ProgressView() }
            Text("Tap Approve on the bar's screen").font(.headline)
            Text(model.pairingPrompt ?? "").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(32).frame(width: 360)
    }
}

@MainActor final class DraftIP: ObservableObject { @Published var ip = "" }

private struct ConnectByAddressSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft = DraftIP()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect by address").font(.title3).bold()
            Text("Enter the bar's IP address (shown on the bar under Settings → Network).")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("192.168.1.50", text: $draft.ip).textFieldStyle(.roundedBorder).frame(width: 260)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Connect") { model.addCoreBar(byIP: draft.ip) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(draft.ip.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(24).frame(width: 360)
    }
}

// MARK: - Shared building blocks

/// Page title row.
struct Header<Trailing: View>: View {
    let title: String; let subtitle: String; let trailing: Trailing
    init(_ title: String, _ subtitle: String, @ViewBuilder trailing: () -> Trailing) { self.title = title; self.subtitle = subtitle; self.trailing = trailing() }
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2).bold()
                if !subtitle.isEmpty { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer()
            trailing
        }.padding(.horizontal, 20).padding(.vertical, 14)
    }
}
extension Header where Trailing == EmptyView {
    init(_ title: String, _ subtitle: String) { self.init(title, subtitle) { EmptyView() } }
}

/// A grouped section: title, content, optional one-line footer.
struct Panel<Content: View>: View {
    let title: String?; let footer: String?; let content: Content
    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) { self.title = title; self.footer = footer; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.headline) }
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.35)))
            if let footer { Text(footer).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

struct EmptyState<Actions: View>: View {
    let icon: String; let title: String; let text: String; let actions: Actions
    init(icon: String, title: String, text: String, @ViewBuilder actions: () -> Actions) { self.icon = icon; self.title = title; self.text = text; self.actions = actions() }
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).font(.title3).bold()
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            actions
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(28)
    }
}

/// Inline stepper under a Send / Publish button.
struct ProgressRow: View {
    let progress: StepProgress
    let lastAt: Date?
    let idle: String
    var never: String = "Not sent yet."
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if progress.isEmpty || (!progress.isRunning && progress.failure == nil && progress.succeeded && lastAt != nil && !recent) {
                Text(lastAt.map { "\(idle) \($0.formatted(date: .omitted, time: .shortened)) ✓" } ?? never).font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    ForEach(progress.steps) { st in
                        HStack(spacing: 4) {
                            switch st.state {
                            case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
                            case .running: ProgressView().controlSize(.mini)
                            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            }
                            Text(st.title).foregroundStyle(st.state == .pending ? .secondary : .primary)
                            if !st.note.isEmpty { Text(st.note).foregroundStyle(.secondary) }
                        }.font(.caption)
                        if st.id != progress.steps.last?.id { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.quaternary) }
                    }
                }
                // No fixedSize(vertical:) here: this row sits beside a button in an HStack and would be
                // measured at zero width (the window-jump bug of 2026-11-03). A flexible frame wraps instead.
                if let f = progress.failure { Text(f).font(.callout).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var recent: Bool { progress.finishedAt.map { Date().timeIntervalSince($0) < 20 } ?? false }
}

@MainActor final class PreviewModel: ObservableObject {
    @Published var image: NSImage?
    @Published var loading = false
    private var token = 0
    func reload(_ make: @escaping () async -> NSImage?) {
        token += 1; let t = token; loading = true
        Task { let img = await make(); if t == self.token { self.image = img; self.loading = false } }
    }
}

struct ActivityLog: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activity").font(.headline)
            // Plain VStack on purpose: a LazyVStack here makes the ScrollView report its whole
            // content height as minimum on macOS, which pushes the split view taller than the
            // window and clips the top of every column (seen 2026-11-03).
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.log) { e in
                        HStack(alignment: .top) {
                            Text(e.time, style: .time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(e.text).font(.caption).textSelection(.enabled)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 0)
        }.padding()
    }
}

private struct StatusBar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 8) {
            if model.isScanning || model.isWorking { ProgressView().controlSize(.small) }
            Text(model.statusLine).font(.caption).lineLimit(1).truncationMode(.tail)
            Spacer()
            LinkBadge()
        }.padding(.horizontal, 12).padding(.vertical, 6).background(.bar)
    }
}

/// "● Connected · answering the bar" — the same words everywhere.
struct LinkBadge: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(model.linkState == "Live link" ? Color.green : (model.linkState.hasPrefix("Link") ? Color.secondary : Color.orange)).frame(width: 7, height: 7)
            Text(linkText).font(.caption).foregroundStyle(.secondary)
        }
        .help("Deckhand keeps a connection to the bar and answers its questions (CPU, memory, network, storage, volume) so the bar's Mac cards and the KnobKey work.")
        .accessibilityLabel(linkText)
    }
    private var linkText: String {
        switch model.linkState {
        case "Live link": return model.pushCount > 0 ? "Connected · \(model.pushCount) requests answered" : "Connected"
        case "Link off": return model.selectedCoreBar == nil ? "No CoreBar" : "Not connected"
        default: return model.linkState.hasPrefix("Reconnecting") ? "Reconnecting…" : model.linkState
        }
    }
}
