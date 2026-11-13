import Foundation
import SwiftUI
import AppKit
import UltraBarKit

@MainActor
final class AppModel: ObservableObject {
    // CoreBars
    @Published var discovered: [CoreBar] = []
    @Published var paired: [Store.PairedCoreBar] = Store.shared.pairedCoreBars
    @Published var selectedSerial: String? { didSet { if oldValue != selectedSerial { startLink() } } }

    // Selected CoreBar state
    @Published var modules: [AttachedModule] = []
    @Published var selectedModuleSerial: String?

    // UI state
    @Published var isScanning = false
    @Published var isWorking = false
    @Published var statusLine = "Ready."
    @Published var log: [LogEntry] = []
    @Published var pairingPrompt: String?
    @Published var showingAddIP = false
    @Published var showingConnect = false
    @Published var nav: NavItem = .coreBarPage
    @Published var showActivity = UserDefaults.standard.bool(forKey: "showActivity") { didSet { UserDefaults.standard.set(showActivity, forKey: "showActivity") } }
    @Published var scanStartedAt: Date?
    @Published var pairingStartedAt: Date?
    @Published var selectedAddon: Theme = .weather

    // Music
    @Published var nowPlaying = AppleMusic.NowPlaying(isPlaying: false, title: "", artist: "", album: "", hasTrack: false)
    var musicPollTask: Task<Void, Never>?

    // Weather
    @Published var lastWeather: OpenMeteo.Now?

    // Theme carousel
    @Published var themeRunning = false
    @Published var currentThemeLabel = ""
    @Published var corebarPages: [CoreBarSession.PageInfo] = []
    /// Apps installed on the bar (GET_APP_LIST). Each becomes an "Open <app>" bar card (`APP:<package>`).
    @Published var barApps: [CoreBarSession.AppInfo] = []
    /// Firmware apps Android has turned off on the bar (`pm list packages -d`), see AppModel+Apps.
    @Published var turnedOffApps: Set<String> = []
    /// Apps page: the vendor marketplace catalogue, per-package install status, the package being worked on.
    @Published var storeApps: [BarAppStore.StoreApp] = []
    @Published var storeScreensavers: [BarAppStore.StoreApp] = []
    @Published var appStatus: [String: CoreBarSession.AppStatus] = [:]
    @Published var appBusy: String?
    @Published var appStoreError: String?
    /// Marketplace entries whose file turned out to be older than the entry says (package → the catalogue versionCode
    /// that was tried): the bar installed it and stayed on the same version, so it is not offered again for that entry.
    @Published var staleCatalogue: [String: Int] = (UserDefaults.standard.dictionary(forKey: "staleCatalogue") as? [String: Int]) ?? [:] {
        didSet { UserDefaults.standard.set(staleCatalogue, forKey: "staleCatalogue") }
    }
    /// Why the last bar-app install over ADB failed (shown on the Apps page until the next attempt succeeds).
    @Published var barAppError: String?
    /// Settings → Debug bridge: what Deckhand last saw of the bar's ADB.
    @Published var adbStatus = AdbStatus()
    @Published var adbBusy = false
    /// Settings → Bar software: the launcher and bridge on the bar against the vendor's latest GitHub release.
    @Published var barSoftware = BarSoftwareStatus()
    /// What the update is doing right now ("Downloading LineOS.V1.0.9.9.apk…"), nil when idle.
    @Published var barSoftwareBusy: String?
    /// Settings → Bar home screen (AppModel+Home).
    @Published var barHome = BarHomeStatus()
    @Published var barHomeBusy: String?
    @Published var screensaver: CoreBarSession.ScreensaverConfig?
    // Persistent link ("Mac agent") that answers the CoreBar's push queries. Wording lives in `LinkBadge`.
    @Published var link: CoreBarLink.State = .stopped
    /// Bar hardening (AppModel+Hardening): the firewall as last seen, whether the user wants it, and the bar's boot id
    /// (a new one means the bar restarted).
    @Published var barFirewall: BarFirewallState = .unknown
    var barFirewallWanted = false
    var barFirewallTask: Task<Void, Never>?
    var lastBarBootID: String?
    @Published var pushCount = 0
    @Published var lastKnobVolume: Int?
    var activeLink: CoreBarLink?
    let agentSystemStats = SystemStats()
    let agentNetworkStats = NetworkStats()
    /// Layers in the last VivoCube package (for DotKey / card "next" stepping).
    var lastPublishedVivoLayers = 1
    var coverRefreshTask: Task<Void, Never>?
    @Published var vivoWiFi: [String: CoreBarSession.ModuleWiFi?] = [:]
    // Diagnostics ("Status" page)
    @Published var doctorItems: [DoctorItem] = []
    @Published var doctorRunning = false
    @Published var doctorRanAt: Date?
    @Published var lastPushAt: Date?
    @Published var lastVolumePushAt: Date?
    /// Names + rendered previews of the layers in the last VivoCube package.
    @Published var vivoLayerNames: [String] = []
    @Published var vivoLayerImages: [Int: NSImage] = [:]
    // Device-reported state (the "twin"), refreshed by `refreshDeviceState()`.
    @Published var vivoLayerShowing: Int?
    @Published var vivoWidgetShowing: Int?
    @Published var vivoScreenOn: Bool?
    @Published var vivoWiFiState: Int?
    /// The selected CoreBar's own hotspot, if Deckhand has learned it (from a cube that reported it,
    /// or typed in the Wi-Fi sheet). Differs per unit — never a built-in value.
    var knownHotspot: (ssid: String, password: String)? {
        selectedCoreBar.flatMap { Store.shared.hotspot(serial: $0.serialNo) }
    }
    /// Wi-Fi state read from the cube says it is not joined: uploads are acknowledged by the bar but never downloaded.
    var cubeOffline: Bool { vivoWiFiState.map { !CoreBarSession.CubeWiFiState.isConnected($0) } ?? false }
    var cubeWiFiLabel: String { CoreBarSession.CubeWiFiState.label(vivoWiFiState) }
    /// Something was sent this session while the cube was offline → the glass still shows the previous package.
    var cubePackageStale: Bool { cubeOffline && lastCubeSentAt != nil }
    @Published var deviceStateAt: Date?
    // Inline progress for the two publish paths + their timestamps.
    @Published var cubeProgress = StepProgress()
    @Published var pageProgress = StepProgress()
    @Published var lastCubeSentAt: Date?
    /// Personal API key for the Tasks bar app (Linear). Stored as a user-only file, never in settings.json.
    @Published var linearKey: String = Store.shared.loadSecret(name: "linear") ?? "" { didSet { Store.shared.saveSecret(linearKey, name: "linear") } }
    /// aisstream.io API key for the Haven bar app (user-only file, like the Linear key; only sent to stream.aisstream.io).
    @Published var aisstreamKey: String = Store.shared.loadSecret(name: "aisstream") ?? "" { didSet { Store.shared.saveSecret(aisstreamKey, name: "aisstream") } }
    /// Whiskystats Data API key for the Cask bar app (user-only file; only sent to data.api.whiskystats.com).
    @Published var whiskystatsKey: String = Store.shared.loadSecret(name: "whiskystats") ?? "" { didSet { Store.shared.saveSecret(whiskystatsKey, name: "whiskystats") } }
    @Published var linearError: String?
    /// SHA-256 over the layer images of the last accepted cube package — an unchanged package is not sent again.
    var lastCubeDigest: Data?
    /// When Deckhand last restarted the launcher for a stale "module offline" (`recoverStaleCubeModule`).
    var lastStaleModuleRestart: Date?
    var claudeWatchTask: Task<Void, Never>?
    // The bar apps' data server (AppModel+Monitor) and presence-aware screen (AppModel+Presence).
    var barDataTask: Task<Void, Never>?
    /// `http://<this Mac>:7432` as the selected bar reaches it, nil while the server is not running.
    @Published var barDataURL: String?
    @Published var barDataError: String?
    let barPages = BarPages()
    @Published var barAppBusy: String?
    var presenceTask: Task<Void, Never>?
    var presenceLog: Process?
    @Published var lastPresenceAt: Date?
    @Published var barScreenOn: Bool?
    @Published var presenceStatus = "Off."
    @Published var lastPagePublishedAt: Date?
    @Published var lastCoverRefreshAt: Date?
    @Published var showingVivoWiFi = false
    var vivoLayerIndex = 0
    @Published var currentPageId: String?
    var themeTask: Task<Void, Never>?
    /// Last resolved "here" (AppModel+Weather): the bar pages ask every few seconds, CoreLocation and the
    /// reverse geocoder must not be hit that often.
    var locationCache: (key: String, at: Date, loc: (lat: Double, lon: Double, name: String))?
    /// URL of the bar's `openBrowser` request the user has not answered yet (AppModel+Link); one at a time.
    var browserRequestPending: String?
    /// "serial@ip" of discovered addresses that differ from the stored one and that a pinned AUTH is checking
    /// or has refused since the last scan — each candidate is tried once per scan, never in a loop.
    var addressChecks: Set<String> = []

    struct LogEntry: Identifiable {
        let id = UUID()
        let time = Date()
        let text: String
    }

    init() {
        // Auto-select the first paired CoreBar and show its last-known modules
        // from the local cache, so there's no need to scan on every launch.
        if selectedSerial == nil, let first = paired.first { selectedSerial = first.serialNo }
        loadCachedModules()
        startLink()
    }

    /// Populate `modules` from the on-disk endpoint cache (written by the last
    /// successful provision), without touching the CoreBar. Refresh re-scans.
    func loadCachedModules() {
        guard let bar = selectedCoreBar, let data = Store.shared.loadEndpoints(serial: bar.serialNo) else { return }
        let mods = CoreBarSession.modulesFromEndpoints(data)
        guard !mods.isEmpty else { return }
        self.modules = mods
        if selectedModuleSerial == nil || !mods.contains(where: { $0.serial == selectedModuleSerial }) {
            selectedModuleSerial = (mods.first(where: { $0.isVivoCube }) ?? mods.first)?.serial
        }
        say("\(mods.count) module\(mods.count == 1 ? "" : "s") from the last scan. Use Find modules to rescan.")
    }

    func say(_ s: String) {
        statusLine = s
        log.insert(LogEntry(text: s), at: 0)
        if log.count > 400 { log.removeLast(log.count - 400) }
    }

    var selectedCoreBar: Store.PairedCoreBar? {
        paired.first { $0.serialNo == selectedSerial }
    }

    var selectedModule: AttachedModule? {
        modules.first { $0.serial == selectedModuleSerial }
    }

    func ipForSelected() -> String? {
        guard let serial = selectedSerial else { return nil }
        return address(for: serial)
    }

    /// The address Deckhand uses for a bar. A discovery reply is unauthenticated, so for a paired bar a reply
    /// that names its serial at a *new* address does not move anything (uploads, ADB, the beacon, the action
    /// peers) until a pinned AUTH on that address with the stored token has succeeded (`confirmAddress`);
    /// until then the stored `lastIp` is used. An unpaired bar (first pairing: nothing to pin yet) and a paired
    /// bar without a token or a pin (nothing to verify with) use the discovered address, as before 2026-11-04.
    func address(for serial: String) -> String? {
        let seen = discovered.first { $0.serialNo == serial }?.ip
        guard let bar = paired.first(where: { $0.serialNo == serial }) else { return seen }
        guard let seen, seen != bar.lastIp else { return bar.lastIp }
        guard bar.certSHA256 != nil, Store.shared.loadToken(serial: serial) != nil else { return seen }
        confirmAddress(seen, for: bar)
        return bar.lastIp
    }

    /// Connect to `candidate` with the pin and the token; adopt the address only when both are accepted.
    /// A wrong certificate or a refused token leaves the stored address alone (and is logged once per scan).
    private func confirmAddress(_ candidate: String, for bar: Store.PairedCoreBar) {
        let key = "\(bar.serialNo)@\(candidate)"
        guard !addressChecks.contains(key), let token = Store.shared.loadToken(serial: bar.serialNo) else { return }
        addressChecks.insert(key)
        let session = CoreBarSession(ip: candidate, token: token, certPin: Store.shared.certPin(for: bar.serialNo))
        Task {
            let r = await session.checkToken(timeout: 6)
            guard r.accepted, !r.mismatch else {
                let why = r.mismatch ? "its certificate is not the pinned one" : (r.presentedCert == nil ? "it did not answer a pinned connection" : "it did not accept the stored token")
                WireLog.shared.event("address \(candidate) claimed for \(bar.serialNo) by discovery not adopted: \(why) — keeping \(bar.lastIp)")
                self.say("A discovery reply names \(bar.name) at \(candidate), but \(why) — still using \(bar.lastIp).")
                return
            }
            Store.shared.upsert(serial: bar.serialNo, name: bar.name, ip: candidate, certSHA256: nil)
            self.paired = Store.shared.pairedCoreBars
            self.addressChecks.remove(key)
            self.say("CoreBar moved to \(candidate) (was \(bar.lastIp); confirmed by its pinned certificate and the stored token).")
            if self.selectedSerial == bar.serialNo { self.startLink() }
        }
    }

    func session(for bar: Store.PairedCoreBar) -> CoreBarSession? {
        guard let token = Store.shared.loadToken(serial: bar.serialNo) else { return nil }
        let ip = address(for: bar.serialNo) ?? bar.lastIp
        return CoreBarSession(ip: ip, token: token, certPin: Store.shared.certPin(for: bar.serialNo))
    }

    // MARK: Discovery

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        scanStartedAt = Date()
        addressChecks.removeAll()   // a new scan may try a refused address once more
        say("Looking for CoreBars on your network…")
        Task {
            let found = await Discovery.listen(timeout: 8)
            self.discovered = found
            self.isScanning = false
            self.scanStartedAt = nil
            if found.isEmpty {
                self.say("No CoreBars found. Make sure the bar and this Mac are on the same Wi-Fi, then look again.")
            } else {
                self.say("Found \(found.count) CoreBar\(found.count == 1 ? "" : "s").")
            }
        }
    }

    /// Add a CoreBar by IP (targeted unicast discovery). Falls back to a manual
    /// entry if there's no discovery reply, so you can still try to pair — handy
    /// for a mock on localhost or a device that doesn't answer unicast.
    func addCoreBar(byIP rawIP: String) {
        let ip = rawIP.trimmingCharacters(in: .whitespaces)
        guard !ip.isEmpty else { return }
        showingAddIP = false
        say("Probing \(ip)…")
        Task {
            if let bar = await Discovery.probe(ip: ip) {
                if !self.discovered.contains(where: { $0.serialNo == bar.serialNo }) { self.discovered.append(bar) }
                self.say("Found \(bar.name.isEmpty ? bar.serialNo : bar.name) at \(ip). Press Pair.")
            } else {
                let bar = CoreBar(serialNo: "manual-\(ip)", version: "", ip: ip, name: ip, tcpPort: Int(Proto.controlPort))
                if !self.discovered.contains(where: { $0.serialNo == bar.serialNo }) { self.discovered.append(bar) }
                self.say("No answer from \(ip) — added it anyway. Press Pair to try.")
            }
        }
    }

    // MARK: Pairing

    func pair(_ bar: CoreBar) {
        guard !isWorking else { return }
        isWorking = true
        pairingStartedAt = Date()
        pairingPrompt = "Tap Approve on “\(bar.name.isEmpty ? bar.serialNo : bar.name)” within 30 seconds…"
        say("Pairing with \(bar.name.isEmpty ? bar.serialNo : bar.name) — tap Approve on the CoreBar.")
        Task {
            let client = CoreBarClient(host: bar.ip)
            do {
                try await client.connect()
                let token = try await client.pair(clientName: "Deckhand for Mac", approvalWindow: 30)
                let cert = await client.presentedCertSHA256
                await client.close()
                Store.shared.saveToken(token, serial: bar.serialNo)
                Store.shared.upsert(serial: bar.serialNo, name: bar.name.isEmpty ? bar.serialNo : bar.name, ip: bar.ip, certSHA256: cert)
                self.paired = Store.shared.pairedCoreBars
                self.selectedSerial = bar.serialNo
                self.say("Paired with \(bar.name.isEmpty ? bar.serialNo : bar.name). Certificate pinned.")
                self.pairingPrompt = nil; self.pairingStartedAt = nil
                self.isWorking = false
                self.nav = .coreBarPage
                self.refreshModules()
            } catch {
                await client.close()
                self.pairingPrompt = nil; self.pairingStartedAt = nil
                self.isWorking = false
                self.say("Pairing did not complete: \(FriendlyError.text(error))")
            }
        }
    }

    func unpair(_ bar: Store.PairedCoreBar) {
        Store.shared.remove(serial: bar.serialNo)
        paired = Store.shared.pairedCoreBars
        if selectedSerial == bar.serialNo {
            selectedSerial = nil
            modules = []
        }
        say("Removed \(bar.name).")
    }

    // MARK: Modules

    func refreshModules() {
        guard !isWorking, let bar = selectedCoreBar else { return }
        guard let session = session(for: bar) else { say("No stored token for this CoreBar — pair it again."); return }
        isWorking = true
        say("Looking for modules on \(bar.name)… (press a DotKey key so it is awake)")
        Task {
            do {
                // Scan + write the gateway config in one step, so modules are
                // registered (controllable) right after a refresh. Merge with the
                // modules we wrote last time so a module that is asleep during this
                // scan (often the DotKey) isn't dropped from the config.
                // Prior = last-written cache ∪ every module ever seen on this CoreBar,
                // so a sleeping DotKey can never fall out of the config again.
                var priorList: [[String: Any]] = []
                if let d = Store.shared.loadEndpoints(serial: bar.serialNo),
                   let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] { priorList = arr }
                let known = Store.shared.knownModules(corebar: bar.serialNo)
                let have = Set(priorList.compactMap { ($0["serialNumber"] as? String) ?? ($0["serialNo"] as? String) })
                priorList += known.values.filter { !have.contains((($0["serialNumber"] as? String) ?? ($0["serialNo"] as? String) ?? "")) }
                let prior = try? JSONSerialization.data(withJSONObject: priorList)
                let (mods, endpointsJSON, diag) = try await session.provision(priorEndpoints: prior)
                Store.shared.saveEndpoints(endpointsJSON, serial: bar.serialNo)
                if let arr = try? JSONSerialization.jsonObject(with: endpointsJSON) as? [[String: Any]] {
                    Store.shared.rememberModules(arr, corebar: bar.serialNo)
                }
                self.modules = mods
                WireLog.shared.event("provision: \(diag)")
                if self.selectedModuleSerial == nil || !mods.contains(where: { $0.serial == self.selectedModuleSerial }) {
                    self.selectedModuleSerial = (mods.first(where: { $0.isVivoCube }) ?? mods.first)?.serial
                }
                if mods.isEmpty {
                    self.say("No modules found. Tap the bar's screen to wake them, then Find modules again.")
                } else {
                    let names = mods.map { "\($0.displayName)" }.joined(separator: ", ")
                    self.say("Found \(mods.count) module\(mods.count == 1 ? "" : "s"): \(names).")
                }
            } catch {
                self.say("Could not find modules: \(FriendlyError.text(error))")
            }
            self.isWorking = false
        }
    }

    // MARK: Control

    func setScreen(on: Bool) {
        guard let bar = selectedCoreBar, let session = session(for: bar),
              let serial = selectedModuleSerial else { return }
        Task {
            let code = await session.setScreen(serial: serial, on: on)
            self.vivoScreenOn = code == 200 ? on : self.vivoScreenOn
            self.say(code == 200 ? "Cube screen \(on ? "on" : "off")." : "The bar did not confirm the screen change.")
        }
    }

    func reboot() {
        guard let bar = selectedCoreBar, let session = session(for: bar),
              let serial = selectedModuleSerial else { return }
        Task {
            await session.reboot(serial: serial)
            self.say("Restarting the cube — it is back in about 20 s.")
        }
    }

    /// RGBA8888 (row 0 = top, as the card renderers' buffer is laid out) → PNG.
    /// The buffer is already in top-left order for CGImage/Glide, so no flip.
    nonisolated static func pngData(fromRGBA rgba: [UInt8], width: Int, height: Int) -> Data? {
        guard rgba.count == width * height * 4 else { return nil }
        let rowBytes = width * 4
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: rowBytes, space: cs, bitmapInfo: CGBitmapInfo(rawValue: info),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:])
    }
}
