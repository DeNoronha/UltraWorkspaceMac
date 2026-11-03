import Foundation
import AppKit
import UltraBarKit

/// One button next to a Status row / the device strip: the single next action.
struct DoctorAction {
    let title: String
    let run: @MainActor () -> Void
}

/// One line of the Status page. Ordered by severity (fail < warn < info < ok).
struct DoctorItem: Identifiable {
    enum State: Int, Comparable { case fail = 0, warn, info, ok
        static func < (a: State, b: State) -> Bool { a.rawValue < b.rawValue } }
    let id = UUID()
    let group: String
    let name: String
    let state: State
    let detail: String
    var action: DoctorAction? = nil
}

@MainActor
extension AppModel {
    var firstVivoCube: AttachedModule? { modules.first { $0.isVivoCube } }

    // MARK: Light-weight device twin (every ~30 s while a device page is in front)

    /// Read what the cube reports: current card (property 9), screen (4), Wi-Fi state (6).
    func refreshDeviceState() async {
        guard let bar = selectedCoreBar, let session = session(for: bar) else { return }
        if let vivo = firstVivoCube {
            if let lw = await session.readLayerWidget(serial: vivo.serial) {
                vivoLayerShowing = lw.layer; vivoWidgetShowing = lw.widget
                if lw.layer >= 1, lw.layer <= vivoLayerNames.count { vivoLayerIndex = lw.layer - 1; currentThemeLabel = vivoLayerNames[lw.layer - 1] }
            }
            if let scr = await session.readProperty(serial: vivo.serial, propertyId: Proto.Property.screen) { vivoScreenOn = scr == 1 }
            if let st = await session.readProperty(serial: vivo.serial, propertyId: Proto.Property.wifi) { vivoWiFiState = Int(st) }
            if vivoWiFi[vivo.serial] == nil, let w = await session.readModuleWiFi(serial: vivo.serial) { vivoWiFi[vivo.serial] = w }
        }
        if let pages = try? await session.listPages() { corebarPages = pages }
        deviceStateAt = Date()
    }

    /// The one thing that is wrong right now, with the one button that fixes it.
    /// One fault + one fix for a device page. `cube` = the VivoCube page (cube Wi-Fi/screen/card faults);
    /// otherwise the CoreBar page (link and page faults only — cube problems belong on the cube page).
    func deviceFault(settings: AppSettings, cube: Bool) -> (message: String, action: DoctorAction)? {
        if linkState != "Live link" {
            return ("Not connected to the bar — its Mac cards and the KnobKey volume won't update.",
                    DoctorAction(title: "Reconnect") { [weak self] in self?.startLink() })
        }
        if cube, let vivo = firstVivoCube {
            if cubeOffline {
                let tail = lastCubeSentAt == nil ? "new cards cannot reach it." : "it still shows its previous cards — the ones you sent never arrived."
                if let w = vivoWiFi[vivo.serial] ?? nil, !w.isCoreBarHotspot {
                    return ("The cube cannot hold Wi-Fi “\(w.ssid)”, so \(tail)", hotspotAction(serial: vivo.serial))
                }
                return ("The cube is not on Wi-Fi, so \(tail)",
                        DoctorAction(title: "Set cube Wi-Fi…") { [weak self] in self?.nav = .vivoCube; self?.showingVivoWiFi = true })
            }
            if let w = vivoWiFi[vivo.serial] ?? nil, !w.isCoreBarHotspot, CoreBarSession.UploadDiag.shared.last.contains("error:4") {
                return ("The bar refuses uploads while the cube is on “\(w.ssid)” (error 4) — it only delivers over its own hotspot.", hotspotAction(serial: vivo.serial))
            }
            if vivoScreenOn == false {
                return ("The cube's screen is off.",
                        DoctorAction(title: "Turn on") { [weak self] in self?.setCubeScreen(on: true, serial: vivo.serial) })
            }
            if let l = vivoLayerShowing, !vivoLayerNames.isEmpty, (l < 1 || l > vivoLayerNames.count) {
                return ("The cube is pointing at a card that is not in the last package (black screen).",
                        DoctorAction(title: "Fix") { [weak self] in self?.recoverVivoDisplay(serial: vivo.serial) })
            }
        }
        if !cube, settings.deckhandPagePublished, !corebarPages.isEmpty, !corebarPages.contains(where: { $0.id == Self.deckhandPageId }) {
            return ("The Deckhand page is gone from the bar (did the official app deploy?).",
                    DoctorAction(title: "Publish page") { [weak self] in self?.publishDeckhandPage(settings: settings) })
        }
        return nil
    }

    /// One click back to the bar's own hotspot when Deckhand knows this bar's credentials;
    /// otherwise open the Wi-Fi sheet so the user can type them (they are printed on the bar).
    func hotspotAction(serial: String) -> DoctorAction {
        if let h = knownHotspot {
            return DoctorAction(title: "Use the CoreBar hotspot") { [weak self] in
                self?.setVivoWiFi(serial: serial, ssid: h.ssid, password: h.password)
            }
        }
        return DoctorAction(title: "Set cube Wi-Fi…") { [weak self] in self?.nav = .vivoCube; self?.showingVivoWiFi = true }
    }

    func setCubeScreen(on: Bool, serial: String) {
        guard let bar = selectedCoreBar, let session = session(for: bar) else { return }
        Task {
            let code = await session.setScreen(serial: serial, on: on)
            if code == 200 { self.vivoScreenOn = on }
            self.say(code == 200 ? "Cube screen \(on ? "on" : "off")." : "The bar did not confirm the screen change.")
        }
    }

    func restartCube(serial: String) {
        guard let bar = selectedCoreBar, let session = session(for: bar) else { return }
        Task { await session.reboot(serial: serial); self.say("Restarting the cube — back in about 20 s.") }
    }

    // MARK: Full check (Status page)

    func runDoctor(settings: AppSettings) {
        guard !doctorRunning else { return }
        doctorRunning = true
        Task {
            defer { self.doctorRunning = false; self.doctorRanAt = Date() }
            var out: [DoctorItem] = []
            func add(_ g: String, _ n: String, _ s: DoctorItem.State, _ d: String, _ a: DoctorAction? = nil) {
                out.append(DoctorItem(group: g, name: n, state: s, detail: d, action: a))
            }
            guard let bar = selectedCoreBar else {
                add("CoreBar", "No CoreBar", .fail, "Nothing is paired yet.", DoctorAction(title: "Find CoreBar") { [weak self] in self?.scan() })
                self.doctorItems = out; return
            }
            let ip = ipForSelected() ?? bar.lastIp
            guard let session = session(for: bar) else {
                add("CoreBar", "Not paired", .fail, "This Mac has no key for \(bar.name) any more.", DoctorAction(title: "Find CoreBar") { [weak self] in self?.scan() })
                self.doctorItems = out; return
            }
            // CoreBar
            let tc = await session.checkToken(timeout: 6)
            if tc.accepted { add("CoreBar", "Connected", .ok, "\(bar.name) at \(ip) accepts this Mac.") }
            else if tc.mismatch { add("CoreBar", "Certificate changed", .fail, "The bar presents a different certificate than when you paired. If you reset or replaced it, pair again.", DoctorAction(title: "Forget & pair again") { [weak self] in self?.unpair(bar); self?.scan() }) }
            else { add("CoreBar", "Not reachable", .fail, "No answer from \(ip). Is the bar on and on the same Wi-Fi?", DoctorAction(title: "Check again") { [weak self] in self?.runDoctor(settings: settings) }) }
            let age = lastPushAt.map { Int(Date().timeIntervalSince($0)) }
            if linkState == "Live link" {
                add("CoreBar", "Answering the bar", .ok, "\(pushCount) requests answered" + (age.map { " · last \($0) s ago" } ?? " · none yet (the bar only asks while a page with Mac cards is on screen)"))
            } else {
                add("CoreBar", "Not connected", .warn, "\(linkState). The bar's Mac cards and the KnobKey volume won't update.", DoctorAction(title: "Reconnect") { [weak self] in self?.startLink() })
            }
            if let pages = try? await session.listPages() {
                corebarPages = pages
                let hasDeck = pages.contains { $0.id == Self.deckhandPageId }
                let names = pages.map(\.name).joined(separator: ", ")
                if hasDeck { add("CoreBar", "Pages", .ok, names + (currentPageId.map { id in " · showing \(pages.first { $0.id == id }?.name ?? id) (as set by Deckhand)" } ?? "")) }
                else if settings.deckhandPagePublished { add("CoreBar", "Deckhand page missing", .warn, "The bar has: \(names). Did the official app deploy since?", DoctorAction(title: "Publish page") { [weak self] in self?.publishDeckhandPage(settings: settings) }) }
                else { add("CoreBar", "Pages", .info, names + " · the Deckhand page has not been published yet", DoctorAction(title: "Publish page") { [weak self] in self?.nav = .coreBarPage }) }
                if !foreignPages.isEmpty { add("CoreBar", "Pages from the official app", .info, foreignPages.map(\.name).joined(separator: ", ") + " — these would be removed by a publish.") }
            } else { add("CoreBar", "Pages", .fail, "The bar did not answer when asked for its pages.") }
            if settings.coreCards.contains("WEATHER") {
                add("CoreBar", "Weather card key", settings.accuWeatherKey.isEmpty ? .warn : .ok,
                    settings.accuWeatherKey.isEmpty ? "The bar's own weather card shows “--” without an AccuWeather key." : "AccuWeather key stored (paid after the trial).",
                    settings.accuWeatherKey.isEmpty ? DoctorAction(title: "Add key") { [weak self] in self?.nav = .coreBarPage } : nil)
            }
            // VivoCube
            if let vivo = firstVivoCube {
                await refreshDeviceState()
                let w = vivoWiFi[vivo.serial] ?? nil
                let st = vivoWiFiState
                let net = w.map { $0.isCoreBarHotspot ? "the CoreBar's hotspot (\($0.ssid))" : "“\($0.ssid)”" } ?? "an unknown network"
                if st == 3 { add("VivoCube", "Wi-Fi", .ok, "Connected to \(net).") }
                else if w == nil && st == nil { add("VivoCube", "Wi-Fi", .fail, "The cube did not answer. Is it attached?", DoctorAction(title: "Find modules") { [weak self] in self?.refreshModules() }) }
                else { add("VivoCube", "Wi-Fi", .fail, "Set to \(net) but not connected\(st.map { " (state \($0))" } ?? ""). New cards cannot reach the cube until it is.", (w?.isCoreBarHotspot ?? true) ? DoctorAction(title: "Set cube Wi-Fi…") { [weak self] in self?.nav = .vivoCube; self?.showingVivoWiFi = true } : hotspotAction(serial: vivo.serial)) }
                switch vivoScreenOn {
                case .some(true): add("VivoCube", "Screen", .ok, "On")
                case .some(false): add("VivoCube", "Screen", .fail, "Off — it stays off until you turn it on.", DoctorAction(title: "Turn on") { [weak self] in self?.setCubeScreen(on: true, serial: vivo.serial) })
                case .none: add("VivoCube", "Screen", .warn, "Could not read the screen state.")
                }
                if let l = vivoLayerShowing {
                    if vivoLayerNames.isEmpty { add("VivoCube", "Showing", .info, "Card \(l) — nothing was sent from this Mac in this session, so Deckhand cannot tell which picture that is.") }
                    else if l >= 1, l <= vivoLayerNames.count { add("VivoCube", "Showing", .ok, "Card \(l) of \(vivoLayerNames.count): \(vivoLayerNames[l - 1])") }
                    else { add("VivoCube", "Showing", .fail, "Card \(l), which is not in the last package (\(vivoLayerNames.count) cards) — the cube shows black.", DoctorAction(title: "Fix black screen") { [weak self] in self?.recoverVivoDisplay(serial: vivo.serial) }) }
                } else { add("VivoCube", "Showing", .warn, "Could not read which card the cube is on.") }
                let last = CoreBarSession.UploadDiag.shared.last
                if last.isEmpty { add("VivoCube", "Last upload", .info, "Nothing sent in this session.") }
                else if last.hasPrefix("accepted"), cubeOffline { add("VivoCube", "Last upload", .fail, (lastCubeSentAt.map { "The bar accepted it at \($0.formatted(date: .omitted, time: .shortened))" } ?? "The bar accepted it") + ", but the cube is not on Wi-Fi, so it never downloaded it. The glass still shows the previous cards.", (w?.isCoreBarHotspot ?? true) ? DoctorAction(title: "Set cube Wi-Fi…") { [weak self] in self?.nav = .vivoCube; self?.showingVivoWiFi = true } : hotspotAction(serial: vivo.serial)) }
                else if last.hasPrefix("accepted") { add("VivoCube", "Last upload", .ok, (lastCubeSentAt.map { "Accepted \($0.formatted(date: .omitted, time: .shortened))" } ?? "Accepted") + " — the cube applies it about 10 s later.") }
                else { add("VivoCube", "Last upload", .fail, FriendlyError.text(last), DoctorAction(title: "Send again") { [weak self] in self?.sendToCube(settings: settings) }) }
                let mode: String = { switch settings.vivoSwitchMode { case .stay: return "stays on one card"; case .timed: return themeRunning ? "switching every \(settings.vivoSeconds) s" : "set to switch every \(settings.vivoSeconds) s, but not running (send to the cube again)"; case .button: return "switches only with the DotKey / bar button" } }()
                add("VivoCube", "Cards", settings.vivoCards.isEmpty ? .warn : .info, settings.vivoCards.isEmpty ? "No cards picked yet." : settings.vivoCards.map(\.title).joined(separator: ", ") + " · \(mode)")
                let up = await session.readProperty(serial: vivo.serial, propertyId: Proto.Property.runTime)
                add("VivoCube", "Up for", .info, up.map { "\($0 / 3600) h \(($0 % 3600) / 60) min" } ?? "unknown")
            } else { add("VivoCube", "No VivoCube", .info, "Not in the module list.", DoctorAction(title: "Find modules") { [weak self] in self?.refreshModules() }) }
            // SenseCube
            if let sense = modules.first(where: { $0.type == "SENSE_CUBE" }) {
                let r = await session.readSenseCube(serial: sense.serial)
                if let t = r.temperatureC { add("SenseCube", "Readings", .ok, String(format: "%.1f °C", t) + (r.humidity.map { String(format: " · %.0f %%", $0) } ?? "") + (r.lux.map { " · \($0) lux" } ?? "")) }
                else { add("SenseCube", "Readings", .fail, "No reply — tap the bar's screen to wake it.", DoctorAction(title: "Find modules") { [weak self] in self?.refreshModules() }) }
            }
            // KnobKey
            if modules.contains(where: { $0.type == "KNOB_KEY" }) {
                let vAge = lastVolumePushAt.map { Int(Date().timeIntervalSince($0)) }
                add("KnobKey", "Volume link", vAge == nil ? .info : .ok,
                    vAge.map { "The bar asked or set the volume \($0) s ago · Mac volume \(Self.macVolume().map { "\($0) %" } ?? "?")" }
                    ?? (settings.deckhandPagePublished ? "No volume requests yet — the bar polls only while the Deckhand page is on screen." : "Publish the CoreBar page once to bind the knob to the Mac's volume."),
                    settings.deckhandPagePublished ? nil : DoctorAction(title: "Publish page") { [weak self] in self?.nav = .coreBarPage })
            }
            // Modules
            let known = Store.shared.knownModules(corebar: bar.serialNo)
            let missing = known.keys.filter { k in !modules.contains { $0.serial == k } }
            if modules.isEmpty { add("Modules", "None found", .warn, "Press Find modules (tap the bar's screen first so they are awake).", DoctorAction(title: "Find modules") { [weak self] in self?.refreshModules() }) }
            else { add("Modules", "Known modules", missing.isEmpty ? .ok : .warn, modules.map { "\($0.prettyType)\($0.online ? "" : " (asleep)")" }.joined(separator: ", ") + (missing.isEmpty ? "" : " · \(missing.count) seen before but not now — wake it and look again"), missing.isEmpty ? nil : DoctorAction(title: "Find modules") { [weak self] in self?.refreshModules() }) }
            // Mac
            if let now = try? await resolveWeather(settings: settings, metric: settings.units == .metric) {
                add("Mac", "Weather (Open-Meteo)", .ok, "\(Int(now.temperature.rounded()))\(now.unitSuffix) \(now.sky.label) in \(now.place)")
            } else { add("Mac", "Weather (Open-Meteo)", .fail, "No location or forecast. Set a city under Widgets → Weather.", DoctorAction(title: "Open Widgets") { [weak self] in self?.nav = .widgets; self?.selectedAddon = .weather }) }
            if settings.deckhandPagePublished {
                add("Mac", "Clock picture", .info, lastCoverRefreshAt.map { "Updated \($0.formatted(date: .omitted, time: .shortened)); refreshed hourly while Deckhand runs." } ?? "Not refreshed yet in this session (hourly while Deckhand runs).")
            }
            let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
            add("Mac", "Versions", .info, "Deckhand \(v) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
            self.doctorItems = out.sorted { $0.state < $1.state }
        }
    }

    /// Plain-text report for pasting into a chat or an issue.
    func doctorReportText(settings: AppSettings) -> String {
        var s = "Deckhand status report — \(Date().formatted(date: .abbreviated, time: .standard))\n"
        s += "CoreBar \(selectedCoreBar?.name ?? "-") \(selectedCoreBar?.serialNo ?? "") @ \(ipForSelected() ?? "-")\n"
        s += "Bar cards: \(settings.coreCards.joined(separator: ", ")) · published: \(settings.deckhandPagePublished)\n"
        s += "Cube cards: \(settings.vivoCards.map(\.rawValue).joined(separator: ", ")) · mode: \(settings.vivoSwitchMode.rawValue) · every \(settings.vivoSeconds) s\n"
        s += "Bindings: knob turn → Mac volume, knob press → mute; DotKey 1/2 → cube card 1/2, 3 → next card, hold 3 → Standard page\n"
        for i in doctorItems {
            let mark: String = { switch i.state { case .ok: return "OK  "; case .warn: return "WARN"; case .fail: return "FAIL"; case .info: return "info" } }()
            s += "\(mark) [\(i.group)] \(i.name): \(i.detail)\n"
        }
        s += "\nRecent activity:\n" + log.prefix(12).map { "  \($0.time.formatted(date: .omitted, time: .standard)) \($0.text)" }.joined(separator: "\n")
        s += "\n\nLast wire-log lines:\n" + WireLog.shared.recent().suffix(30).map { "  " + $0 }.joined(separator: "\n")
        return s
    }
}
