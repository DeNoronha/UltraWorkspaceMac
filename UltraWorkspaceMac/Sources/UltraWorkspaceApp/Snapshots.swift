import SwiftUI
import AppKit
import UltraBarKit

/// DEVELOPER ONLY: screenshots of every page of the main window, without Screen Recording permission.
///
///     cd UltraWorkspaceMac && swift build && DECKHAND_SNAPSHOTS=/path/to/folder .build/debug/UltraWorkspaceApp
///
/// Add DECKHAND_SNAPSHOT_QUICK=1 for the main pages in light mode only.
///
/// What it does, and what it never does:
/// - Re-launches itself with a throw-away home folder (`CFFIXED_USER_HOME`/`HOME` → `<folder>/.home`), so
///   Store, AppSettings and ContactStore read and write only there. Into it go *sanitized copies* of the
///   real settings (secret keys blanked, Wi-Fi passwords dropped, location set to a fixed city) and the module
///   cache, but **no pairing tokens**: without a token every bar call (`session(for:)`) returns nil, so nothing
///   connects to the bar. Nothing here calls AppDelegate.startServices() (the bar data server on 7432, presence over
///   adb, Music polling) and ContentView is not used; the window is built here from SidebarView + the page views.
///   WireLog is not touched: its on/off switch is a real user setting, so the Logs page shows its "off" state.
///   `adbStatus` is filled in so Bar System and Settings → Debug Bridge do not run `adb`. Public HTTP (Open-Meteo weather, the vendor's app catalogue) is allowed.
/// - Fills the model with demo state (connected link, pages, apps, doctor results, activity) so the pages look
///   like a working setup instead of empty states.
/// - Captures each page in-process: the window (with title bar and toolbar) via the window server's own-window
///   capture when it answers, else `cacheDisplay(in:to:)` of the frame view. Light and dark. The window is brought
///   forward for the run (so controls draw in their active state); detail panes are opened by setting the
///   selection in the model. The Settings panes, the Help window, People and the Add a CoreBar sheet are drawn in
///   windows of their own (the Settings TabView draws as tabs there, not as the Settings window's toolbar).
///   Run from UltraWorkspaceMac/ so the bundled APKs in dist/bar-apps are found.
@MainActor
enum Snapshots {
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["DECKHAND_SNAPSHOTS"], !dir.isEmpty else { return }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        if env["DECKHAND_SNAPSHOT_HOME"] == nil {
            exit(relaunchInSandboxHome(out: out))
        }
        Runner(out: out).run()
        exit(0)
    }

    // MARK: Stage 1: a throw-away home with sanitized copies

    private static func relaunchInSandboxHome(out: URL) -> Int32 {
        let fm = FileManager.default
        let home = out.appendingPathComponent(".home", isDirectory: true)
        try? fm.removeItem(at: home)
        let dst = home.appendingPathComponent("Library/Application Support/UltraWorkspaceMac", isDirectory: true)
        try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
        let src = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/UltraWorkspaceMac", isDirectory: true)

        // settings.json: keys blanked or masked, a fixed city instead of "here".
        if let data = try? Data(contentsOf: src.appendingPathComponent("settings.json")),
           var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for k in obj.keys where ["key", "token", "secret", "password", "pass"].contains(where: { k.lowercased().contains($0) }) {
                if let s = obj[k] as? String { obj[k] = s.isEmpty ? "" : "demo-key-not-real" }
            }
            obj["locationMode"] = "manual"; obj["manualCity"] = "Amsterdam"; obj["manualLat"] = "52.3676"; obj["manualLon"] = "4.9041"
            if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) { try? d.write(to: dst.appendingPathComponent("settings.json")) }
        }
        // corebars.json: name, serial, address and pin only (no hotspot or saved Wi-Fi passwords).
        if let data = try? Data(contentsOf: src.appendingPathComponent("corebars.json")),
           var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let bars = obj["coreBars"] as? [[String: Any]] {
            obj["coreBars"] = bars.map { b in b.filter { ["serialNo", "name", "lastIp", "certSHA256"].contains($0.key) } }
            if let d = try? JSONSerialization.data(withJSONObject: obj) { try? d.write(to: dst.appendingPathComponent("corebars.json")) }
        }
        // Module cache and app data without secrets. Never: tokens/, wire.log, zeekr/.
        for name in ["endpoints", "haven.json", "cask.json", "cask-cache.json"] {
            try? fm.copyItem(at: src.appendingPathComponent(name), to: dst.appendingPathComponent(name))
        }
        // Demo people.
        let people: [Contact] = [Contact(name: "Anna de Vries", email: "anna@example.com", phone: "+31 6 1234 5678"),
                                 Contact(name: "Bram Jansen", email: "bram@example.com"),
                                 Contact(name: "Chris Bakker", email: "chris@example.com", phone: "+31 6 8765 4321")]
        if let d = try? JSONEncoder().encode(people) { try? d.write(to: dst.appendingPathComponent("contacts.json")) }
        var env = ProcessInfo.processInfo.environment
        env["CFFIXED_USER_HOME"] = home.path; env["HOME"] = home.path; env["DECKHAND_SNAPSHOT_HOME"] = home.path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        p.arguments = Array(CommandLine.arguments.dropFirst())
        p.environment = env
        do { try p.run() } catch { print("snapshots: could not relaunch: \(error)"); return 1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    // MARK: Stage 2: build the window, walk the pages, capture

    final class KeyWindow: NSWindow {
        // Draw as the active window (sidebar selection colour, traffic lights) without activating the app.
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
        override var canBecomeKey: Bool { true }
        // Let the full-length renders be taller than the screen.
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    @MainActor final class Runner {
        let out: URL
        let model: AppModel
        let settings = AppSettings()
        let contacts = ContactStore()
        var window: KeyWindow!
        var written: [String] = []

        init(out: URL) {
            self.out = out
            model = AppModel()   // no token in the sandbox home: startLink() stops at once
        }

        func pump(_ seconds: TimeInterval) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { RunLoop.main.run(mode: .default, before: min(end, Date().addingTimeInterval(0.05))) }
        }

        func run() {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            app.finishLaunching()
            seed()
            fetchCatalogue()

            let root = SnapshotRoot().environmentObject(model).environmentObject(settings).environmentObject(contacts)
            let host = NSHostingView(rootView: AnyView(root))
            if #available(macOS 14.0, *) { host.sceneBridgingOptions = [.toolbars, .title] }
            let w = KeyWindow(contentRect: NSRect(x: 80, y: 80, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
            w.title = "Deckhand"
            w.isReleasedWhenClosed = false
            w.toolbar = NSToolbar(identifier: "snapshots")
            w.toolbarStyle = .unified
            w.contentView = host
            w.setFrame(NSRect(x: 80, y: 80, width: 1280, height: 820), display: true)
            // Bring the window forward so controls render in their active state (accent-tinted switches, coloured
            // traffic lights); a background window draws them grey. No input is sent to any other app.
            app.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            window = w

            var pages: [(NavItem, String)] = [(.overview, "overview"), (.coreBarPage, "corebar")]
            let has: (String) -> Bool = { t in self.model.modules.contains { $0.type == t } }
            if has("VIVO_CUBE") { pages.append((.vivoCube, "vivocube")) }
            if has("KNOB_KEY") || has("DOT_KEY") { pages.append((.controls, "controls")) }
            if has("SENSE_CUBE") { pages.append((.senseCube, "sensecube")) }
            pages += [(.barSystem, "barsystem"), (.apps, "apps"), (.cubeCards, "cubecards"), (.screensavers, "screensavers"), (.logs, "logs")]

            let wasActivity = model.showActivity
            for (appearanceName, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let a = NSAppearance(named: appearanceName)
                app.appearance = a; w.appearance = a
                model.showActivity = false
                for (i, (nav, name)) in pages.enumerated() {
                    model.nav = nav
                    pump(i == 0 ? 4 : 1.6)
                    if nav == .overview { seedDoctor(); pump(0.6) }
                    capture(String(format: "%02d-%@-%@", i + 1, name, suffix))
                }
                // Activity inspector on.
                model.showActivity = true; model.nav = .coreBarPage; pump(1.5)
                capture("20-corebar-with-activity-\(suffix)")
                model.showActivity = false
                // DECKHAND_SNAPSHOT_QUICK=1: the main pages in light only, for a fast look while working on a page.
                if ProcessInfo.processInfo.environment["DECKHAND_SNAPSHOT_QUICK"] != nil { break }
                // The narrowest window the layout allows.
                let normal = w.frame
                w.setFrame(NSRect(x: normal.minX, y: normal.minY, width: 760, height: 600), display: true)
                model.nav = .apps; pump(1.4)
                capture("21-apps-narrow-\(suffix)", preferWindowServer: false)
                // A tall full-length render of the long pages.
                w.setFrame(NSRect(x: normal.minX, y: normal.minY, width: 1280, height: 2200), display: true)
                for (nav, name) in [(NavItem.overview, "overview"), (.coreBarPage, "corebar"), (.vivoCube, "vivocube"), (.barSystem, "barsystem"), (.controls, "controls")] where pages.contains(where: { $0.0 == nav }) {
                    model.nav = nav; pump(1.4)
                    if nav == .overview { seedDoctor(); pump(0.4) }
                    capture("30-\(name)-full-\(suffix)", preferWindowServer: false)
                }
                w.setFrame(normal, display: true)
                // Detail panes: the selection is in the model.
                model.nav = .apps; pump(1.0)
                for (row, page) in [("claude", "claude"), ("weather", "weather"), ("training", "strava"), ("whisky-portfolio", "cask"), ("schiphol", "schiphol"), ("haven", "haven"), ("teletekst", "teletekst")] {
                    model.selectedApp = BarPages.package(for: page); pump(1.6)
                    capture("40-apps-\(row)-\(suffix)")
                }
                if let market = model.storeApps.first {
                    model.selectedApp = market.package; pump(1.6)
                    capture("40-apps-marketplace-\(suffix)")
                }
                model.nav = .cubeCards; pump(1.0)
                for t in [Theme.date, .claude, .crypto] {
                    model.selectedAddon = t; pump(1.6)
                    capture("40-cubecards-\(t.rawValue)-\(suffix)")
                }
                // Settings panes, Help and People in windows of their own.
                for tab in SettingsTab.allCases {
                    UserDefaults.standard.set(tab.rawValue, forKey: SettingsTab.key)
                    side(SettingsWindowView().environmentObject(model).environmentObject(settings), size: NSSize(width: 560, height: 600), appearance: a, name: "60-settings-\(tab.rawValue)-\(suffix)")
                }
                for topic in HelpTopic.allCases {
                    UserDefaults.standard.set(topic.rawValue, forKey: HelpTopic.key)
                    side(HelpView(), size: NSSize(width: 760, height: 560), appearance: a, name: "70-help-\(topic.rawValue)-\(suffix)")
                }
                side(PeopleView().environmentObject(contacts), size: NSSize(width: 520, height: 480), appearance: a, name: "80-people-\(suffix)")
                // The Add a CoreBar sheet (scan state faked: no network scan).
                model.isScanning = true; model.scanStartedAt = Date()
                side(ConnectView(asSheet: true).environmentObject(model).frame(width: 520, height: 520), size: NSSize(width: 520, height: 520), appearance: a, name: "50-connect-sheet-\(suffix)")
                model.isScanning = false; model.scanStartedAt = nil
            }
            model.showActivity = wasActivity
            print("snapshots: wrote \(written.count) files to \(out.path)")
            for f in written { print("  \(f)") }
        }

        /// Draws `view` in a window of its own and captures it.
        func side<V: View>(_ view: V, size: NSSize, appearance: NSAppearance?, name: String) {
            let win = KeyWindow(contentRect: NSRect(x: 200, y: 200, width: size.width, height: size.height), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            win.appearance = appearance
            let host = NSHostingView(rootView: view)
            if #available(macOS 14.0, *) { host.sceneBridgingOptions = [.toolbars, .title] }
            win.contentView = host
            win.orderBack(nil); pump(1.4)
            capture(name, in: win)
            win.orderOut(nil)
        }

        // MARK: Demo state

        func seed() {
            model.link = .connected
            model.pushCount = 1842
            model.lastPushAt = Date().addingTimeInterval(-3)
            model.lastVolumePushAt = Date().addingTimeInterval(-40)
            model.adbStatus = AdbStatus(adbPath: "/opt/homebrew/bin/adb", wifi: true, persistent: true, checkedAt: Date())
            model.barFirewall = .unknown
            model.corebarPages = [Self.page(AppModel.defaultPageId, "Standard"), Self.page(AppModel.deckhandPageId, "Deckhand")]
            model.currentPageId = AppModel.deckhandPageId
            model.lastPagePublishedAt = Date().addingTimeInterval(-3600 * 3)
            model.lastCoverRefreshAt = Date().addingTimeInterval(-1200)
            model.barScreenOn = true
            model.vivoLayerNames = settings.vivoCards.map(\.title)
            model.vivoLayerShowing = model.vivoLayerNames.isEmpty ? nil : 1
            model.vivoScreenOn = true
            model.lastCubeSentAt = Date().addingTimeInterval(-1800)
            model.nowPlaying = AppleMusic.NowPlaying(isPlaying: true, title: "Holocene", artist: "Bon Iver", album: "Bon Iver, Bon Iver", hasTrack: true)
            model.lastWeather = OpenMeteo.Now(temperature: 11, unitSuffix: "°C", code: 2, sky: .cloudy, isDay: true, humidity: 78, windSpeed: 18, windSuffix: "km/h", place: "Amsterdam")
            model.barDataURL = "http://192.168.1.20:7432"
            model.presenceStatus = "On: the bar sleeps after 5 min away, wakes when you are back."
            model.lastPresenceAt = Date().addingTimeInterval(-25)
            let v = AppModel.barAppsVersion
            var apps: [CoreBarSession.AppInfo] = AppModel.barAppPages.enumerated().compactMap { i, p in
                // Most Deckhand apps installed at the current version, one a version behind, two not installed.
                guard !["teletekst", "verse"].contains(p.page) else { return nil }
                return Self.app(BarPages.package(for: p.page), p.label, p.page == "tide" ? "2.2" : v)
            }
            apps += [Self.app("com.ultrabar.calculator", "Calculator", "1.0.4"), Self.app("com.ultrabar.worldclock", "World Clock", "1.2.0"),
                     Self.app("com.ultrabar.settings", "Settings", "1.0.3", system: true), Self.app("com.ultrabar.music", "Music", "1.1.0", system: true),
                     Self.app("com.ultrabar.screensaver.aquarium", "Aquarium", "1.0.2", screensaver: true),
                     Self.app("com.ultrabar.screensaver.clock", "Flip Clock", "1.1.0", screensaver: true)]
            model.barApps = apps
            model.screensaver = CoreBarSession.ScreensaverConfig(featureEnabled: true, lockTime: "TIME_2MIN", packageName: "com.ultrabar.screensaver.clock", uri: nil, ver: 2)
            for line in ["Connected to ultrabar.", "Cube: sent 3 cards (Date, Weather, Calendar).", "Weather: 11 °C partly cloudy in Amsterdam.",
                         "Deckhand page published: 6 cards.", "Bar apps: config pushed to 14 apps.", "Claude: 2 sessions, 1 waiting for you."] {
                model.say(line)
                // Activity is kept only while the diagnostic log is on, which is a real user setting: fill the list
                // directly so the inspector shows entries.
                model.log.insert(AppModel.LogEntry(text: line), at: 0)
            }
        }

        /// The vendor's public catalogue (what Apps / Screensavers list), so those pages show real entries.
        func fetchCatalogue() {
            final class Box: @unchecked Sendable { var apps: [BarAppStore.StoreApp] = []; var savers: [BarAppStore.StoreApp] = []; var done = false }
            let box = Box()
            Task.detached {
                box.apps = (try? await BarAppStore.fetch()) ?? []
                box.savers = (try? await BarAppStore.fetch(appType: BarAppStore.screensaversType)) ?? []
                box.done = true
            }
            let end = Date().addingTimeInterval(20)
            while !box.done && Date() < end { pump(0.1) }
            model.storeApps = box.apps; model.storeScreensavers = box.savers
            // Mark the catalogue entries that the demo bar "has" as installed, one with an update.
            for a in box.apps.prefix(2) + box.savers.prefix(2) {
                model.appStatus[a.package] = Self.status(installed: true, code: max(1, a.versionCode - (a.package == box.apps.first?.package ? 1 : 0)), name: a.versionName)
                if !model.barApps.contains(where: { $0.packageName == a.package }) {
                    model.barApps.append(Self.app(a.package, a.name, a.versionName, screensaver: box.savers.contains(a)))
                }
            }
        }

        func seedDoctor() {
            let bar = model.selectedCoreBar?.name ?? "ultrabar"
            model.doctorItems = [
                DoctorItem(group: "VivoCube", name: "Last upload", state: .warn, detail: "Accepted 30 min ago, but the cube reported a weak Wi-Fi signal (-78 dBm)."),
                DoctorItem(group: "CoreBar", name: "Connected", state: .ok, detail: "\(bar) accepts this Mac."),
                DoctorItem(group: "CoreBar", name: "Answering the bar", state: .ok, detail: "1842 requests answered · last 3 s ago"),
                DoctorItem(group: "CoreBar", name: "Pages", state: .ok, detail: "Standard, Deckhand · showing Deckhand (as set by Deckhand)"),
                DoctorItem(group: "VivoCube", name: "Wi-Fi", state: .ok, detail: "Connected to the CoreBar's hotspot."),
                DoctorItem(group: "VivoCube", name: "Screen", state: .ok, detail: "On"),
                DoctorItem(group: "VivoCube", name: "Cards", state: .info, detail: settings.vivoCards.map(\.title).joined(separator: ", ") + " · switching every \(settings.vivoSeconds) s"),
                DoctorItem(group: "SenseCube", name: "Readings", state: .ok, detail: "21.4 °C · 46 % · 312 lux"),
                DoctorItem(group: "KnobKey", name: "Volume link", state: .ok, detail: "The bar asked or set the volume 40 s ago"),
                DoctorItem(group: "Modules", name: "Known modules", state: .ok, detail: model.modules.map(\.prettyType).joined(separator: ", ")),
                DoctorItem(group: "Mac", name: "Weather (Open-Meteo)", state: .ok, detail: "11°C Partly cloudy in Amsterdam"),
                DoctorItem(group: "Mac", name: "Data for the bar apps", state: .ok, detail: "Served at http://192.168.1.20:7432 to the selected bar only."),
                DoctorItem(group: "Mac", name: "Versions", state: .info, detail: "Deckhand dev · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"),
            ]
            model.doctorRanAt = Date()
        }

        // UltraBarKit's value types have no public memberwise init; these mirrors have the same stored layout.
        private struct PageMirror { let id: String; let name: String }
        private struct AppMirror { let packageName: String, appName: String, versionName: String; let systemApp: Bool, allowProfile: Bool, isScreensaver: Bool; let port: Int?, sessionToken: String?, iconUrl: String? }
        private struct StatusMirror { let installed: Bool; let versionCode: Int; let versionName: String }
        static func page(_ id: String, _ name: String) -> CoreBarSession.PageInfo { unsafeBitCast(PageMirror(id: id, name: name), to: CoreBarSession.PageInfo.self) }
        static func app(_ pkg: String, _ name: String, _ ver: String, system: Bool = false, screensaver: Bool = false) -> CoreBarSession.AppInfo {
            unsafeBitCast(AppMirror(packageName: pkg, appName: name, versionName: ver, systemApp: system, allowProfile: !screensaver, isScreensaver: screensaver, port: nil, sessionToken: nil, iconUrl: nil), to: CoreBarSession.AppInfo.self)
        }
        static func status(installed: Bool, code: Int, name: String) -> CoreBarSession.AppStatus {
            unsafeBitCast(StatusMirror(installed: installed, versionCode: code, versionName: name), to: CoreBarSession.AppStatus.self)
        }

        // MARK: Capture

        private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        private static let createImage: CreateImage? = {
            guard let h = dlopen(nil, RTLD_NOW), let s = dlsym(h, "CGWindowListCreateImage") else { return nil }
            return unsafeBitCast(s, to: CreateImage.self)
        }()

        func capture(_ name: String, in win: NSWindow? = nil, preferWindowServer: Bool = true) {
            let w = win ?? window!
            w.displayIfNeeded()
            var png: Data?
            // 1. The window server's picture of our own window: real Liquid Glass and title bar. Own windows need no permission.
            if preferWindowServer, let f = Self.createImage,
               let img = f(.null, 1 << 3 /* optionIncludingWindow */, UInt32(w.windowNumber), (1 << 0) | (1 << 3) /* ignore framing, best resolution */)?.takeRetainedValue(),
               img.width > 10, !Self.isBlank(img) {
                png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
            }
            // 2. Fallback: AppKit draws the frame view (title bar, toolbar, content) into a bitmap. Glass may render flat.
            if png == nil, let v = w.contentView?.superview ?? w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                png = rep.representation(using: .png, properties: [:])
            }
            guard let png else { print("snapshots: nothing captured for \(name)"); return }
            let url = out.appendingPathComponent(name + ".png")
            try? png.write(to: url)
            written.append(url.lastPathComponent)
        }

        private static func isBlank(_ img: CGImage) -> Bool {
            guard let data = img.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return true }
            let n = CFDataGetLength(data)
            var nonZero = 0
            var i = 0
            while i < n { if p[i] != 0 { nonZero += 1 }; i += max(4, n / 4000) }
            return nonZero < 10
        }
    }
}

/// The main window without ContentView's start-up wiring (servers, polling, adb): the app's own layout.
private struct SnapshotRoot: View {
    var body: some View { MainWindowLayout() }
}
