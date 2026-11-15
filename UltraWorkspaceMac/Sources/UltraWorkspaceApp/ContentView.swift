import SwiftUI
import UltraBarKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    /// Owned by `AppDelegate` with the model, so reopening the window does not create a second copy, and the
    /// background services (started at launch, `AppDelegate.startServices`) run without a window.
    @EnvironmentObject var settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MainWindowLayout()
            // The menu bar icon's "Open Deckhand" opens a new window through this when the last one was closed; the
            // Help button and menu open the Help window the same way.
            .onAppear {
                let open = openWindow
                MainWindow.open = { open(id: MainWindow.id) }
                HelpWindow.openAction = { open(id: HelpWindow.id) }
                PeopleWindow.openAction = { open(id: PeopleWindow.id) }
            }
            .registersSettingsOpener()
            .sheet(isPresented: $model.showingConnect) { ConnectView(asSheet: true).environmentObject(model).frame(width: 520, height: 520) }
            .sheet(isPresented: $model.showingAddIP) { ConnectByAddressSheet().environmentObject(model) }
            .sheet(isPresented: Binding(get: { model.pairingPrompt != nil }, set: { if !$0 { model.pairingPrompt = nil } })) {
                PairingSheet().environmentObject(model)
            }
    }
}

/// The main window's layout: sidebar, the page, and Activity as an inspector on the right. Shared with the developer
/// snapshots (Snapshots.swift), which build the same window without ContentView's start-up wiring.
struct MainWindowLayout: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ActivityInspectorHost {
            NavigationSplitView {
                SidebarView()
            } detail: {
                DetailRouter()
                    .navigationTitle(model.nav.title)
            }
        }
        // The widest minimum is a library page: sidebar (200) + list (240) + detail (320). 1200 before 2026-11-15, with Activity.
        .frame(minWidth: 760, minHeight: 480)
        .toolbar {
            ToolbarItem(placement: .automatic) { ConnectionBadge() }
        }
    }
}

/// Activity on the right of every page: a real inspector on macOS 14 and later (toggled from the toolbar, ⌥⌘I), a
/// plain column on macOS 13.
private struct ActivityInspectorHost<Content: View>: View {
    @EnvironmentObject var model: AppModel
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 14.0, *) {
            content
                .inspector(isPresented: $model.showActivity) {
                    ActivityList().inspectorColumnWidth(min: 220, ideal: 260, max: 380)
                }
                .toolbar { ToolbarItem(placement: .automatic) { toggle } }
        } else {
            HStack(spacing: 0) {
                content.frame(maxWidth: .infinity)
                if model.showActivity { Divider(); ActivityList().frame(width: 260) }
            }
            .toolbar { ToolbarItem(placement: .automatic) { toggle } }
        }
    }

    private var toggle: some View {
        Button { model.showActivity.toggle() } label: { Label("Activity", systemImage: "sidebar.trailing") }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help(model.showActivity ? "Hide Activity (⌥⌘I)" : "Show Activity: what Deckhand did, newest first (⌥⌘I)")
            .accessibilityLabel(model.showActivity ? "Hide Activity" : "Show Activity")
    }
}

// MARK: - Detail router

private struct DetailRouter: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.selectedCoreBar == nil, model.nav.needsBar {
            ConnectView(asSheet: false)
        } else {
            switch model.nav {
            case .overview: OverviewView()
            case .coreBarPage: CoreBarPageView()
            case .vivoCube: moduleView(["VIVO_CUBE"], "VivoCube") { VivoCubeView(module: $0) }
            case .controls: moduleView(["KNOB_KEY", "DOT_KEY"], "KnobKey or DotKey") { _ in ControlsView() }
            case .senseCube: moduleView(["SENSE_CUBE"], "SenseCube") { SenseCubeView(module: $0) }
            case .barSystem: BarSystemView()
            case .apps: AppsView()
            case .cubeCards: CubeCardsView()
            case .screensavers: ScreensaversView()
            case .logs: LogsView()
            }
        }
    }

    @ViewBuilder private func moduleView<V: View>(_ types: [String], _ name: String, _ make: (AttachedModule) -> V) -> some View {
        if let m = model.modules.first(where: { types.contains($0.type) }) { make(m) }
        else { MissingModule(name: name) }
    }
}

private struct MissingModule: View {
    @EnvironmentObject var model: AppModel
    let name: String
    var body: some View {
        EmptyState(icon: "cube", title: "No \(name) Found", text: "Tap the bar's screen so the modules are awake, then look again.") {
            Button { model.refreshModules() } label: { Label("Find Modules", systemImage: "magnifyingglass") }.disabled(model.isWorking)
        }
    }
}

// MARK: - Connection badge

/// "● Connected": the link to the bar, the same words in the toolbar, the sidebar and the menu bar menu.
struct ConnectionText: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(color).imageScale(.small)
            Text(Self.text(model)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.text(model))
    }
    private var symbol: String {
        switch model.link {
        case .connected: return "circle.fill"
        case .connecting, .reconnecting: return "circle.dotted"
        case .stopped: return "exclamationmark.circle.fill"
        }
    }
    private var color: Color {
        switch model.link {
        case .connected: return .green
        case .connecting, .reconnecting: return .secondary
        case .stopped: return .orange
        }
    }
    @MainActor static func text(_ model: AppModel) -> String {
        switch model.link {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .stopped: return model.selectedCoreBar == nil ? "No CoreBar" : "Not connected"
        }
    }
}

/// The toolbar's only status: the connection, with the details (requests answered, the last thing Deckhand did) in a
/// popover. Raw errors never reach the toolbar; they are in the popover's last line, in Activity and on Overview.
private struct ConnectionBadge: View {
    @EnvironmentObject var model: AppModel
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                if model.isScanning || model.isWorking { ProgressView().controlSize(.small) }
                ConnectionText()
            }
            .padding(.horizontal, 4)
        }
        .buttonStyle(.borderless)
        .help("Connection to the bar")
        .popover(isPresented: $open, arrowEdge: .bottom) { ConnectionDetails().environmentObject(model) }
    }
}

private struct ConnectionDetails: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.selectedCoreBar?.name ?? "No CoreBar").font(.headline)
            ConnectionText()
            // The push count and "last request" are plain properties (not published on every request): read every 5 s.
            TimelineView(.periodic(from: .now, by: 5)) { _ in
                VStack(alignment: .leading, spacing: 4) {
                    if let bar = model.selectedCoreBar {
                        LabeledContent("Address", value: model.ipForSelected() ?? bar.lastIp)
                    }
                    if model.link.isConnected {
                        LabeledContent("Requests answered", value: "\(model.pushCount)")
                        if let t = model.lastPushAt { LabeledContent("Last request", value: Self.ago(t)) }
                    }
                }.font(.callout)
            }
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                Text("Last activity").font(.caption).foregroundStyle(.secondary)
                Text(model.statusLine).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            HStack {
                Button("Open Overview") { model.nav = .overview }
                if model.link == .stopped, model.selectedCoreBar != nil { Button("Reconnect") { model.startLink() } }
            }
        }
        .padding(16).frame(width: 300)
    }
    static func ago(_ t: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(t)))
        return s < 120 ? "\(s) s ago" : "\(s / 60) min ago"
    }
}

// MARK: - Activity

/// What Deckhand did, newest first. Kept only while the diagnostic log is on (Settings → Privacy); the last line is
/// always shown, so the inspector is never blank.
struct ActivityList: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        List {
            // While the list is kept its first entry is the latest line; otherwise show that line on its own.
            if model.log.isEmpty {
                Section("Latest") {
                    Text(model.statusLine).font(.callout).textSelection(.enabled)
                }
            }
            Section(model.log.isEmpty ? "Earlier" : "Newest first") {
                if model.log.isEmpty {
                    if WireLog.shared.enabled {
                        Text("Nothing yet.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Activity is kept only while the diagnostic log is on.").font(.callout).foregroundStyle(.secondary)
                            Button("Privacy Settings…") { SettingsWindow.open(.privacy) }
                        }
                    }
                }
                ForEach(model.log) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.time, style: .time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(e.text).font(.callout).textSelection(.enabled)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Activity")
    }
}

// MARK: - First run / add a CoreBar

struct ConnectView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let asSheet: Bool

    private var unpaired: [CoreBar] { model.discovered.filter { d in !model.paired.contains { $0.serialNo == d.serialNo } } }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if model.isScanning, let t0 = model.scanStartedAt {
                        TimelineView(.periodic(from: t0, by: 0.25)) { ctx in
                            ProgressView(value: min(1, ctx.date.timeIntervalSince(t0) / 8)) { Text("Looking on your network…").font(.callout) }
                        }
                    } else {
                        Button { model.scan() } label: { Label(model.discovered.isEmpty ? "Look for CoreBars" : "Look Again", systemImage: "antenna.radiowaves.left.and.right") }
                            .keyboardShortcut(.defaultAction)
                    }
                    ForEach(unpaired) { bar in
                        LabeledContent {
                            Button("Pair") { model.pair(bar) }.disabled(model.isWorking)
                        } label: {
                            Text(bar.name.isEmpty ? bar.serialNo : bar.name)
                            Text(bar.ip)
                        }
                    }
                    if !model.isScanning, model.scanStartedAt == nil, unpaired.isEmpty, !model.paired.isEmpty, asSheet {
                        StatusLabel("All CoreBars found so far are already paired.", .info)
                    }
                    HStack(spacing: 14) {
                        Button("Connect by Address…") { model.showingAddIP = true }
                        Button("Local Network Permission…") {
                            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") { NSWorkspace.shared.open(u) }
                        }.help("macOS asks for Local Network access the first time. If you declined, allow Deckhand there.")
                    }
                } header: {
                    Text("1 · Find the bar")
                } footer: {
                    Footnote("The bar and this Mac must be on the same network.")
                }
                Section("2 · Approve on the bar") {
                    Text("Press Pair, then tap Approve on the bar's screen within 30 seconds. Deckhand then finds the modules on its own.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        // Non-breaking hyphens: "PC‑LINK" and "USB‑OTG" must never break across lines (S15).
                        StatusLabel("Deckhand needs no USB cable. Power the bar from USB\u{2011}OTG and leave PC\u{2011}LINK unplugged.", .attention)
                        Spacer()
                        HelpButton(.connecting)
                    }
                }
            }
            .formStyle(.grouped)
            if asSheet {
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(16)
            }
        }
        .navigationTitle(asSheet ? "Add a CoreBar" : "Connect Your CoreBar")
        .onAppear { if model.discovered.isEmpty, !model.isScanning { model.scan() } }
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
                        Text("\(left)").font(.callout.monospacedDigit())
                    }
                    .accessibilityLabel("\(left) seconds left")
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
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("IP address", text: $draft.ip, prompt: Text("192.168.1.50"))
                } header: {
                    Text("Connect by address")
                } footer: {
                    Footnote("The bar shows its address under Settings → Network.")
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Connect") { model.addCoreBar(byIP: draft.ip) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.ip.trimmingCharacters(in: .whitespaces).isEmpty)
            }.padding(16)
        }.frame(width: 380)
    }
}

// MARK: - Shared building blocks

struct EmptyState<Actions: View>: View {
    let icon: String; let title: String; let text: String; let actions: Actions
    init(icon: String, title: String, text: String, @ViewBuilder actions: () -> Actions) { self.icon = icon; self.title = title; self.text = text; self.actions = actions() }
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.largeTitle).imageScale(.large).foregroundStyle(.secondary)
            Text(title).font(.title3).bold()
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            actions
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(28)
    }
}

/// The one "Replace the bar's pages?" question, asked before a publish that would remove pages made in the
/// official app. Callers set `isPresented` when `model.publishNeedsConfirmation(settings:)` says so.
struct PublishConfirmation: ViewModifier {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @Binding var isPresented: Bool
    func body(content: Content) -> some View {
        content.alert("Replace the bar's pages?", isPresented: $isPresented) {
            Button("Replace Pages", role: .destructive) { model.publishDeckhandPage(settings: settings) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.foreignPages.isEmpty
                 ? "The bar will have two pages: its Standard page and the Deckhand page, with the knob and key bindings. Pages made in the official app would be removed; none were found."
                 : "These pages were made in the official app and will be removed: \(model.foreignPages.map(\.name).joined(separator: ", ")).")
        }
    }
}
extension View {
    func publishConfirmation(isPresented: Binding<Bool>) -> some View { modifier(PublishConfirmation(isPresented: isPresented)) }
}

/// Progress of a Publish or Send to Cube: the steps while it runs, then "Published 4:51" with a tick.
struct ProgressRow: View {
    let progress: StepProgress
    let lastAt: Date?
    let idle: String
    var never: String = "Not sent yet."
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if progress.isEmpty || (!progress.isRunning && progress.failure == nil && progress.succeeded && lastAt != nil && !recent) {
                if let lastAt { StatusLabel("\(idle) \(lastAt.formatted(date: .omitted, time: .shortened))", .ok) }
                else { StatusLabel(never, .info) }
            } else {
                // A flowing row of steps; wraps instead of measuring itself at zero width (the window-jump bug of 2026-11-03).
                HStack(spacing: 10) {
                    ForEach(progress.steps) { st in
                        HStack(spacing: 4) {
                            switch st.state {
                            case .pending: Image(systemName: "circle").foregroundStyle(.secondary).accessibilityLabel("Waiting")
                            case .running: ProgressView().controlSize(.mini)
                            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Done")
                            case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).accessibilityLabel("Failed")
                            }
                            Text(st.title).foregroundStyle(st.state == .pending ? .secondary : .primary)
                            if !st.note.isEmpty { Text(st.note).foregroundStyle(.secondary) }
                        }.font(.callout)
                    }
                }
                if let f = progress.failure { StatusLabel(f, .failed).frame(maxWidth: .infinity, alignment: .leading) }
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

/// A card's icon: the bar's own app icon when there is one, else the SF Symbol.
struct CardIcon: View {
    let card: AppSettings.CoreCard
    var size: CGFloat = 18
    var body: some View {
        if card.imageURL != nil {
            AppIcon(url: card.imageURL, title: card.title, fallback: card.icon, size: size)
        } else {
            Image(systemName: card.icon).frame(width: size, height: size)
        }
    }
}
