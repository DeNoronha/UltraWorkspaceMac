import SwiftUI
import UltraBarKit

/// The Settings window (⌘,, Deckhand › Settings…): preferences of the Mac app. Tasks on the bar itself (its software,
/// home screen, screen, launcher) are on the Bar System page; help is in the Help window.
struct SettingsWindowView: View {
    @AppStorage(SettingsTab.key) private var tab: SettingsTab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsPane()
                .tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            LocationSettingsPane()
                .tabItem { Label("Location & Units", systemImage: "location") }.tag(SettingsTab.location)
            BarsSettingsPane()
                .tabItem { Label("Bars", systemImage: "rectangle.on.rectangle.angled") }.tag(SettingsTab.bars)
            DebugBridgeSettingsPane()
                .tabItem { Label("Debug Bridge", systemImage: "wrench.and.screwdriver") }.tag(SettingsTab.debugBridge)
            PrivacySettingsPane()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }.tag(SettingsTab.privacy)
        }
        .frame(width: 560)
    }
}

// MARK: General

private struct GeneralSettingsPane: View {
    @AppStorage(MacPresence.key) private var presence: MacPresence = .dock

    var body: some View {
        Form {
            Section {
                Picker("Show Deckhand in", selection: $presence) {
                    ForEach(MacPresence.allCases) { Text($0.title).tag($0) }
                }
                LaunchAtLoginRow()
            } footer: {
                Footnote(presence == .menuBar
                     ? "Deckhand keeps running when you close its window. Open it again from the menu bar icon. While a Deckhand window is open, Deckhand is in the Dock and has its menu bar."
                     : presence == .both ? "The menu bar icon shows whether the bar is connected." : "Deckhand is in the Dock like any other app.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 220)
    }
}

// MARK: Location & Units

/// The one place for where "here" is and how numbers read. Used by the Weather card and app, Flights, Sun & Moon,
/// Tide's almanac, the clock picture and Calendar (it used to be repeated on four pages).
private struct LocationSettingsPane: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Location", selection: $settings.locationMode) {
                    Text("Same as this Mac").tag(AppSettings.LocationMode.auto)
                    Text("A city I choose").tag(AppSettings.LocationMode.manual)
                }
                .pickerStyle(.radioGroup)
                if settings.locationMode == .manual {
                    TextField("City", text: $settings.manualCity, prompt: Text("Amsterdam"))
                    TextField("Latitude", text: $settings.manualLat, prompt: Text("Optional, e.g. 52.37"))
                    TextField("Longitude", text: $settings.manualLon, prompt: Text("Optional, e.g. 4.90"))
                } else {
                    LabeledContent("Time zone", value: settings.macTimeZone)
                }
            } header: {
                Text("Location")
            } footer: {
                Footnote("Used by Weather, Flights, Sun & Moon and Tide.")
            }
            Section {
                Picker("Temperature", selection: $settings.units) {
                    Text("°C").tag(AppSettings.Units.metric)
                    Text("°F").tag(AppSettings.Units.imperial)
                }
                .pickerStyle(.segmented)
                Toggle("24-hour clock", isOn: $settings.clock24h)
            } header: {
                Text("Units")
            } footer: {
                Footnote("Used by the Weather card and app, the clock picture and Calendar.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 400)
    }
}

// MARK: Bars

private struct BarsSettingsPane: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmForget = false

    var body: some View {
        Form {
            Section {
                if model.paired.isEmpty { Text("No CoreBar paired yet.").foregroundStyle(.secondary) }
                ForEach(model.paired) { bar in
                    LabeledContent {
                        if bar.serialNo == model.selectedSerial {
                            Text("In use").foregroundStyle(.secondary)
                        } else {
                            Button("Use") { use(bar) }
                        }
                    } label: {
                        Text(bar.name)
                        Text("\(model.address(for: bar.serialNo) ?? bar.lastIp) · \(bar.serialNo)").textSelection(.enabled)
                    }
                }
                HStack {
                    Button("Add Bar…") { MainWindow.bringForward(); model.showingConnect = true }
                    if let bar = model.selectedCoreBar {
                        Button("Forget “\(bar.name)”…") { confirmForget = true }
                    }
                }
            } header: {
                Text("Paired bars")
            } footer: {
                Footnote("Forgetting removes this Mac's pairing key; the bar itself is not changed.")
            }
            Section {
                if let d = model.selectedCoreBar.flatMap({ b in model.discovered.first { $0.serialNo == b.serialNo } }), !d.version.isEmpty {
                    LabeledContent("Launcher", value: d.version)
                }
                LabeledContent("Modules", value: model.modules.isEmpty ? "None found yet" : model.modules.map(\.prettyType).joined(separator: ", "))
                HStack {
                    Button { model.refreshModules() } label: { Text(model.isWorking ? "Looking for Modules…" : "Find Modules") }
                        .disabled(model.isWorking || model.selectedCoreBar == nil)
                    if model.isWorking { ProgressView().controlSize(.small) }
                }
            } header: {
                Text("This bar")
            } footer: {
                Footnote("Tap the bar's screen first so sleeping modules answer. The scan takes about 16 seconds.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 420)
        .alert("Forget \(model.selectedCoreBar?.name ?? "this bar")?", isPresented: $confirmForget) {
            Button("Forget", role: .destructive) { if let b = model.selectedCoreBar { model.unpair(b) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Deckhand removes its pairing key for this bar. The bar itself is not changed; you can pair it again later.") }
    }

    private func use(_ bar: Store.PairedCoreBar) {
        model.selectedSerial = bar.serialNo
        model.nav = .coreBarPage
        model.modules = []
        model.loadCachedModules()
    }
}

// MARK: Debug Bridge

private struct DebugBridgeSettingsPane: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        let st = model.adbStatus
        let adbOK = st.adbPath != nil, barOK = st.wifi == true && !st.unauthorized, stays = st.persistent == true
        Form {
            Section {
                AdbStep(number: 1, title: "adb on this Mac", done: adbOK,
                        status: adbOK ? "Found." : "Install Android's platform tools.")
                    .help(st.adbPath ?? "brew install --cask android-platform-tools")
                AdbStep(number: 2, title: "WiFi ADB on at the bar", done: barOK,
                        status: barOK ? "The bar accepts this Mac."
                            : st.unauthorized ? "On the bar, tick Always allow from this computer and tap Allow."
                            : "Switch on WiFi ADB in the bar's Developer options.")
                AdbStep(number: 3, title: "Stays on after a reboot", done: stays,
                        status: stays ? "Comes back by itself after a reboot." : barOK ? "Press Keep On After Reboots once." : "Needs step 2 first.")
                if let m = st.message { StatusLabel(m, .attention) }
                HStack {
                    Button("Refresh") { model.checkAdb() }.disabled(model.adbBusy)
                    Button("Keep On After Reboots") { model.makeWifiAdbPersistent() }
                        .disabled(!barOK || stays)
                        .help("Sets the bar's ADB port to stay on and switches USB debugging on.")
                    if !st.usbSerials.isEmpty {
                        Button("Turn On over USB") { model.enableWifiAdbOverUSB() }.disabled(!adbOK)
                            .help("For a bar that adb sees over USB: WiFi ADB on until its next reboot.")
                    }
                    if model.adbBusy { ProgressView().controlSize(.small) }
                    Spacer()
                    HelpButton(.debugBridge)
                }
            } header: {
                Text("Debug bridge")
            } footer: {
                Footnote("Needed for the Deckhand apps, Bar System and keeping the bar's screen on. Set up once.")
            }
            Section {
                Toggle("Only this Mac may connect to the bar", isOn: Binding(get: { settings.barFirewall }, set: { on in
                    settings.barFirewall = on; model.setBarFirewall(on)
                }))
                .disabled(model.adbStatus.wifi != true)
                switch model.barFirewall {
                case .on(let mac): StatusLabel("On: the bar accepts connections only from \(mac).", .ok)
                case .off: StatusLabel("Off: every device on your network can reach the bar's debug bridge.", .attention)
                case .failed(let why): StatusLabel(why, .failed)
                case .unknown: StatusLabel(model.adbStatus.wifi == true ? "Checking…" : "Needs the debug bridge.", .info)
                }
                DetailsDisclosure(text: "A firewall on the bar: on your home network only this Mac may open connections to it (debug bridge, upload server and other services). The VivoCube's Wi\u{2011}Fi link, the bar apps' internet access and Deckhand's beacon keep working. The bar forgets the rules when it restarts; Deckhand sets them again when it reconnects. If this Mac gets a different address and loses the bar, restart the bar.")
            } header: {
                Text("Bar firewall")
            } footer: {
                Footnote("While WiFi ADB is on, anyone on your network can open a shell on the bar. This closes it.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
        .onAppear { if model.adbStatus.checkedAt == nil { model.checkAdb() } }
    }
}

/// One row of the debug bridge checklist: a tick or a numbered circle, the title and one short status line.
private struct AdbStep: View {
    let number: Int, title: String, done: Bool, status: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .font(.title3).foregroundStyle(done ? Color.green : Color.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number), \(title): \(done ? "done" : "not done"). \(status)")
    }
}

// MARK: Privacy

private struct PrivacySettingsPane: View {
    var body: some View {
        Form { PrivacySettingsSection() }
            .formStyle(.grouped)
            .frame(height: 320)
    }
}
