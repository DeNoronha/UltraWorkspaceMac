import SwiftUI
import UltraBarKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var contacts = ContactStore()
    @StateObject private var settings = AppSettings()

    var body: some View {
        NavigationSplitView {
            SidebarView().frame(minWidth: 240)
        } detail: {
            DetailRouter()
        }
        .environmentObject(contacts)
        .environmentObject(settings)
        .onAppear { model.startMusicPolling() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.scan() } label: { Label("Scan", systemImage: "antenna.radiowaves.left.and.right") }
                    .disabled(model.isScanning)
            }
            ToolbarItem { Button { model.showingAbout = true } label: { Label("About", systemImage: "info.circle") } }
            ToolbarItem { Button { model.showingSettings = true } label: { Label("Settings", systemImage: "gearshape") } }
        }
        .overlay(alignment: .bottom) { StatusBar() }
        .sheet(isPresented: $model.showingSettings) {
            SettingsView().environmentObject(model).environmentObject(settings)
        }
        .sheet(isPresented: $model.showingAbout) { AboutView() }
        .sheet(isPresented: $model.showingAddIP) { AddByIPSheet().environmentObject(model) }
        .sheet(isPresented: Binding(get: { model.pairingPrompt != nil },
                                    set: { if !$0 { model.pairingPrompt = nil } })) {
            VStack(spacing: 16) { ProgressView(); Text(model.pairingPrompt ?? "").multilineTextAlignment(.center) }
                .padding(32).frame(width: 360)
        }
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: Binding(get: { model.nav as NavItem? },
                                set: { if let v = $0 { model.nav = v } })) {
            Section("CoreBars") {
                if model.paired.isEmpty && model.discovered.isEmpty {
                    Text("None yet — press Scan ↻").foregroundStyle(.secondary)
                }
                ForEach(model.paired) { bar in
                    Button { selectCoreBar(bar) } label: {
                        HStack {
                            Image(systemName: "rectangle.on.rectangle.angled")
                            VStack(alignment: .leading) {
                                Text(bar.name).fontWeight(.medium)
                                Text(bar.serialNo).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if bar.serialNo == model.selectedSerial { Image(systemName: "checkmark").foregroundStyle(.blue) }
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu { Button("Remove / Unpair", role: .destructive) { model.unpair(bar) } }
                }
                // Discovered-but-not-yet-paired CoreBars show up here to pair.
                ForEach(model.discovered.filter { d in !model.paired.contains { $0.serialNo == d.serialNo } }) { bar in
                    HStack {
                        Image(systemName: "rectangle.on.rectangle.angled").foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(bar.name.isEmpty ? bar.serialNo : bar.name)
                            Text("\(bar.ip) · v\(bar.version)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Pair") { model.pair(bar) }.buttonStyle(.borderless)
                    }
                }
                Button { model.scan() } label: {
                    Label(model.isScanning ? "Scanning…" : "Scan for CoreBars", systemImage: "antenna.radiowaves.left.and.right")
                }.buttonStyle(.borderless).disabled(model.isScanning)
                Button { model.showingAddIP = true } label: {
                    Label("Add by IP…", systemImage: "number")
                }.buttonStyle(.borderless)
            }

            if model.selectedCoreBar != nil {
                Section(model.selectedCoreBar?.name ?? "Device") {
                    Label("Overview", systemImage: "square.grid.2x2").tag(NavItem.coreBar)
                    ForEach(model.modules) { m in
                        Label {
                            HStack { Text(m.prettyType); Spacer()
                                Circle().fill(m.online ? .green : .secondary).frame(width: 6, height: 6) }
                        } icon: { Image(systemName: iconFor(m.type)) }
                        .tag(NavItem.module(m.serial))
                    }
                }
            }

            Section("Configure") {
                Label("Widgets", systemImage: "puzzlepiece.extension").tag(NavItem.addons)
                Label("People", systemImage: "person.2").tag(NavItem.people)
                Label("Logs", systemImage: "doc.text.magnifyingglass").tag(NavItem.logs)
            }

            Section {
                Button { model.showingAbout = true } label: {
                    Label("About Deckhand", systemImage: "info.circle")
                }.buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
    }

    private func selectCoreBar(_ bar: Store.PairedCoreBar) {
        model.selectedSerial = bar.serialNo
        model.nav = .coreBar
        model.modules = []
        // Show the last-known modules instantly from the local cache; the user
        // presses Refresh to rescan the bus. No scan needed on every selection.
        model.loadCachedModules()
    }

    private func iconFor(_ type: String) -> String {
        switch type {
        case "VIVO_CUBE": return "circle.circle"
        case "KNOB_KEY": return "dial.min"
        case "DOT_KEY": return "square.grid.3x1.below.line.grid.1x2"
        case "SENSE_CUBE": return "sensor.fill"
        case "PC_BOOT": return "power"
        default: return "cube"
        }
    }
}

// MARK: - Add by IP

@MainActor final class DraftIP: ObservableObject { @Published var ip = "127.0.0.1" }

private struct AddByIPSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft = DraftIP()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a CoreBar by IP").font(.title3).bold()
            Text("Enter the device's IP address. Useful for a mock CoreBar on localhost, or when discovery can't find it (e.g. across Docker's network).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("192.168.1.50", text: $draft.ip).textFieldStyle(.roundedBorder).frame(width: 260)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") { model.addCoreBar(byIP: draft.ip) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.ip.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(24).frame(width: 340)
    }
}

// MARK: - Detail router

private struct DetailRouter: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        switch model.nav {
        case .addons: AddonsView()
        case .people: PeopleView()
        case .logs: LogsView()
        case .coreBar:
            if model.selectedCoreBar != nil { CoreBarView() } else { Unavailable() }
        case .module(let serial):
            if model.selectedCoreBar != nil, let m = model.modules.first(where: { $0.serial == serial }) { ModuleRouter(module: m) }
            else if model.selectedCoreBar != nil { CoreBarView() } else { Unavailable() }
        }
    }
}

private struct ModuleRouter: View {
    let module: AttachedModule
    var body: some View {
        switch module.type {
        case "VIVO_CUBE": VivoCubeView(module: module)
        case "KNOB_KEY": KnobKeyView(module: module)
        case "DOT_KEY": DotKeyView(module: module)
        case "SENSE_CUBE": SenseCubeView(module: module)
        default: GenericModuleView(module: module)
        }
    }
}

// MARK: - CoreBar overview

private struct CoreBarView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(title: model.selectedCoreBar?.name ?? "CoreBar",
                   subtitle: "\(model.selectedCoreBar?.serialNo ?? "") · \(model.ipForSelected() ?? "")",
                   trailing: AnyView(HStack {
                       Button { model.refreshModules() } label: { Label(model.isWorking ? "Scanning…" : "Refresh / set up", systemImage: "arrow.clockwise") }.disabled(model.isWorking)
                   }))
            Divider()
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        CoreBarPagesView()
                    }.padding().frame(minWidth: 320)
                }
                ActivityLog().frame(minWidth: 260)
            }
        }
    }
}


// MARK: - CoreBar pages (profiles)

/// The CoreBar has no wallpaper: a page is a strip of the device's own cards and
/// our image can only be the clock card's cover. Pages cannot be read back and
/// BATCH_SAVE_PROFILE replaces all of them, so publishing is confirmed every time.
private struct CoreBarPagesView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @StateObject private var pm = PreviewModel()
    @StateObject private var ui = PagesUI()   // @State macro unavailable on CLT-only toolchains
    private final class PagesUI: ObservableObject { @Published var confirmPublish = false }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("CoreBar pages").font(.headline)
                Spacer()
                Button { model.refreshPages() } label: { Label("List pages", systemImage: "list.bullet.rectangle") }
                    .help("Read-only: asks the CoreBar which pages (profiles) exist (ids + names).")
            }
            Text("The CoreBar's big screen shows pages: a strip of the device's own cards (clock, weather, …). There is no full-screen image. Deckhand can add a page whose clock card carries Deckhand's picture.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black)
                    if let img = pm.image {
                        Image(nsImage: img).resizable().interpolation(.high)
                            .frame(width: 140, height: 140).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else if pm.loading { ProgressView() } else { Text("—").foregroundStyle(.secondary) }
                }
                .frame(width: 150, height: 150)
                .onAppear { reload() }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Clock-card cover (480×480, weather & time)").font(.subheadline)
                    Button { ui.confirmPublish = true } label: { Label("Publish Deckhand page…", systemImage: "rectangle.stack.badge.plus") }
                        .disabled(model.isWorking || model.selectedCoreBar == nil)
                    Button { model.refreshDeckhandCover(settings: settings) } label: { Label("Refresh cover only", systemImage: "arrow.triangle.2.circlepath") }
                        .disabled(model.isWorking || model.selectedCoreBar == nil)
                        .help("Re-uploads deckhand/cover.png; the CoreBar repaints the current page without rewriting pages.")
                    Button { reload() } label: { Label("Refresh preview", systemImage: "arrow.clockwise") }.buttonStyle(.borderless)
                }
            }

            if !model.corebarPages.isEmpty {
                Text("Pages on the CoreBar").font(.subheadline)
                ForEach(model.corebarPages, id: \.id) { p in
                    HStack {
                        Image(systemName: model.currentPageId == p.id ? "checkmark.circle.fill" : "circle").foregroundStyle(model.currentPageId == p.id ? .green : .secondary)
                        Text(p.name).fontWeight(.medium)
                        Text(p.id).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Show") { model.switchPage(id: p.id) }.buttonStyle(.link)
                    }
                }
            }
            Label("Publishing rewrites ALL pages on the CoreBar (the device cannot send them back). Deckhand re-sends the standard page plus its own; pages made with the official app other than the standard one are lost — redeploy them from that app if needed. The official app's Deploy, in turn, deletes Deckhand's images.", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
        .alert("Rewrite the CoreBar's pages?", isPresented: $ui.confirmPublish) {
            Button("Publish", role: .destructive) { model.publishDeckhandPage(settings: settings) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces every page on the CoreBar with: the standard page (clock + weather) and a Deckhand page whose clock card shows Deckhand's picture. Pages created in the official app (other than the standard one) will be removed. Known pages right now: \(model.corebarPages.isEmpty ? "not listed yet — press “List pages” first" : model.corebarPages.map(\.name).joined(separator: ", ")).")
        }
    }

    private func reload() {
        pm.reload {
            guard let png = await model.renderPageCover(settings: settings) else { return nil }
            return NSImage(data: png)
        }
    }
}

// MARK: - VivoCube

private struct VivoCubeView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    let module: AttachedModule

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(title: "VivoCube", subtitle: module.serial, trailing: nil)
            Divider()
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        CubePreview()
                        Divider()
                        Text("Display").font(.headline)
                        HStack {
                            Button("Screen On") { push { await $0.setScreen(serial: module.serial, on: true) } }
                            Button("Screen Off") { push { await $0.setScreen(serial: module.serial, on: false) } }
                            Button("Reboot", role: .destructive) { push { await $0.reboot(serial: module.serial) } }
                            Button { model.recoverVivoDisplay(serial: module.serial) } label: {
                                Label("Recover display", systemImage: "bandage")
                            }
                            .help("Black screen? The CoreBar re-applies its cached screen state and layer/widget to the VivoCube. This sets screen on + layer 1 / widget 101.")
                        }
                        Text("Uploads are applied by the VivoCube itself a few seconds after the CoreBar accepts them. \"Screen Off\" is remembered by the CoreBar until you turn it on again.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Menu {
                                ForEach([240, 280, 320, 360, 390, 412, 454, 466, 480], id: \.self) { s in
                                    Button("\(s) × \(s)") { model.sendPanelSizeTest(serial: module.serial, size: s) }
                                }
                            } label: { Label("Panel size test…", systemImage: "ruler") }
                            .frame(width: 180)
                            Text("Experiment: pushes a test pattern of that size. A red frame on all four sides = the panel is at least that big.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }

                        Divider()
                        RotationView(target: .vivocube, publishSerial: module.serial)

                        Divider()
                        Text("Push a custom image").font(.headline)
                        Button { model.chooseAndUploadImage() } label: { Label("Choose image…", systemImage: "photo.badge.arrow.down") }
                            .disabled(model.isWorking)
                        Spacer()
                    }.padding().frame(minWidth: 320)
                }
                ActivityLog().frame(minWidth: 240)
            }
        }
        .onAppear { model.selectedModuleSerial = module.serial }
    }

    private func push(_ op: @escaping (CoreBarSession) async -> Void) {
        guard let bar = model.selectedCoreBar, let session = model.session(for: bar) else { return }
        Task { await op(session); model.say("Sent to \(module.serial).") }
    }
}

// MARK: - Input modules (features differ per device)

private struct KnobKeyView: View {
    let module: AttachedModule
    var body: some View {
        DeviceInfo(title: "KnobKey", serial: module.serial, systemImage: "dial.min",
                   lines: ["A rotary encoder with a push button.",
                           "Feasible: bind a rotation direction to “PC volume” in the device profile; the CoreBar then pushes volume changes to this Mac (act 1000000 / SET_VOLUME), which we apply to the system volume.",
                           "Needs the profile-write path (BATCH_SAVE_PROFILE) — on the roadmap, after the safe preview is confirmed."])
    }
}

private struct DotKeyView: View {
    let module: AttachedModule
    var body: some View {
        DeviceInfo(title: "DotKey", serial: module.serial, systemImage: "square.grid.3x1.below.line.grid.1x2",
                   lines: ["A 3-key keypad (two round + one long key; single / double / long press).",
                           "Feasible: bind a key to a “PC control” scene action in the device profile; a press then pushes to this Mac (act 1000000 / PC_CONTROL), which we map to a shortcut/hotkey/media key.",
                           "Needs the profile-write path (BATCH_SAVE_PROFILE) — on the roadmap, after the safe preview is confirmed."])
    }
}

@MainActor final class SenseReader: ObservableObject {
    @Published var reading: CoreBarSession.SenseReading?
    @Published var updated: Date?
    @Published var busy = false
    private var task: Task<Void, Never>?
    func start(model: AppModel, serial: String) {
        stop()
        task = Task { [weak self] in
            while !Task.isCancelled {
                if let bar = model.selectedCoreBar, let session = model.session(for: bar) {
                    await MainActor.run { self?.busy = true }
                    let r = await session.readSenseCube(serial: serial)
                    await MainActor.run { self?.reading = r; self?.updated = Date(); self?.busy = false }
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
    func stop() { task?.cancel(); task = nil }
}

private struct SenseCubeView: View {
    @EnvironmentObject var model: AppModel
    let module: AttachedModule
    @StateObject private var reader = SenseReader()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(title: "SenseCube", subtitle: module.serial,
                   trailing: AnyView(Button { reader.start(model: model, serial: module.serial) } label: {
                       Label("Refresh", systemImage: "arrow.clockwise") }.disabled(reader.busy)))
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    tile("Temperature", reader.reading?.temperatureC.map { String(format: "%.1f°C", $0) } ?? "—", "thermometer.medium", .orange)
                    tile("Humidity", reader.reading?.humidity.map { String(format: "%.0f%%", $0) } ?? "—", "humidity.fill", .teal)
                    tile("Light", reader.reading?.lux.map { "\($0) lux" } ?? "—", "sun.max.fill", .yellow)
                }
                Text("Presence (mmWave), sound level and vibration are event-only on the device and aren't exposed over the network — so they can't be read remotely yet.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let u = reader.updated {
                    Text("Updated \(u, style: .time) · polling every 5s").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding()
        }
        .onAppear { reader.start(model: model, serial: module.serial) }
        .onDisappear { reader.stop() }
    }

    private func tile(_ label: String, _ value: String, _ icon: String, _ color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 26)).foregroundStyle(color)
            Text(value).font(.title3).bold().monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 120, height: 110)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.4)))
    }
}

private struct GenericModuleView: View {
    let module: AttachedModule
    var body: some View {
        DeviceInfo(title: module.prettyType, serial: module.serial, systemImage: "cube", lines: ["Module."])
    }
}

private struct DeviceInfo: View {
    let title: String; let serial: String; let systemImage: String; let lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(title: title, subtitle: serial, trailing: nil)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: systemImage).font(.system(size: 40)).foregroundStyle(.secondary)
                ForEach(lines, id: \.self) { Text($0).foregroundStyle($0 == lines.first ? .primary : .secondary) }
                Spacer()
            }.padding()
        }
    }
}

// MARK: - Live widget preview (rendered locally, never touches the device)

@MainActor final class PreviewModel: ObservableObject {
    @Published var image: NSImage?
    @Published var loading = false
    private var token = 0
    func reload(_ make: @escaping () async -> NSImage?) {
        token += 1; let t = token; loading = true
        Task { let img = await make(); if t == self.token { self.image = img; self.loading = false } }
    }
}

/// 240×240 square preview for the VivoCube (the panel is square; the bezel only looks round-ish), with a picker to choose the widget.
private struct CubePreview: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @StateObject private var pm = PreviewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Preview").font(.headline)
                Spacer()
                Picker("", selection: $model.selectedAddon) {
                    ForEach(Theme.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
                }.labelsHidden().frame(width: 190)
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh preview")
            }
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black)
                if let img = pm.image {
                    Image(nsImage: img).resizable().interpolation(.high)
                        .frame(width: 200, height: 200).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else if pm.loading {
                    ProgressView()
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .frame(width: 210, height: 210)
            .overlay(Circle().stroke(.white.opacity(0.08), lineWidth: 1).frame(width: 200, height: 200))
            Text("2.0″ square · 240×240").font(.caption2).foregroundStyle(.secondary)
        }
        .onAppear { reload() }
        .onChange(of: model.selectedAddon) { _ in reload() }
    }
    private func reload() { pm.reload { await model.previewImage(model.selectedAddon, settings: settings) } }
}

/// Wide 1424×280 preview for the CoreBar screen (weather today; more later).
private struct BarPreview: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @StateObject private var pm = PreviewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Preview").font(.subheadline).bold()
                Spacer()
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh preview")
            }
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.black)
                if let img = pm.image {
                    Image(nsImage: img).resizable().interpolation(.high).aspectRatio(1424.0/280.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8)).padding(4)
                } else if pm.loading {
                    ProgressView()
                } else {
                    Text("Weather only for now — wide layouts for other widgets are coming.")
                        .font(.caption).foregroundStyle(.secondary).padding(8)
                }
            }
            .frame(maxWidth: 420).frame(height: 420 * 280 / 1424 + 8)
        }
        .onAppear { reload() }
    }
    private func reload() { pm.reload { await model.previewWideImage(.weather, settings: settings) } }
}

// MARK: - Per-device widget rotation (tick widgets + interval + publish)

private struct RotationView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    let target: RotationTarget
    let publishSerial: String?   // VivoCube serial to publish to; nil = not pushable yet (CoreBar)

    private var enabled: [Theme] { settings.enabledList(for: target) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Widget rotation").font(.headline)
            Text(target == .vivocube
                 ? "Tick up to 6 widgets. They are uploaded once as layers; rotation then just switches layers (no re-flash). Contents refresh every few minutes."
                 : "Tick the widgets for the CoreBar's big screen.")
                .font(.caption).foregroundStyle(.secondary)

            ForEach(Theme.allCases) { t in
                Toggle(isOn: Binding(get: { settings.isEnabled(t, for: target) },
                                     set: { settings.setEnabled(t, $0, for: target) })) {
                    Label(t.title, systemImage: t.icon)
                }.toggleStyle(.checkbox)
            }

            Divider()
            HStack(spacing: 8) {
                Text(enabled.count > 1 ? "Show each for" : "Interval").foregroundStyle(.secondary)
                Picker("", selection: target == .vivocube ? $settings.vivoSeconds : $settings.coreSeconds) {
                    Text("15s").tag(15); Text("30s").tag(30); Text("1 min").tag(60); Text("3 min").tag(180)
                }.labelsHidden().frame(width: 90).disabled(enabled.count <= 1)
            }

            HStack(spacing: 12) {
                Button {
                    if target == .vivocube { model.startThemeRotation(settings: settings) }
                } label: {
                    Label(enabled.count > 1 ? "Publish & rotate" : "Publish to \(target == .vivocube ? "VivoCube" : "CoreBar")",
                          systemImage: "square.and.arrow.up")
                }
                .disabled(publishSerial == nil || enabled.isEmpty || model.isWorking)

                if target == .vivocube && model.themeRunning {
                    Button("Stop") { model.stopThemeRotation() }
                    if !model.currentThemeLabel.isEmpty {
                        Text("Showing: \(model.currentThemeLabel)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if target == .corebar {
                Label("Publishing to the CoreBar's big screen is still being reverse-engineered — your selection is saved for when it's ready.",
                      systemImage: "wrench.and.screwdriver")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if enabled.isEmpty {
                Text("Tick at least one widget to publish.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Widget settings (left list, right settings)

private struct AddonsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(title: "Widgets", subtitle: "Configure each widget — pick which ones to show per device on the VivoCube / CoreBar pages", trailing: nil)
            Divider()
            HSplitView {
                List(selection: Binding(get: { model.selectedAddon as Theme? },
                                        set: { if let v = $0 { model.selectedAddon = v } })) {
                    ForEach(Theme.allCases) { t in
                        Label(t.title, systemImage: t.icon).tag(t)
                    }
                }
                .frame(minWidth: 200)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Label(model.selectedAddon.title, systemImage: model.selectedAddon.icon).font(.title3).bold()
                        addonSettings(model.selectedAddon)
                        Divider()
                        Text("Choose where this widget appears and how fast it rotates on the device's page: sidebar → VivoCube (or CoreBar) → Widget rotation.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }.padding().frame(minWidth: 320)
                }
            }
        }
    }

    @ViewBuilder private func addonSettings(_ t: Theme) -> some View {
        switch t {
        case .weather:
            VStack(alignment: .leading, spacing: 10) {
                Text("Live weather + clock via Open-Meteo (free, no API key).").font(.caption).foregroundStyle(.secondary)
                Picker("Location", selection: $settings.locationMode) {
                    Text("Same as this Mac").tag(AppSettings.LocationMode.auto)
                    Text("Manual").tag(AppSettings.LocationMode.manual)
                }.pickerStyle(.radioGroup)
                if settings.locationMode == .manual {
                    TextField("City (e.g. Amsterdam)", text: $settings.manualCity).frame(width: 220)
                    HStack { TextField("Lat", text: $settings.manualLat).frame(width: 90)
                        TextField("Lon", text: $settings.manualLon).frame(width: 90) }
                } else {
                    Text("Timezone: \(settings.macTimeZone)").font(.caption).foregroundStyle(.secondary)
                }
                Picker("Units", selection: $settings.units) {
                    Text("°C").tag(AppSettings.Units.metric); Text("°F").tag(AppSettings.Units.imperial)
                }.pickerStyle(.segmented).frame(width: 140)
                Toggle("24-hour clock", isOn: $settings.clock24h).toggleStyle(.switch)
            }
        case .music:
            MusicControls()
        case .cpu:
            Text("CPU and memory usage of this Mac (iStat-style bars).").font(.callout).foregroundStyle(.secondary)
        case .network:
            Text("Network throughput of this Mac: download and upload per second.").font(.callout).foregroundStyle(.secondary)
        case .claude:
            Text("Claude Code activity: tokens used today and active sessions, read from ~/.claude.").font(.callout).foregroundStyle(.secondary)
        case .battery:
            Text("This Mac's battery charge and power state (a desktop Mac shows “On AC power”).").font(.callout).foregroundStyle(.secondary)
        case .disk:
            Text("Startup-disk usage: how full the drive is, with free/total space.").font(.callout).foregroundStyle(.secondary)
        case .worldclock:
            Text("Current time in Amsterdam, New York and Tokyo.").font(.callout).foregroundStyle(.secondary)
        case .crypto:
            Text("Bitcoin and Ethereum price with 24-hour change (CoinGecko, in EUR — no API key).").font(.callout).foregroundStyle(.secondary)
        case .calendar:
            Text("Your next calendar events. Needs Calendar access (macOS will ask the first time).").font(.callout).foregroundStyle(.secondary)
        case .diskio:
            Text("Live disk read/write throughput of this Mac.").font(.callout).foregroundStyle(.secondary)
        case .topcpu:
            Text("The top CPU-consuming apps on this Mac right now.").font(.callout).foregroundStyle(.secondary)
        case .uptime:
            Text("How long this Mac has been running, plus the 1/5/15-minute load average.").font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct MusicControls: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.nowPlaying.hasTrack ? model.nowPlaying.title : "Nothing playing").fontWeight(.medium)
            Text(model.nowPlaying.hasTrack ? model.nowPlaying.artist : " ").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { model.musicPrevious() } label: { Image(systemName: "backward.fill") }
                Button { model.musicPlayPause() } label: { Image(systemName: model.nowPlaying.isPlaying ? "pause.fill" : "play.fill") }
                Button { model.musicNext() } label: { Image(systemName: "forward.fill") }
                Button { model.musicVolume(-10) } label: { Image(systemName: "speaker.wave.1.fill") }
                Button { model.musicVolume(10) } label: { Image(systemName: "speaker.wave.3.fill") }
            }.buttonStyle(.bordered)
        }
    }
}

// MARK: - People

@MainActor final class DraftContact: ObservableObject {
    @Published var name = ""; @Published var email = ""; @Published var phone = ""
}

private struct PeopleView: View {
    @EnvironmentObject var contacts: ContactStore
    @StateObject private var draft = DraftContact()
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(title: "People", subtitle: "Teams / FaceTime / Mail shortcuts", trailing: nil)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if contacts.contacts.isEmpty { Text("Add someone below.").foregroundStyle(.secondary) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(contacts.contacts) { c in
                            HStack {
                                VStack(alignment: .leading) { Text(c.name).fontWeight(.medium); Text(c.email).font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                Button { PeopleActions.teamsChat(c) } label: { Image(systemName: "message.fill") }.help("Teams chat")
                                Button { PeopleActions.teamsCall(c) } label: { Image(systemName: "phone.fill") }.help("Teams call")
                                Button { PeopleActions.faceTime(c) } label: { Image(systemName: "video.fill") }.help("FaceTime")
                                Button { PeopleActions.mail(c) } label: { Image(systemName: "envelope.fill") }.help("Mail")
                                Button(role: .destructive) { contacts.remove(c) } label: { Image(systemName: "trash") }
                            }.buttonStyle(.borderless).padding(.vertical, 2)
                            Divider()
                        }
                    }
                }
                Divider()
                HStack {
                    TextField("Name", text: $draft.name).frame(width: 130)
                    TextField("name@work.com", text: $draft.email).frame(width: 170)
                    TextField("phone", text: $draft.phone).frame(width: 110)
                    Button("Add") {
                        let n = draft.name.trimmingCharacters(in: .whitespaces); let e = draft.email.trimmingCharacters(in: .whitespaces)
                        guard !n.isEmpty, !e.isEmpty else { return }
                        contacts.add(Contact(name: n, email: e, phone: draft.phone.trimmingCharacters(in: .whitespaces)))
                        draft.name = ""; draft.email = ""; draft.phone = ""
                    }
                }
                Spacer()
            }.padding()
        }
    }
}

// MARK: - Shared

private struct Header: View {
    let title: String; let subtitle: String; let trailing: AnyView?
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title).font(.title2).bold()
                Text(subtitle).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            if let trailing { trailing }
        }.padding()
    }
}

private struct ActivityLog: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activity").font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(model.log) { e in
                        HStack(alignment: .top) {
                            Text(e.time, style: .time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(e.text).font(.caption).textSelection(.enabled)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding()
    }
}

private struct Unavailable: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "rectangle.on.rectangle.angled").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("Connect your UltraBar").font(.title3)
                Text("Make sure the CoreBar and this Mac are on the same Wi-Fi, then Scan and Pair (tap Approve on the device).")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                Button("Scan now") { model.scan() }.disabled(model.isScanning)
                ConnectionHelp().frame(maxWidth: 440).padding(.top, 8)
            }.frame(maxWidth: .infinity).padding(28)
        }
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

private struct StatusBar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 8) {
            if model.isScanning || model.isWorking { ProgressView().controlSize(.small) }
            Text(model.statusLine).font(.caption).lineLimit(1)
            Spacer()
        }.padding(.horizontal, 12).padding(.vertical, 6).modifier(GlassSurface())
    }
}

/// Adopt the macOS 26+ Liquid Glass surface where we previously hand-rolled a
/// material; falls back to the system material on older macOS.
private struct GlassSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Rectangle())
        } else {
            content.background(.ultraThinMaterial)
        }
    }
}
