import SwiftUI
import AppKit

/// Help that used to sit in the Settings form ("Connecting", "On the CoreBar itself", the debug bridge walk-through):
/// now a Help window, opened from the Help menu and from every (?) button. The full manual is on the website.
enum HelpTopic: String, CaseIterable, Identifiable {
    case connecting, debugBridge, onTheBar
    static let key = "helpTopic"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .connecting: return "Connecting Your CoreBar"
        case .debugBridge: return "Turning On the Debug Bridge"
        case .onTheBar: return "Settings on the CoreBar Itself"
        }
    }
    var symbol: String {
        switch self {
        case .connecting: return "cable.connector"
        case .debugBridge: return "wrench.and.screwdriver"
        case .onTheBar: return "rectangle.on.rectangle.angled"
        }
    }
    /// The same subject in the online manual (site/manual, built from MANUAL.md).
    var manualAnchor: String {
        switch self {
        case .connecting: return "power--the-usb-cable--read-this-first"
        case .debugBridge: return "turn-on-the-debug-bridge-adb-on-the-bar"
        case .onTheBar: return "settings-on-the-corebar-itself"
        }
    }
}

@MainActor
enum HelpWindow {
    static let id = "help"
    static let manualURL = URL(string: "https://openbarx.com/manual/")!
    /// SwiftUI's `openWindow(id:)`, handed over by the main window when it appears.
    static var openAction: (() -> Void)?

    static func open(_ topic: HelpTopic) {
        UserDefaults.standard.set(topic.rawValue, forKey: HelpTopic.key)
        AppActivation.bringToFront()
        if let openAction { openAction() } else { NSWorkspace.shared.open(manualURL) }
    }
    static func openManual(_ topic: HelpTopic? = nil) {
        let url = topic.flatMap { URL(string: manualURL.absoluteString + "#" + $0.manualAnchor) } ?? manualURL
        NSWorkspace.shared.open(url)
    }
}

/// Help menu: the three topics and the manual.
struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Deckhand Manual") { HelpWindow.openManual() }
            Divider()
            ForEach(HelpTopic.allCases) { t in
                Button(t.title) {
                    UserDefaults.standard.set(t.rawValue, forKey: HelpTopic.key)
                    openWindow(id: HelpWindow.id)
                }
            }
        }
    }
}

struct HelpView: View {
    @AppStorage(HelpTopic.key) private var topic: HelpTopic = .connecting

    var body: some View {
        NavigationSplitView {
            List(HelpTopic.allCases, selection: Binding(get: { topic as HelpTopic? }, set: { if let t = $0 { topic = t } })) { t in
                Label(t.title, systemImage: t.symbol).tag(t)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 250, ideal: 270, max: 320)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch topic {
                    case .connecting: ConnectingHelp()
                    case .debugBridge: DebugBridgeHelp()
                    case .onTheBar: OnTheBarHelp()
                    }
                    Divider()
                    Button("Open This Topic in the Manual") { HelpWindow.openManual(topic) }
                }
                .padding(24).frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .navigationTitle(topic.title)
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}

/// The two USB ports. The vendor's design is easy to get dangerously wrong, so this is spelled out.
private struct ConnectingHelp: View {
    var body: some View {
        Text("Deckhand controls the CoreBar over your network. The Mac and the bar must be on the same network; Deckhand needs no USB cable.")
        Text("The bar has two USB ports").font(.headline)
        HelpStep(symbol: "bolt", title: "USB\u{2011}OTG: power", text: "A fast charger (PD or QC) or the 12 V adapter. Fast charging is fine on this port.")
        HelpStep(symbol: "cable.connector.slash", title: "PC\u{2011}LINK: leave it unplugged", text: "On a computer the bar becomes a USB keyboard, and its WiFi ADB switch turns off, which Deckhand needs for the bar apps.")
        StatusLabel("Never plug a laptop or phone fast charger into PC\u{2011}LINK. It is 5 V only; a 9–20 V charger can damage the bar's mainboard.", .attention)
        Text("Finding the bar").font(.headline)
        Text("If Deckhand does not find the bar, check that it is on the same Wi\u{2011}Fi as this Mac (on the bar: Control Center → Wi\u{2011}Fi) and that Deckhand may use the local network (System Settings → Privacy & Security → Local Network). On another subnet or a VPN, use Connect by Address with the address the bar shows under Settings → Network.")
    }
}

private struct DebugBridgeHelp: View {
    var body: some View {
        Text("Deckhand installs its bar apps, restarts the bar's launcher and keeps the bar's screen on through Android's debug bridge (ADB). You set it up once. Settings → Debug Bridge shows a tick next to each step that is done.")
        HelpStep(symbol: "1.circle", title: "Install adb on this Mac", text: "In Terminal: brew install --cask android-platform-tools (needs Homebrew, brew.sh).")
        HelpStep(symbol: "2.circle", title: "Become a developer on the bar", text: "Long-press the Settings button on the bar's home screen. Open About tablet and tap Build number seven times, until the bar says you are now a developer.")
        HelpStep(symbol: "3.circle", title: "Switch on WiFi ADB", text: "Go back, then System → Advanced → Developer options. Under Debugging, switch on WiFi ADB.")
        HelpStep(symbol: "4.circle", title: "Allow this Mac", text: "In Deckhand, open Settings → Debug Bridge and press Refresh. When the bar asks Allow debugging?, tick Always allow from this computer and tap Allow.")
        HelpStep(symbol: "5.circle", title: "Keep it on after reboots", text: "Press Keep On After Reboots. Without it the bar turns WiFi ADB off at every reboot. Deckhand sets the bar's ADB port to stay at 5555 and switches USB debugging on, which Android needs to start the bridge at boot.")
        StatusLabel("While WiFi ADB is on, every device on your network can open a shell on the bar. Turn on Only this Mac may connect in Settings → Debug Bridge, or keep the bar on a network you trust.", .attention)
        Text("Plugging PC\u{2011}LINK into a computer turns WiFi ADB off. If the bar stops answering after a reboot, switch WiFi ADB on again at the bar and press Keep On After Reboots.")
            .foregroundStyle(.secondary)
    }
}

private struct OnTheBarHelp: View {
    var body: some View {
        Text("A few things can only be set on the bar, because its protocol has no command for them.")
        HelpStep(symbol: "clock", title: "Time and time zone", text: "On the bar: Settings → Time. The bar keeps the time itself over the internet.")
        HelpStep(symbol: "wifi", title: "Wi\u{2011}Fi", text: "Joined on the bar. Deckhand can list nearby networks but cannot join one.")
        HelpStep(symbol: "dot.radiowaves.left.and.right", title: "Bluetooth", text: "Managed on the bar: the module mesh and waking a computer.")
        HelpStep(symbol: "moon", title: "Screen timeout", text: "On the bar: Settings → Screen timeout (30 s to 5 min, or Never). To keep the screen on while someone is at the desk, use Keep the screen on in Bar System.")
    }
}

private struct HelpStep: View {
    let symbol: String, title: String, text: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Color.accentColor).frame(width: 26).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.semibold)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
