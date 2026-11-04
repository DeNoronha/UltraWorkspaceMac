import Foundation
import AppKit
import UltraBarKit

/// The "Mac agent": a persistent link to the selected CoreBar that answers the
/// device's own questions. This is what makes the CoreBar's native CPU /
/// MEMORY / STORAGE / NETWORK cards, KnobKey → volume, and PC_CONTROL cards work
/// — device-first: the CoreBar renders, the Mac only supplies Mac-only data.
extension CoreBarLink.State {
    var isConnected: Bool { self == .connected }
}

@MainActor
extension AppModel {
    func startLink() {
        stopLink()
        guard let bar = selectedCoreBar, let session = session(for: bar) else { link = .stopped; return }
        let l = CoreBarLink(ip: session.ip, token: session.token, certPin: session.certPin)
        activeLink = l
        Task {
            await l.start(onState: { [weak self] st in
                Task { @MainActor in
                    guard let self else { return }
                    self.link = st
                    if st == .connected { self.showDeckhandPageIfPublished() }
                }
            }, handler: { [weak self] type, payloadJSON in
                guard let self else { return nil }
                // Volume is answered here, off the main actor, straight from the CoreAudio cache: the bar gives
                // up on a GET_VOLUME after about a second and asks again, and the main actor can be busy for
                // longer than that right after launch or while cards render (p90 1.2 s measured 2026-11-04).
                switch type {
                case "GET_VOLUME":
                    Task { @MainActor in self.notePush(type: type) }
                    return CoreBarLink.json(MacAudio.shared.volume ?? 50)
                case "SET_VOLUME":
                    let v = max(0, min(100, Self.intValue(CoreBarLink.value(payloadJSON)) ?? 50))
                    MacAudio.shared.setVolume(v)
                    Task { @MainActor in self.notePush(type: type); self.lastKnobVolume = v }
                    return CoreBarLink.json(v)
                default:
                    return await self.handlePush(type: type, payloadJSON: payloadJSON)
                }
            })
        }
    }

    func stopLink() {
        if let l = activeLink { Task { await l.stop() } }
        activeLink = nil
    }

    // MARK: Push handling (runs on the main actor; keep it quick)

    /// Bookkeeping for the status views; the volume fast path above calls it without waiting.
    func notePush(type: String) {
        pushCount += 1
        lastPushAt = Date()
        if type == "GET_VOLUME" || type == "SET_VOLUME" { lastVolumePushAt = Date() }
    }

    private func handlePush(type: String, payloadJSON: Data?) async -> Data? {
        notePush(type: type)
        let payload = CoreBarLink.value(payloadJSON)
        let out: Any?
        switch type {
        case "CPU":
            out = Int(agentSystemStats.sample().cpuPercent.rounded())
        case "MEMORY":
            out = Int(agentSystemStats.sample().memPercent.rounded())
        case "STORAGE":
            out = Self.diskUsedPercent()
        case "NETWORK":
            let t = agentNetworkStats.totals()
            out = ["totalReceived": t.received, "totalSent": t.sent]
        case "GET_VOLUME", "SET_VOLUME":
            // Answered on the link's own task (see startLink); never reaches here.
            out = MacAudio.shared.volume ?? 50
        case "GET_BRIGHTNESS":
            out = 50 // not controllable from here (the vendor's Mac client stubs this too)
        case "SET_BRIGHTNESS":
            out = Self.intValue(payload) ?? 50
        case "TEST":
            out = payload ?? NSNull()
        case "PC_CONTROL":
            handlePCControl(payload)
            out = NSNull()
        case "MODULE_STATE", "METRIC":
            return nil // informational pushes; no reply expected
        default:
            WireLog.shared.event("link: unhandled push type \(type)")
            return nil
        }
        guard let out, !(out is NSNull) else { return Data() }
        return CoreBarLink.json(out)
    }

    /// PC_CONTROL payloads: Deckhand's own `{"deckhand": "<command>"}` and the
    /// vendor's `{"action": …, "params": {…}}` (openBrowser / openFile /
    /// startApp). `inputText` and `execCmd` are deliberately not executed.
    private func handlePCControl(_ payload: Any?) {
        guard let p = payload as? [String: Any] else { return }
        if let cmd = p["deckhand"] as? String {
            switch cmd {
            case "next": stepVivoLayer(+1)
            case "previous": stepVivoLayer(-1)
            case "music.playpause": AppleMusic.playPause()
            case "music.next": AppleMusic.next()
            case "music.previous": AppleMusic.previous()
            case "mute": Self.toggleMacMute()
            case "page.default": switchPage(id: Self.defaultPageId)
            case "page.deckhand": switchPage(id: Self.deckhandPageId)
            default: say("CoreBar asked for unknown Deckhand command “\(cmd)”.")
            }
            return
        }
        let action = (p["action"] as? String) ?? ""
        let params = (p["params"] as? [String: Any]) ?? [:]
        switch action {
        case "openBrowser":
            // Never silently: whoever can speak to :7431 could push a phishing or drive-by URL. Deckhand asks
            // first (host and full URL, Open / Ignore), http(s) only, and remembers nothing (SECURITY.md, path 3).
            if let s = params["url"] as? String, let u = URL(string: s), ["http", "https"].contains(u.scheme?.lowercased() ?? ""), u.host != nil {
                confirmOpenBrowser(u)
            } else {
                say("CoreBar asked to open a link that is not http(s) — ignored.")
            }
        case "openFile", "startApp", "inputText", "execCmd":
            // Anything that can speak to :7431 (the vendor TLS key is shared across devices) could
            // push these; opening an arbitrary path is code execution. Deckhand's own pages never
            // emit them, so they are refused outright (SECURITY.md).
            say("CoreBar requested “\(action)” — not executed (Deckhand does not open files, start apps, type or run commands on the bar's behalf).")
            // Only the parameter names: an `inputText` the bar wanted typed could be anything, and the log is kept.
            WireLog.shared.event("PC_CONTROL \(action) refused (params: \(params.keys.sorted().joined(separator: ",")))")
        default:
            say("CoreBar sent PC_CONTROL \(p.keys.sorted().joined(separator: ",")) — ignored.")
        }
    }

    /// "The CoreBar wants to open a web page": an alert with the host and the URL. One at a time — a second
    /// request while one is showing is dropped and logged, so a hostile bar cannot stack dialogs. Nothing is
    /// remembered: the next request asks again.
    private func confirmOpenBrowser(_ url: URL) {
        let host = url.host ?? "?"
        let text = url.absoluteString
        guard browserRequestPending == nil else {
            say("CoreBar asked to open \(host) while another request is still open — ignored.")
            return
        }
        browserRequestPending = text
        say("CoreBar wants to open \(host) — waiting for your answer.")
        // Off the push handler's call chain: the bar gets its reply first, then the window asks.
        Task { @MainActor in
            let alert = NSAlert()
            alert.messageText = "Open a web page the CoreBar asked for?"
            alert.informativeText = "The bar \(self.selectedCoreBar?.name ?? "") asks this Mac to open\n\n\(host)\n\(text.count > 300 ? String(text.prefix(300)) + "…" : text)\n\nOnly open it if you expect it (an app card on the bar you tapped, for instance)."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Ignore")
            alert.addButton(withTitle: "Open")
            NSApp.activate(ignoringOtherApps: true)
            let open: Bool
            if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
                open = await alert.beginSheetModal(for: window) == .alertSecondButtonReturn
            } else {
                open = alert.runModal() == .alertSecondButtonReturn
            }
            self.browserRequestPending = nil
            if open { NSWorkspace.shared.open(url); self.say("Opened \(host) (from the CoreBar).") }
            else { self.say("Did not open \(host) (from the CoreBar).") }
        }
    }

    /// Step the VivoCube to the next/previous layer of the current rotation set
    /// (property 9); used by the DotKey "Next" binding and PC_CONTROL cards.
    func stepVivoLayer(_ delta: Int) {
        guard let bar = selectedCoreBar, let session = session(for: bar), let serial = vivoCubeSerial else { return }
        let count = max(1, min(Self.maxVivoLayers, max(lastPublishedVivoLayers, vivoLayerNames.count)))
        vivoLayerIndex = ((vivoLayerIndex + delta) % count + count) % count
        let layer = vivoLayerIndex + 1
        Task { _ = await self.showCubeCard(layer, session: session, serial: serial) }
        say("Cube → card \(layer)\(layer - 1 < vivoLayerNames.count ? " (\(vivoLayerNames[layer - 1]))" : "") — from the bar.")
    }

    // MARK: Mac helpers

    nonisolated static func diskUsedPercent() -> Int {
        guard let a = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
              let total = (a[.systemSize] as? NSNumber)?.doubleValue, total > 0,
              let free = (a[.systemFreeSize] as? NSNumber)?.doubleValue else { return 0 }
        return Int(((total - free) / total * 100).rounded())
    }

    /// Mac output volume (0…100) from the CoreAudio cache; nil when the output device has no control.
    nonisolated static func macVolume() -> Int? { MacAudio.shared.volume }
    nonisolated static func toggleMacMute() { MacAudio.shared.toggleMute() }
    nonisolated static func intValue(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }
}
