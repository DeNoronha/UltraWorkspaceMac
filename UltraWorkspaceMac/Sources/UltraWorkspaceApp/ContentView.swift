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
            ToolbarItem { Button { model.showingSettings = true } label: { Label("Settings", systemImage: "gearshape") } }
        }
        .overlay(alignment: .bottom) { StatusBar() }
        .sheet(isPresented: $model.showingSettings) {
            SettingsView().environmentObject(model).environmentObject(settings)
        }
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
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(title: model.selectedCoreBar?.name ?? "CoreBar",
                   subtitle: "\(model.selectedCoreBar?.serialNo ?? "") · \(model.ipForSelected() ?? "")",
                   trailing: AnyView(HStack {
                       Button { model.refreshModules() } label: { Label(model.isWorking ? "Scanning…" : "Refresh / set up", systemImage: "arrow.clockwise") }.disabled(model.isWorking)
                   }))
            Divider()
            HSplitView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Modules").font(.headline)
                    if model.modules.isEmpty {
                        Text("No modules yet. Tap the CoreBar's screen to wake the modules, then press “Refresh / set up”.").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.modules) { m in
                            HStack {
                                Circle().fill(m.online ? .green : .secondary).frame(width: 7, height: 7)
                                Text(m.prettyType).fontWeight(.medium)
                                Text(m.serial).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Open") { model.nav = .module(m.serial) }.buttonStyle(.link)
                            }
                        }
                    }
                    Divider()
                    Text("CoreBar screen (5:1, 1424×280)").font(.headline)
                    Text("Setting the big bar's wallpaper/screensaver is profile-bound and on the roadmap — for now add-ons publish to a VivoCube.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.padding().frame(minWidth: 320)
                ActivityLog().frame(minWidth: 260)
            }
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
                        Text("Display").font(.headline)
                        HStack {
                            Button("Screen On") { push { await $0.setScreen(serial: module.serial, on: true) } }
                            Button("Screen Off") { push { await $0.setScreen(serial: module.serial, on: false) } }
                            Button("Reboot", role: .destructive) { push { await $0.reboot(serial: module.serial) } }
                        }

                        Divider()
                        Text("Publish a widget").font(.headline)
                        Picker("Widget", selection: $model.selectedAddon) {
                            ForEach(Theme.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
                        }.pickerStyle(.radioGroup)
                        Button {
                            model.publishAddon(model.selectedAddon, to: module.serial, settings: settings)
                        } label: { Label("Publish to this VivoCube", systemImage: "square.and.arrow.up") }

                        Divider()
                        Text("Auto-rotate").font(.headline)
                        Text("Cycle through the widgets you enabled in the Widgets section — each stays on screen for \(settings.rotateSeconds)s before the next.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            if model.themeRunning {
                                Button("Stop") { model.stopThemeRotation() }
                                Text("Showing: \(model.currentThemeLabel)").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Button("Start rotation") { model.startThemeRotation(settings: settings) }
                            }
                        }

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
                           "Planned: bind rotation to system/Apple Music volume and the push button to play/pause — driven over the network by this app.",
                           "This needs the inbound knob/button events (next feature)."])
    }
}

private struct DotKeyView: View {
    let module: AttachedModule
    var body: some View {
        DeviceInfo(title: "DotKey", serial: module.serial, systemImage: "square.grid.3x1.below.line.grid.1x2",
                   lines: ["A 3-key mechanical keypad (single / double / long press).",
                           "Planned: bind keys to app shortcuts, hotkeys, media keys and macros.",
                           "This needs the inbound button events (next feature)."])
    }
}

private struct SenseCubeView: View {
    let module: AttachedModule
    var body: some View {
        DeviceInfo(title: "SenseCube", serial: module.serial, systemImage: "sensor.fill",
                   lines: ["mmWave radar + light, temperature, humidity and vibration sensors.",
                           "Planned: live sensor readouts and automations (e.g. presence)."])
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

// MARK: - Add-ons (left list, right settings)

private struct AddonsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(title: "Widgets", subtitle: "Configure, then publish from a VivoCube", trailing: nil)
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
                        HStack {
                            Label(model.selectedAddon.title, systemImage: model.selectedAddon.icon).font(.title3).bold()
                            Spacer()
                            Toggle("In rotation", isOn: Binding(
                                get: { settings.isThemeEnabled(model.selectedAddon) },
                                set: { settings.setTheme(model.selectedAddon, $0) })).toggleStyle(.checkbox)
                        }
                        addonSettings(model.selectedAddon)
                        Divider()
                        HStack {
                            Text("Show each widget for")
                            Picker("", selection: $settings.rotateSeconds) {
                                Text("15s").tag(15); Text("30s").tag(30); Text("1 min").tag(60); Text("3 min").tag(180)
                            }.labelsHidden().frame(width: 90)
                            Text("(only when rotating ≥2 widgets)").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Publish happens from a VivoCube (pick a module in the sidebar → Publish).")
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
        VStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle.angled").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Select a CoreBar").font(.title3)
            Text("Press Scan, then Pair with your CoreBar. Tap Approve on the device when prompted.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            Button("Scan now") { model.scan() }.disabled(model.isScanning)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StatusBar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 8) {
            if model.isScanning || model.isWorking { ProgressView().controlSize(.small) }
            Text(model.statusLine).font(.caption).lineLimit(1)
            Spacer()
        }.padding(.horizontal, 12).padding(.vertical, 6).background(.ultraThinMaterial)
    }
}
