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
                    LabeledContent("adb on this Mac", value: st.adbPath ?? "not found — brew install --cask android-platform-tools")
                    LabeledContent("Wi-Fi ADB (port 5555)") {
                        Text(st.wifi.map { $0 ? "reachable" : "off — the bar refuses the connection" } ?? "not checked")
                            .foregroundStyle(st.wifi == false ? .orange : .primary)
                    }
                    LabeledContent("After a reboot") {
                        Text(st.persistent.map { $0 ? "stays on" : "turns off again" } ?? "—")
                            .foregroundStyle(st.persistent == false ? .orange : .primary)
                    }
                    LabeledContent("Over USB", value: st.usbSerials.isEmpty ? "no bar attached" : st.usbSerials.joined(separator: ", "))
                    if let m = st.message { Text(m).font(.callout).foregroundStyle(.orange) }
                    HStack {
                        Button { model.checkAdb() } label: { Label("Check", systemImage: "arrow.clockwise") }
                            .disabled(model.adbBusy).help("Look for adb on this Mac and ask the bar whether Wi-Fi ADB answers")
                        Button { model.enableWifiAdbOverUSB() } label: { Label("Turn on over USB", systemImage: "cable.connector") }
                            .disabled(st.usbSerials.isEmpty || st.adbPath == nil)
                            .help("adb tcpip 5555 on the bar attached over USB: Wi-Fi ADB on until its next reboot")
                        Button { model.makeWifiAdbPersistent() } label: { Label("Keep on after reboots", systemImage: "pin") }
                            .disabled(st.wifi != true || st.persistent == true)
                            .help("setprop persist.adb.tcp.port 5555 on the bar")
                        if model.adbBusy { ProgressView().controlSize(.small) }
                    }
                    Text("Installing the Deckhand apps, restarting the bar's launcher and keeping the screen on all go through Android's debug bridge. The bar's Developer options can turn Wi-Fi ADB on, but it turns off at every reboot. Two ways around that: plug the bar into this Mac over USB and press Turn on over USB (accept the prompt on the bar the first time), then Keep on after reboots so it sticks.")
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
