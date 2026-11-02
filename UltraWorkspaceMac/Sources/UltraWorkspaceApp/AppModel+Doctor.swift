import Foundation
import AppKit
import UltraBarKit

/// One line of the Status page.
struct DoctorItem: Identifiable {
    enum State { case ok, warn, fail, info }
    let id = UUID()
    let group: String
    let name: String
    let state: State
    let detail: String
}

/// "Doctor": everything the hardware can tell us, in one place, so nobody has
/// to take a photo of the device to know what state it is in.
@MainActor
extension AppModel {
    func runDoctor(settings: AppSettings) {
        guard !doctorRunning else { return }
        doctorRunning = true
        Task {
            defer { self.doctorRunning = false; self.doctorRanAt = Date() }
            var out: [DoctorItem] = []
            func add(_ g: String, _ n: String, _ s: DoctorItem.State, _ d: String) { out.append(DoctorItem(group: g, name: n, state: s, detail: d)) }

            guard let bar = selectedCoreBar else { add("CoreBar", "Selected", .fail, "No CoreBar selected"); self.doctorItems = out; return }
            let ip = ipForSelected() ?? bar.lastIp
            // 1. Reachability + token
            if let session = session(for: bar) {
                let tc = await session.checkToken(timeout: 6)
                add("CoreBar", "Reachable (\(ip))", tc.accepted ? .ok : .fail,
                    tc.accepted ? "TLS + token accepted" : (tc.mismatch ? "certificate changed — re-pair" : "no answer on :7431 (off, asleep or other network)"))
                // 2. Link
                let age = lastPushAt.map { Int(Date().timeIntervalSince($0)) }
                add("CoreBar", "Live link", linkState == "Live link" ? .ok : .warn,
                    "\(linkState) · \(pushCount) device questions answered" + (age.map { " · last \($0) s ago" } ?? " · no questions yet (only while a page with Mac cards is on screen)"))
                // 3. Pages
                if let pages = try? await session.listPages() {
                    corebarPages = pages
                    let hasDeck = pages.contains { $0.id == Self.deckhandPageId }
                    add("CoreBar", "Pages", hasDeck ? .ok : .warn,
                        pages.map { "\($0.name) [\($0.id)]" }.joined(separator: ", ") + (hasDeck ? "" : " — Deckhand page not published") + (currentPageId.map { " · showing \($0) (as far as Deckhand knows)" } ?? ""))
                } else { add("CoreBar", "Pages", .fail, "30710 did not answer") }
                add("CoreBar", "Weather card key", settings.accuWeatherKey.isEmpty ? .info : .ok,
                    settings.accuWeatherKey.isEmpty ? "no AccuWeather key — the CoreBar's own weather card stays empty (Deckhand's weather cover works without it)" : "AccuWeather key set (paid after the trial)")
                // 4. VivoCube
                if let vivo = modules.first(where: { $0.isVivoCube }) {
                    let w = await session.readModuleWiFi(serial: vivo.serial)
                    let st = await session.readProperty(serial: vivo.serial, propertyId: Proto.Property.wifi)
                    let stText = st.map { $0 == 3 ? "connected" : ($0 == 1 ? "NOT connected / connecting" : "state \($0)") } ?? "unknown"
                    let wifiOK = (st == 3)
                    add("VivoCube", "Wi-Fi", wifiOK ? .ok : (w == nil ? .fail : .warn),
                        (w.map { $0.isCoreBarHotspot ? "CoreBar hotspot \($0.ssid)" : "network “\($0.ssid)”" } ?? "unreadable") + " · \(stText)" + (wifiOK ? "" : " — uploads are accepted but cannot be applied until the cube is connected"))
                    let scr = await session.readProperty(serial: vivo.serial, propertyId: Proto.Property.screen)
                    add("VivoCube", "Screen", scr == 1 ? .ok : (scr == 0 ? .fail : .warn), scr == 1 ? "on" : (scr == 0 ? "OFF (press Screen On)" : "unknown"))
                    if let lw = await session.readLayerWidget(serial: vivo.serial) {
                        let name = (lw.layer >= 1 && lw.layer <= vivoLayerNames.count) ? vivoLayerNames[lw.layer - 1] : "layer \(lw.layer) (not in the last package Deckhand sent)"
                        add("VivoCube", "Showing", (lw.layer >= 1 && lw.layer <= max(1, vivoLayerNames.count)) ? .ok : .warn,
                            "layer \(lw.layer) / widget \(lw.widget) → \(name)")
                    } else { add("VivoCube", "Showing", .fail, "property 9 unreadable") }
                    let up = await session.readProperty(serial: vivo.serial, propertyId: Proto.Property.runTime)
                    add("VivoCube", "Uptime", .info, up.map { "\($0 / 3600) h \(($0 % 3600) / 60) min" } ?? "unknown")
                    let last = CoreBarSession.UploadDiag.shared.last
                    add("VivoCube", "Last upload", last.hasPrefix("accepted") ? .ok : (last.isEmpty ? .info : .fail), last.isEmpty ? "none this session" : last)
                    add("VivoCube", "Rotation", themeRunning ? .ok : .info,
                        themeRunning ? "running · \(vivoLayerNames.count) widgets · every \(settings.vivoSeconds) s · now: \(currentThemeLabel)" : "not running")
                } else { add("VivoCube", "Module", .info, "no VivoCube in the module list (Refresh / set up)") }
                // 5. SenseCube
                if let sense = modules.first(where: { $0.type == "SENSE_CUBE" }) {
                    let r = await session.readSenseCube(serial: sense.serial)
                    let ok = r.temperatureC != nil
                    add("SenseCube", "Readings", ok ? .ok : .fail,
                        ok ? "\(r.temperatureC!) °C · \(r.humidity.map { "\($0) %" } ?? "–") · \(r.lux.map { "\($0) lux" } ?? "–")" : "no reply (asleep? tap the CoreBar)")
                }
                // 6. KnobKey
                if modules.contains(where: { $0.type == "KNOB_KEY" }) {
                    let age = lastVolumePushAt.map { Int(Date().timeIntervalSince($0)) }
                    add("KnobKey", "Volume link", age == nil ? .info : .ok,
                        age.map { "device asked/set volume \($0) s ago · Mac volume \(Self.macVolume().map(String.init) ?? "?")%" } ?? "no volume requests yet (bound in the Deckhand page; the device polls only while a page with the binding is active)")
                }
                // 7. Modules cache
                add("Modules", "Known modules", modules.isEmpty ? .warn : .ok, modules.isEmpty ? "none — press Refresh / set up" : modules.map { "\($0.prettyType) \($0.serial)\($0.online ? "" : " (asleep)")" }.joined(separator: ", "))
            } else {
                add("CoreBar", "Token", .fail, "no stored token — pair again")
            }
            // 8. Weather source
            if let now = try? await resolveWeather(settings: settings, metric: settings.units == .metric) {
                add("Mac", "Weather (Open-Meteo)", .ok, "\(Int(now.temperature.rounded()))\(now.unitSuffix) \(now.sky.label) @ \(now.place)")
            } else { add("Mac", "Weather (Open-Meteo)", .fail, "could not resolve a location/forecast") }
            self.doctorItems = out
        }
    }

    /// Plain-text version for pasting into a chat/issue.
    func doctorReportText() -> String {
        var s = "Deckhand status report — \(Date().formatted(date: .abbreviated, time: .standard))\n"
        s += "App \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") · CoreBar \(selectedCoreBar?.name ?? "-") \(selectedCoreBar?.serialNo ?? "") @ \(ipForSelected() ?? "-")\n"
        var group = ""
        for i in doctorItems {
            if i.group != group { group = i.group; s += "\n[\(group)]\n" }
            let mark: String = { switch i.state { case .ok: return "OK  "; case .warn: return "WARN"; case .fail: return "FAIL"; case .info: return "info" } }()
            s += "\(mark) \(i.name): \(i.detail)\n"
        }
        s += "\nRecent activity:\n" + log.prefix(12).map { "  \($0.time.formatted(date: .omitted, time: .standard)) \($0.text)" }.joined(separator: "\n")
        return s
    }
}
