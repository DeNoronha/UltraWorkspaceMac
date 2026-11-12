import SwiftUI
import UltraBarKit

struct SettingsView: View {
    @State private var confirmSoftwareUpdate = false
    @State private var confirmForget = false
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @AppStorage(MacPresence.key) private var presence: MacPresence = .dock

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header("Settings", "This bar, its screen, the debug bridge, connection help and what is set on the bar itself.")
            Divider()

            Form {
                Section("CoreBar") {
                    if let bar = model.selectedCoreBar {
                        LabeledContent("Name", value: bar.name)
                        LabeledContent("Serial") { Text(bar.serialNo).textSelection(.enabled) }
                        LabeledContent("Address", value: model.ipForSelected() ?? bar.lastIp)
                        if model.paired.count > 1 {
                            LabeledContent("Paired bars", value: model.paired.map(\.name).joined(separator: ", "))
                        }
                    } else {
                        Text("No CoreBar selected.").foregroundStyle(.secondary)
                    }
                    HStack {
                        Button { model.refreshModules() } label: { Label(model.isWorking ? "Looking for modules…" : "Find modules", systemImage: "magnifyingglass") }
                            .disabled(model.isWorking || model.selectedCoreBar == nil)
                            .help("A live scan of the bar's magnetic bus, about 16 seconds. Tap the bar's screen first so sleeping modules answer.")
                        Button { model.showingConnect = true } label: { Label("Add another CoreBar…", systemImage: "plus") }
                            .help("Find and pair a second bar on this network; the sidebar then offers a switch between them.")
                        if model.selectedCoreBar != nil {
                            Button(role: .destructive) { confirmForget = true } label: { Label("Forget this CoreBar…", systemImage: "trash") }
                                .help("Removes Deckhand's pairing key for this bar; the bar itself is not changed.")
                        }
                    }
                    .alert("Forget this CoreBar?", isPresented: $confirmForget) {
                        Button("Forget", role: .destructive) { if let b = model.selectedCoreBar { model.unpair(b) } }
                        Button("Cancel", role: .cancel) {}
                    } message: { Text("Deckhand removes its pairing key for \(model.selectedCoreBar?.name ?? "this bar"). The bar itself is not changed.") }
                }

                Section("Bar screen") {
                    Toggle("Keep the screen on while someone is at the desk (via ADB)", isOn: $settings.presenceWake)
                        .onChange(of: settings.presenceWake) { on in on ? model.startPresence(settings: settings) : model.stopPresence(settings: settings) }
                    LabeledContent("Switch off after … without anyone") {
                        Stepper(value: $settings.presenceSleepMinutes, in: 1...120) {
                            Text("\(settings.presenceSleepMinutes) min").monospacedDigit().frame(minWidth: 52, alignment: .trailing)
                        }
                    }
                        .disabled(!settings.presenceWake)
                    LabeledContent("Status") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(model.presenceStatus)
                            if let on = model.barScreenOn { Text("Bar screen: \(on ? "on" : "off")").foregroundStyle(.secondary) }
                            if let t = model.lastPresenceAt { Text("Last movement \(Int(Date().timeIntervalSince(t))) s ago").foregroundStyle(.secondary) }
                        }.font(.callout)
                    }
                    Text("Uses the SenseCube's presence sensor through the bar's debug bridge: the bar needs \"Wi-Fi ADB\" on in its Developer options and adb on this Mac (brew install --cask android-platform-tools). The bar's own protocol cannot wake its screen; without this, the bar's Screen timeout setting (max 5 min or never) decides.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                Section("Debug bridge (ADB)") {
                    let st = model.adbStatus
                    let adbOK = st.adbPath != nil, barOK = st.wifi == true && !st.unauthorized, stays = st.persistent == true
                    Text("Deckhand installs its bar apps, restarts the bar's launcher and keeps the bar's screen on through Android's debug bridge. Three steps, once.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    AdbStep(number: 1, title: "adb on this Mac", done: adbOK,
                            detail: adbOK ? st.adbPath! : "Install Android's platform tools: in Terminal, `brew install --cask android-platform-tools` (needs Homebrew), then press Check.")
                    AdbStep(number: 2, title: "Wi‑Fi ADB on at the bar", done: barOK,
                            detail: barOK ? "The bar answers on port 5555 and accepts this Mac."
                                : st.unauthorized ? "The bar is asking whether to allow this Mac: on the bar, tick “Always allow from this computer” and tap Allow, then press Check."
                                : "On the bar: long‑press the Settings button → About tablet → tap Build number seven times (“You are now a developer”) → back → System → Advanced → Developer options → switch on WiFi ADB. Then press Check and allow this Mac when the bar asks. No USB cable: plugging the bar's PC‑LINK port into a computer turns Wi‑Fi ADB off.")
                    AdbStep(number: 3, title: "Stays on after a reboot", done: stays,
                            detail: stays ? "Wi‑Fi ADB comes back by itself after every reboot."
                                : barOK ? "The bar switches Wi‑Fi ADB off at every reboot. Press Keep on after reboots once; Deckhand sets persist.adb.tcp.port=5555 and switches USB debugging on, which Wi‑Fi ADB needs to start at boot."
                                : "Needs step 2 first.")
                    if let m = st.message { Text(m).font(.callout).foregroundStyle(.orange) }
                    HStack {
                        Button { model.checkAdb() } label: { Label("Check", systemImage: "arrow.clockwise") }
                            .disabled(model.adbBusy).help("Look for adb on this Mac and ask the bar whether Wi-Fi ADB answers")
                        Button { model.makeWifiAdbPersistent() } label: { Label("Keep on after reboots", systemImage: "pin") }
                            .disabled(!barOK || stays).buttonStyle(.borderedProminent)
                            .help("setprop persist.adb.tcp.port 5555 and USB debugging on (adb_enabled=1) on the bar")
                        Button { model.enableWifiAdbOverUSB() } label: { Label("Turn on over USB", systemImage: "cable.connector") }
                            .disabled(st.usbSerials.isEmpty || !adbOK)
                            .help(st.usbSerials.isEmpty ? "No bar attached over USB (its PC-LINK port, never the USB-OTG power port)" : "adb tcpip 5555 on the bar attached over USB: Wi-Fi ADB on until its next reboot")
                        if model.adbBusy { ProgressView().controlSize(.small) }
                    }
                    Text("While Wi‑Fi ADB is on, every device on your network can reach a root shell on the bar. Bar hardening below closes that.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Section("Bar hardening") {
                    Toggle("Only this Mac may connect to the bar", isOn: Binding(get: { settings.barFirewall }, set: { on in
                        settings.barFirewall = on; model.setBarFirewall(on)
                    }))
                    .toggleStyle(.switch).disabled(model.adbStatus.wifi != true)
                    switch model.barFirewall {
                    case .on(let mac): Label("On: the bar accepts connections only from \(mac).", systemImage: "lock.shield").foregroundStyle(.green)
                    case .off: Label("Off: every device on your network can reach the bar's debug bridge (a root shell), its upload server and its other services.", systemImage: "lock.open").foregroundStyle(.orange)
                    case .failed(let why): Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    case .unknown: Text(model.adbStatus.wifi == true ? "Checking…" : "Needs the debug bridge (above).").foregroundStyle(.secondary)
                    }
                    Text("A firewall on the bar: on your home network only this Mac may open connections to it (debug bridge, the bar's upload server and services). The VivoCube's own Wi‑Fi link, the bar apps' internet access and Deckhand's beacon are not affected. The bar forgets the rules when it restarts; Deckhand sets them again as soon as it reconnects. If this Mac gets a different address and can no longer reach the bar, restart the bar: the rules are gone until Deckhand sets them with the new address.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                Section("Bar software") {
                    let sw = model.barSoftware, adbOK = model.adbStatus.wifi == true && !model.adbStatus.unauthorized
                    Text("The bar's launcher and bridge service, as installed on the bar and as published by Sanytron on GitHub. Deckhand downloads the newer file, checks that it is the right package, and installs it over the debug bridge; the vendor's desktop app is not needed.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    SoftwareRow(title: "Launcher", package: VendorRelease.launcherPackage, installed: sw.launcher, latest: sw.release?.launcher, update: sw.launcherUpdate != nil)
                    SoftwareRow(title: "Bridge", package: VendorRelease.bridgePackage, installed: sw.bridge, latest: sw.release?.bridge, update: sw.bridgeUpdate != nil)
                    if let r = sw.release {
                        LabeledContent("Latest release") {
                            HStack(spacing: 6) {
                                Text(r.tag + (r.published.map { " · " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""))
                                Link("on GitHub", destination: VendorRelease.pageURL).font(.callout)
                            }
                        }
                    }
                    if let m = sw.message { Text(m).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                    HStack {
                        Button { model.checkBarSoftware() } label: { Label("Check", systemImage: "arrow.clockwise") }
                            .disabled(model.barSoftwareBusy != nil)
                            .help(adbOK ? "Read the versions off the bar and the latest release from GitHub" : "Reads GitHub now; the bar's own versions need the debug bridge (above)")
                        Button { confirmSoftwareUpdate = true } label: { Label(sw.updates.isEmpty ? "Update bar software" : "Update bar software (\(sw.updates.count))", systemImage: "arrow.down.circle") }
                            .buttonStyle(.borderedProminent)
                            .disabled(sw.updates.isEmpty || !adbOK || model.barSoftwareBusy != nil)
                            .help(sw.updates.isEmpty ? "Nothing newer than what the bar has" : "Install " + sw.updates.map(\.name).joined(separator: " and ") + " on the bar")
                        if let b = model.barSoftwareBusy { ProgressView().controlSize(.small); Text(b).font(.callout).foregroundStyle(.secondary) }
                    }
                    .confirmationDialog("Update the bar's software?", isPresented: $confirmSoftwareUpdate, titleVisibility: .visible) {
                        Button("Install " + sw.updates.map(\.name).joined(separator: " and ")) { model.updateBarSoftware() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Deckhand downloads \(sw.updates.map { "\($0.name) (\($0.size / 1_000_000) MB)" }.joined(separator: " and ")) from Sanytron's GitHub release, checks the package inside, and installs it over Wi‑Fi ADB. A new launcher restarts the bar's screen for a few seconds; keep the bar powered. Your pages and pairing stay.")
                    }
                }

                Section("Bar home screen") {
                    let h = model.barHome, adbOK = model.adbStatus.wifi == true && !model.adbStatus.unauthorized
                    Text("What the bar shows when no app is open. Out of the box that is the bar's own launcher with its card pages. Deckhand Home is a plain home screen for the strip: the clock, whether Deckhand is reachable, one tile per installed app, and Settings and the bar's own launcher always within reach. Both keep running; switching is one press either way.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    LabeledContent("Deckhand Home on the bar") {
                        if let i = h.installed { Text("\(i.name) (\(i.code))" + (h.updateAvailable ? " · \(AppModel.homeVersion) available" : "")) }
                        else if h.checkedAt != nil { Text("Not installed").foregroundStyle(.secondary) }
                        else { Text("Not checked yet").foregroundStyle(.secondary) }
                    }
                    LabeledContent("Current home screen") {
                        if h.deckhandIsHome { Text("Deckhand Home") }
                        else if h.vendorIsHome { Text("The bar's own launcher") }
                        else if let c = h.current { Text(c).font(.callout) }
                        else { Text("—").foregroundStyle(.secondary) }
                    }
                    if let m = h.message { Text(m).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                    HStack {
                        Button { model.checkBarHome() } label: { Label("Check", systemImage: "arrow.clockwise") }
                            .disabled(model.barHomeBusy != nil || !adbOK)
                            .help(adbOK ? "Ask the bar what it has and which home screen it uses" : "Needs the debug bridge (above)")
                        Button { model.installBarHome() } label: { Label(h.installed == nil ? "Install Deckhand Home" : h.updateAvailable ? "Update to \(AppModel.homeVersion)" : "Reinstall", systemImage: "arrow.down.circle") }
                            .disabled(model.barHomeBusy != nil || !adbOK)
                            .help("adb install of the DeckhandHome.apk shipped with this build")
                        Button { model.setBarHome(deckhand: true) } label: { Label("Use Deckhand Home", systemImage: "house") }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.barHomeBusy != nil || !adbOK || h.installed == nil || h.deckhandIsHome)
                            .help("cmd package set-home-activity on the bar; the bar's own launcher keeps running")
                        Button { model.setBarHome(deckhand: false) } label: { Label("Use the bar's own home", systemImage: "arrow.uturn.backward") }
                            .disabled(model.barHomeBusy != nil || !adbOK || h.vendorIsHome)
                            .help("Back to the launcher that came with the bar")
                        if let b = model.barHomeBusy { ProgressView().controlSize(.small); Text(b).font(.callout).foregroundStyle(.secondary) }
                    }
                    Text("With Deckhand Home in front, the bar's card pages are one tap away on its UltraBar tile, and the bar's Back key returns to Deckhand Home from any app. The screen timeout above still applies.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                Section("Deckhand on this Mac") {
                    Picker("Show Deckhand in", selection: $presence) {
                        ForEach(MacPresence.allCases) { Text($0.title).tag($0) }
                    }
                    Text(presence == .menuBar
                         ? "Deckhand has no Dock icon and keeps running when you close its window. Open it again from the menu bar icon."
                         : presence == .both
                         ? "The menu bar icon shows whether the bar is connected and opens Deckhand."
                         : "Deckhand is in the Dock like any other app.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    LaunchAtLoginRow()
                }

                Section("Connecting") {
                    ConnectionHelp()
                }

                Section("On the CoreBar itself") {
                    note("Time & timezone", "Set on the CoreBar (Settings → Time), kept by NTP. The protocol has no set-time command.")
                    note("Wi-Fi", "Managed on the CoreBar. The protocol can list nearby networks but cannot join one, so Wi-Fi onboarding stays on the device.")
                    note("Bluetooth", "Managed on the CoreBar (module mesh and PC-wake).")
                }

                Section("Where to find things") {
                    Text("Cards and their settings are on the Widgets page; which cards each screen shows is set on the CoreBar and VivoCube pages. Apps and screensavers have their own pages under Library. Version and license: About Deckhand.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
        }
        .onAppear { if model.adbStatus.checkedAt == nil { model.checkAdb() } }
    }

    private func note(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).fontWeight(.medium)
            Text(body).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One row of the Debug bridge checklist: a tick or a numbered circle, the title, and what to do while it is not done.
private struct AdbStep: View {
    let number: Int, title: String, done: Bool, detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .font(.title3).foregroundStyle(done ? Color.green : Color.secondary).frame(width: 24)
                .accessibilityLabel(done ? "Done" : "Step \(number)")
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(done ? .secondary : .primary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }.padding(.vertical, 2)
    }
}

/// One row of the Bar software section: what is on the bar, what the vendor published, and whether that is newer.
private struct SoftwareRow: View {
    let title: String, package: String, installed: (name: String, code: Int)?, latest: VendorRelease.Asset?, update: Bool
    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(installed.map { "\($0.name) (\($0.code)) on the bar" } ?? "not read from the bar yet")
                if let latest {
                    if update { Tag("update \(latest.versionName)", .orange) }
                    else if installed != nil { Tag("up to date", .green) }
                    else { Text("· latest \(latest.versionName)").foregroundStyle(.secondary) }
                }
            }
        }.help(package)
    }
}
