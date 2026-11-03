import Foundation
import AppKit
import UltraBarKit

/// The "Mac agent": a persistent link to the selected CoreBar that answers the
/// device's own questions. This is what makes the CoreBar's native CPU /
/// MEMORY / STORAGE / NETWORK cards, KnobKey → volume, and PC_CONTROL cards work
/// — device-first: the CoreBar renders, the Mac only supplies Mac-only data.
@MainActor
extension AppModel {
    func startLink() {
        stopLink()
        guard let bar = selectedCoreBar, let session = session(for: bar) else { linkState = "No CoreBar"; return }
        let l = CoreBarLink(ip: session.ip, token: session.token, certPin: session.certPin)
        link = l
        Task {
            await l.start(onState: { [weak self] st in
                Task { @MainActor in
                    guard let self else { return }
                    switch st {
                    case .stopped: self.linkState = "Link off"
                    case .connecting: self.linkState = "Linking…"
                    case .connected: self.linkState = "Live link"; self.showDeckhandPageIfPublished()
                    case .reconnecting(let why): self.linkState = "Reconnecting (\(why.prefix(40)))"
                    }
                }
            }, handler: { [weak self] type, payloadJSON in
                guard let self else { return nil }
                return await self.handlePush(type: type, payloadJSON: payloadJSON)
            })
        }
    }

    func stopLink() {
        if let l = link { Task { await l.stop() } }
        link = nil
    }

    // MARK: Push handling (runs on the main actor; keep it quick)

    private func handlePush(type: String, payloadJSON: Data?) async -> Data? {
        pushCount += 1
        lastPushAt = Date()
        if type == "GET_VOLUME" || type == "SET_VOLUME" { lastVolumePushAt = Date() }
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
        case "GET_VOLUME":
            out = Self.macVolume() ?? 50
        case "SET_VOLUME":
            let v = max(0, min(100, Self.intValue(payload) ?? 50))
            Self.setMacVolume(v)
            lastKnobVolume = v
            out = v
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
            if let s = params["url"] as? String, let u = URL(string: s), ["http", "https"].contains(u.scheme ?? "") {
                NSWorkspace.shared.open(u); say("Opened \(s) (from the CoreBar).")
            }
        case "openFile", "startApp", "inputText", "execCmd":
            // Anything that can speak to :7431 (the vendor TLS key is shared across devices) could
            // push these; opening an arbitrary path is code execution. Deckhand's own pages never
            // emit them, so they are refused outright (SECURITY.md).
            say("CoreBar requested “\(action)” — not executed (Deckhand does not open files, start apps, type or run commands on the bar's behalf).")
            WireLog.shared.event("PC_CONTROL \(action) refused: \(params)")
        default:
            say("CoreBar sent PC_CONTROL \(p.keys.sorted().joined(separator: ",")) — ignored.")
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

    nonisolated static func macVolume() -> Int? {
        guard let out = osascript("output volume of (get volume settings)") else { return nil }
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    nonisolated static func setMacVolume(_ v: Int) { _ = osascript("set volume output volume \(v)") }
    nonisolated static func toggleMacMute() {
        if let m = osascript("output muted of (get volume settings)") {
            _ = osascript("set volume output muted \(m.contains("true") ? "false" : "true")")
        }
    }
    nonisolated private static func osascript(_ src: String) -> String? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript"); p.arguments = ["-e", src]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
    nonisolated private static func intValue(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }
}
