import SwiftUI
import UltraBarKit

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings

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
                    } else {
                        Text("No CoreBar selected.").foregroundStyle(.secondary)
                    }
                }

                Section("Pages from this Mac") {
                    Toggle("Serve the pages only to the bar", isOn: $settings.pagesOnlyForBar)
                        .onChange(of: settings.pagesOnlyForBar) { on in MonitorServer.shared.setPagesOnlyForPeers(on) }
                    Text(settings.monitorServe
                         ? "The bar apps' pages (Monitor, Claude, Calendar, Tasks, …) are served on port 7432 while \"Serve the pages from this Mac\" is on (Apps page). Off: anyone on the network can read them in a browser, handy to preview a page. On: only the paired bar's address and this Mac get them; any other host gets 403. The bar's address is taken from a pinned, authenticated connection, not from discovery alone."
                         : "\"Serve the pages from this Mac\" is off (Apps page), so nothing is served. This switch decides who may read the pages once it is on: everyone on the network (off, lets you preview in a browser) or only the paired bar and this Mac (on).")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                Section("Bar screen") {
                    Toggle("Keep the screen on while someone is at the desk (via ADB)", isOn: $settings.presenceWake)
                        .onChange(of: settings.presenceWake) { on in on ? model.startPresence(settings: settings) : model.stopPresence(settings: settings) }
                    Stepper("Switch off after \(settings.presenceSleepMinutes) min without anyone", value: $settings.presenceSleepMinutes, in: 1...120)
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
                                : "On the bar: long‑press the Settings button → About tablet → tap Build number seven times (“You are now a developer”) → back → System → Advanced → Developer options → switch on WiFi ADB. Then press Check and allow this Mac when the bar asks. Without a free hand: plug the bar's PC‑LINK port into this Mac over USB and press Turn on over USB.")
                    AdbStep(number: 3, title: "Stays on after a reboot", done: stays,
                            detail: stays ? "Wi‑Fi ADB comes back by itself after every reboot."
                                : barOK ? "The bar switches Wi‑Fi ADB off at every reboot. Press Keep on after reboots once; Deckhand sets persist.adb.tcp.port=5555 on the bar."
                                : "Needs step 2 first.")
                    if let m = st.message { Text(m).font(.callout).foregroundStyle(.orange) }
                    HStack {
                        Button { model.checkAdb() } label: { Label("Check", systemImage: "arrow.clockwise") }
                            .disabled(model.adbBusy).help("Look for adb on this Mac and ask the bar whether Wi-Fi ADB answers")
                        Button { model.makeWifiAdbPersistent() } label: { Label("Keep on after reboots", systemImage: "pin") }
                            .disabled(!barOK || stays).buttonStyle(.borderedProminent)
                            .help("setprop persist.adb.tcp.port 5555 on the bar")
                        Button { model.enableWifiAdbOverUSB() } label: { Label("Turn on over USB", systemImage: "cable.connector") }
                            .disabled(st.usbSerials.isEmpty || !adbOK)
                            .help(st.usbSerials.isEmpty ? "No bar attached over USB (its PC-LINK port, never the USB-OTG power port)" : "adb tcpip 5555 on the bar attached over USB: Wi-Fi ADB on until its next reboot")
                        if model.adbBusy { ProgressView().controlSize(.small) }
                    }
                    Text("While Wi‑Fi ADB is on, every device on your network can reach a shell on the bar, so keep the bar on a network you trust.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
