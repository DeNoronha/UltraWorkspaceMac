import Foundation
import SwiftUI
import AppKit
import UltraBarKit

@MainActor
final class AppModel: ObservableObject {
    // CoreBars
    @Published var discovered: [CoreBar] = []
    @Published var paired: [Store.PairedCoreBar] = Store.shared.pairedCoreBars
    @Published var selectedSerial: String?

    // Selected CoreBar state
    @Published var modules: [AttachedModule] = []
    @Published var selectedModuleSerial: String?

    // UI state
    @Published var isScanning = false
    @Published var isWorking = false
    @Published var statusLine = "Ready."
    @Published var log: [LogEntry] = []
    @Published var pairingPrompt: String?
    @Published var showingSettings = false
    @Published var nav: NavItem = .coreBar
    @Published var selectedAddon: Theme = .weather

    // Upload options (VivoCube native resolution is ~240×240)
    @Published var canvasSize = 240

    // Music
    @Published var nowPlaying = AppleMusic.NowPlaying(isPlaying: false, title: "", artist: "", album: "", hasTrack: false)
    @Published var autoPushNowPlaying = false
    var musicPollTask: Task<Void, Never>?
    var lastPushedKey = ""

    // Weather
    @Published var lastWeather: OpenMeteo.Now?
    @Published var weatherAutoUpdate = false
    var weatherTask: Task<Void, Never>?

    // Theme carousel
    @Published var themeRunning = false
    @Published var currentThemeLabel = ""
    let sysStats = SystemStats()
    let netStats = NetworkStats()
    var themeTask: Task<Void, Never>?
    var themeIndex = 0

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
        say("Loaded \(mods.count) saved module\(mods.count == 1 ? "" : "s") from cache. Refresh to rescan.")
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
        if let d = discovered.first(where: { $0.serialNo == selectedSerial }) { return d.ip }
        return selectedCoreBar?.lastIp
    }

    func session(for bar: Store.PairedCoreBar) -> CoreBarSession? {
        guard let token = Store.shared.loadToken(serial: bar.serialNo) else { return nil }
        let ip = discovered.first(where: { $0.serialNo == bar.serialNo })?.ip ?? bar.lastIp
        return CoreBarSession(ip: ip, token: token, certPin: Store.shared.certPin(for: bar.serialNo))
    }

    // MARK: Discovery

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        say("Scanning the local network for CoreBars…")
        Task {
            let found = await Discovery.listen(timeout: 8)
            self.discovered = found
            self.isScanning = false
            if found.isEmpty {
                self.say("No CoreBars found. Make sure the CoreBar and this Mac are on the same Wi-Fi, then scan again.")
            } else {
                self.say("Found \(found.count) CoreBar\(found.count == 1 ? "" : "s").")
            }
        }
    }

    // MARK: Pairing

    func pair(_ bar: CoreBar) {
        guard !isWorking else { return }
        isWorking = true
        pairingPrompt = "Tap Approve on “\(bar.name.isEmpty ? bar.serialNo : bar.name)” within 30 seconds…"
        say("Pairing with \(bar.name.isEmpty ? bar.serialNo : bar.name) — tap Approve on the CoreBar.")
        Task {
            let client = CoreBarClient(host: bar.ip)
            do {
                try await client.connect()
                let token = try await client.pair(clientName: "UltraWorkspace for Mac", approvalWindow: 30)
                let cert = await client.presentedCertSHA256
                await client.close()
                Store.shared.saveToken(token, serial: bar.serialNo)
                Store.shared.upsert(serial: bar.serialNo, name: bar.name.isEmpty ? bar.serialNo : bar.name, ip: bar.ip, certSHA256: cert)
                self.paired = Store.shared.pairedCoreBars
                self.selectedSerial = bar.serialNo
                self.say("Paired with \(bar.name.isEmpty ? bar.serialNo : bar.name). Certificate pinned.")
                self.pairingPrompt = nil
                self.isWorking = false
                self.refreshModules()
            } catch {
                await client.close()
                self.pairingPrompt = nil
                self.isWorking = false
                self.say("Pairing failed: \(error.localizedDescription)")
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
        guard let bar = selectedCoreBar, let session = session(for: bar), !isWorking else {
            if selectedCoreBar != nil { say("No stored token for this CoreBar — pair it again.") }
            return
        }
        isWorking = true
        say("Scanning the bus and registering modules on \(bar.name)…")
        Task {
            do {
                // Scan + write the gateway config in one step, so modules are
                // registered (controllable) right after a refresh. Merge with the
                // modules we wrote last time so a module that is asleep during this
                // scan (often the DotKey) isn't dropped from the config.
                let prior = Store.shared.loadEndpoints(serial: bar.serialNo)
                let (mods, endpointsJSON, diag) = try await session.provision(priorEndpoints: prior)
                Store.shared.saveEndpoints(endpointsJSON, serial: bar.serialNo)
                self.modules = mods
                self.say("setup: \(diag)")
                if self.selectedModuleSerial == nil || !mods.contains(where: { $0.serial == self.selectedModuleSerial }) {
                    self.selectedModuleSerial = (mods.first(where: { $0.isVivoCube }) ?? mods.first)?.serial
                }
                if mods.isEmpty {
                    self.say("No modules found. Tap the CoreBar's screen to wake the modules, then Refresh.")
                } else {
                    let names = mods.map { "\($0.displayName)" }.joined(separator: ", ")
                    self.say("Ready: \(mods.count) module\(mods.count == 1 ? "" : "s") (\(names)).")
                }
            } catch {
                self.say("Could not set up modules: \(error.localizedDescription)")
            }
            self.isWorking = false
        }
    }

    /// Provision the CoreBar: scan + write the discovered modules into the
    /// gateway config so they become controllable. Changes device config.
    func provisionModules() {
        guard let bar = selectedCoreBar, let session = session(for: bar), !isWorking else {
            if selectedCoreBar != nil { say("No stored token — pair this CoreBar again.") }
            return
        }
        // Refresh now also writes the config, so "Set up modules" == Refresh.
        _ = bar; _ = session
        refreshModules()
    }

    // MARK: Control

    func setScreen(on: Bool) {
        guard let bar = selectedCoreBar, let session = session(for: bar),
              let serial = selectedModuleSerial else { return }
        Task {
            let code = await session.setScreen(serial: serial, on: on)
            self.say("Screen \(on ? "on" : "off") → \(code.map(String.init) ?? "no reply")")
        }
    }

    func reboot() {
        guard let bar = selectedCoreBar, let session = session(for: bar),
              let serial = selectedModuleSerial else { return }
        Task {
            await session.reboot(serial: serial)
            self.say("Reboot sent to \(serial).")
        }
    }

    func chooseAndUploadImage() {
        guard let bar = selectedCoreBar, let session = session(for: bar),
              let serial = selectedModuleSerial else {
            say("Select a CoreBar and a module first.")
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.allowsMultipleSelection = false
        panel.message = "Pick an image to show on \(serial)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let size = canvasSize
        isWorking = true
        say("Rendering and uploading \(url.lastPathComponent) to \(serial)…")
        Task.detached {
            guard let tgz = Self.buildTgz(from: url, size: size) else {
                await MainActor.run { self.say("Could not read that image."); self.isWorking = false }
                return
            }
            do {
                _ = try await session.upload(serial: serial, tgz: tgz)
                await MainActor.run { self.say("Uploaded \(tgz.count) bytes to \(serial). ✓"); self.isWorking = false }
            } catch {
                await MainActor.run { self.say("Upload failed: \(error.localizedDescription)"); self.isWorking = false }
            }
        }
    }

    nonisolated static func buildTgz(from url: URL, size: Int) -> Data? {
        guard let src = NSImage(contentsOf: url),
              let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        guard let fullRGBA = DeviceImage.rgba(from: cg, width: size, height: size) else { return nil }
        let pressedSize = max(1, Int(Double(size) * 0.8))
        guard let pressedRGBA = DeviceImage.rgba(from: cg, width: pressedSize, height: pressedSize) else { return nil }
        let def = DeviceImage.encode(width: size, height: size, rgba: fullRGBA)
        let pre = DeviceImage.encode(width: pressedSize, height: pressedSize, rgba: pressedRGBA)
        let layer = DeployPackager.Layer(layerId: 1, widgetId: 101, defaultBin: def, pressedBin: pre)
        return DeployPackager.buildTgz(layers: [layer], defaultLayer: 1)
    }
}
