import Foundation
import AppKit
import UltraBarKit

/// CoreBar "pages" (vendor profiles). There is no wallpaper / full-screen image
/// on the CoreBar: a page is a strip of vendor cards, and the only place our
/// own image can appear is as the clock (TIME) card's cover + blurred
/// background. The device cannot report page contents, only ids (30710), and
/// BATCH_SAVE_PROFILE replaces everything — so this path is explicit and
/// confirmed by the user every time.
@MainActor
extension AppModel {
    static let deckhandPageId = "deckhand.page"
    static let defaultPageId = "default"

    /// Read-only: list page ids/names on the CoreBar.
    func refreshPages() {
        guard let bar = selectedCoreBar, let session = session(for: bar) else { return }
        Task {
            do {
                let pages = try await session.listPages()
                self.corebarPages = pages
                WireLog.shared.event("pages: " + pages.map { "\($0.name) [\($0.id)]" }.joined(separator: ", "))
            } catch { self.say("The bar did not answer when asked for its pages: \(FriendlyError.text(error))") }
        }
    }

    /// Coordinates for the device's own WEATHER card (same chain as our weather:
    /// manual lat/lon → manual city → Mac location → IP geolocation).
    func resolveCoordinates(settings: AppSettings) async -> (lat: String, lon: String, place: String)? {
        func fmt(_ d: Double) -> String { String(format: "%.4f", d) }
        if settings.locationMode == .manual {
            if let lat = Double(settings.manualLat.replacingOccurrences(of: ",", with: ".")),
               let lon = Double(settings.manualLon.replacingOccurrences(of: ",", with: ".")) { return (fmt(lat), fmt(lon), settings.manualCity) }
            if !settings.manualCity.isEmpty, let p = try? await OpenMeteo.geocode(settings.manualCity) { return (fmt(p.latitude), fmt(p.longitude), p.name) }
        }
        if let loc = await MacLocation().once() { return (fmt(loc.lat), fmt(loc.lon), loc.place) }
        if !settings.manualCity.isEmpty, let p = try? await OpenMeteo.geocode(settings.manualCity) { return (fmt(p.latitude), fmt(p.longitude), p.name) }
        if let ip = await OpenMeteo.ipLocate() { return (fmt(ip.lat), fmt(ip.lon), ip.city) }
        return nil
    }

    /// Render the square cover we put on the clock card.
    func renderPageCover(settings: AppSettings) async -> Data? {
        let now = try? await resolveWeather(settings: settings, metric: settings.units == .metric)
        guard let rgba = WeatherCard.render(width: 480, height: 480, now: now, clock24h: settings.clock24h) else { return nil }
        // NOTE: the cover is a static picture — the CoreBar's own TIME card shows the
        // live time next to it; the cover is refreshed daily so its date stays right.
        return Self.pngData(fromRGBA: rgba, width: 480, height: 480)
    }

    /// Pages other than the standard one and Deckhand's own — made in the official app; a publish removes them.
    var foreignPages: [CoreBarSession.PageInfo] { corebarPages.filter { ![Self.defaultPageId, Self.deckhandPageId].contains($0.id) } }
    /// Confirm only when something could be lost: first publish, or foreign pages present.
    func publishNeedsConfirmation(settings: AppSettings) -> Bool { !settings.deckhandPagePublished || !foreignPages.isEmpty }

    /// Replace the bar's pages with: its standard page + the Deckhand page, then show the Deckhand page.
    /// Destructive for pages made in the official app (confirmed in the UI when that applies).
    func publishDeckhandPage(settings: AppSettings) {
        guard let bar = selectedCoreBar, let session = session(for: bar) else { pageProgress.failNow("Pair a CoreBar first."); return }
        guard !isWorking else { return }
        isWorking = true
        pageProgress.begin([("cover", "Clock picture"), ("icons", "Button icons"), ("pages", "Pages written"), ("show", "Showing the Deckhand page")])
        Task {
            defer { self.isWorking = false }
            self.pageProgress.run("cover")
            guard let png = await self.renderPageCover(settings: settings) else { self.pageProgress.fail("cover", "Could not draw the clock picture."); return }
            do {
                try await session.uploadPageAsset(png, name: "cover.png")
                self.pageProgress.done("cover")
                self.pageProgress.run("icons")
                let coords = await self.resolveCoordinates(settings: settings)
                let weatherParam: [String: String] = ["lat": coords?.lat ?? "", "lon": coords?.lon ?? ""]
                try await self.uploadButtonIcons(session: session)
                let key = settings.accuWeatherKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty {
                    do { _ = try await session.setWeatherAPIKey(key, metric: settings.units == .metric) }
                    catch { self.say("The bar did not accept the AccuWeather key: \(FriendlyError.text(error))") }
                }
                self.pageProgress.done("icons")
                self.pageProgress.run("pages")
                // Cards subscribe to the module uid (= serial in our gateway config).
                let senseSerial = self.modules.first(where: { $0.type == "SENSE_CUBE" }).map { $0.deviceId.isEmpty ? $0.serial : $0.deviceId }
                let standard: [String: Any] = [
                    "id": Self.defaultPageId, "name": "Standard Mode", "isDefault": false, "showName": true, "iconScale": 100,
                    "icon": "http://cdn.lifex360.com/ultrabar/desktop/default.png",
                    "module": self.moduleBindings(),
                    "widget": [
                        ["id": "sys.component.time", "type": "TIME", "name": "Time", "icon": ""],
                        ["id": "sys.component.weather", "type": "WEATHER", "name": "Weather", "param": weatherParam],
                    ],
                ]
                var w: [[String: Any]] = []
                for card in settings.coreCards {
                    switch card {
                    case "TIME":
                        // Own id: the bar copies a DEVICE-stored picture for a known widget id
                        // (that is how the stock tiger kept winning on sys.component.time).
                        w.append(["id": "deckhand.time", "type": "TIME", "name": "Deckhand", "icon": "deckhand/cover.png"])
                    case "WEATHER":
                        w.append(["id": "sys.component.weather", "type": "WEATHER", "name": "Weather", "param": weatherParam])
                    case "WORLD_TIME":
                        w.append(["id": "deckhand.worldtime", "type": "WORLD_TIME", "name": Self.worldTimeName(), "icon": "", "iconScale": 0, "param": ["offset": Self.worldTimeOffset()]])
                    case "SENSE_TEMP":
                        if let senseSerial { w.append(["id": "deckhand.sense.temp", "type": "SENSE_CUBE_TEMP", "name": "Temperature", "param": ["uid": senseSerial]]) }
                    case "SENSE_HUM":
                        if let senseSerial { w.append(["id": "deckhand.sense.hum", "type": "SENSE_CUBE_HUM", "name": "Humidity", "param": ["uid": senseSerial]]) }
                    case "CPU": w.append(["id": "deckhand.cpu", "type": "CPU", "name": "Mac CPU", "param": ["data": ""]])
                    case "MEMORY": w.append(["id": "deckhand.mem", "type": "MEMORY", "name": "Mac memory", "param": ["data": ""]])
                    case "STORAGE": w.append(["id": "deckhand.storage", "type": "STORAGE", "name": "Mac storage", "param": ["data": ""]])
                    case "NETWORK": w.append(["id": "deckhand.net", "type": "NETWORK", "name": "Mac network", "param": ["data": ""]])
                    case "NEXT_LAYER":
                        w.append(["id": "deckhand.next", "type": "PC_CONTROL", "name": "Next card", "icon": "deckhand/btn-next.png", "iconScale": 80,
                                  "param": ["output": 10, "payload": ["deckhand": "next"]]])
                    case "MUSIC":
                        w.append(["id": "deckhand.music", "type": "PC_CONTROL", "name": "Play / Pause", "icon": "deckhand/btn-music.png", "iconScale": 80,
                                  "param": ["output": 10, "payload": ["deckhand": "music.playpause"]]])
                    default: break
                    }
                }
                let deckhand: [String: Any] = [
                    "id": Self.deckhandPageId, "name": "Deckhand", "isDefault": true,   // the page the bar boots into "showName": true, "iconScale": 100,
                    "icon": "deckhand/cover.png",
                    "module": self.moduleBindings(),
                    "widget": w,
                ]
                _ = try await session.savePages([standard, deckhand])
                self.pageProgress.done("pages", note: "\(w.count) cards")
                self.pageProgress.run("show")
                // The bar ignores a switch to the page already showing; bounce via the
                // standard page so a re-publish reloads the new layout.
                if self.currentPageId == Self.deckhandPageId {
                    _ = try? await session.switchPage(id: Self.defaultPageId)
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
                _ = try await session.switchPage(id: Self.deckhandPageId)
                self.currentPageId = Self.deckhandPageId
                settings.deckhandPagePublished = true
                self.lastPagePublishedAt = Date()
                self.pageProgress.done("show")
                self.say("The bar shows the Deckhand page: \(w.count) cards\(coords.map { " · weather for \($0.place)" } ?? ""). ✓")
                self.refreshPages()
            } catch {
                let msg = FriendlyError.text(error)
                let stepId = self.pageProgress.steps.first(where: { $0.state == .running })?.id ?? "pages"
                self.pageProgress.fail(stepId, msg)
                self.say("Publishing the page did not complete: \(msg)")
            }
        }
    }

    // MARK: Module bindings (KnobKey → Mac volume, DotKey → VivoCube widgets / Deckhand commands)

    /// Profile `module[]` entries so the modules do something useful on the
    /// device itself: KnobKey turns = Mac volume (device polls GET_VOLUME and
    /// sends SET_VOLUME over the link); DotKey buttons switch VivoCube widgets
    /// directly on the CoreBar (VIVO_CUBE_TOGGLE) and button 3 asks the Mac for
    /// "next". Vendor keyCodes: button1 = 2, button2 = 1, button3 = 0.
    func moduleBindings() -> [[String: Any]] {
        var out: [[String: Any]] = []
        if let knob = modules.first(where: { $0.type == "KNOB_KEY" }) {
            out.append([
                "productId": "KNOB_KEY", "serialNo": knob.serial,
                "config": [
                    "button": ["keyCode": 0, "singleClick": ["show": false, "name": "Mute", "icon": "",
                        "actions": [["type": "PC_CONTROL", "id": "1", "name": "Mute",
                                     "values": [["id": "1", "value": ["output": 10, "payload": ["deckhand": "mute"]]]]]]]],
                    "clockwise": ["id": "pc:volume", "type": "PC_VOLUME"],
                    "counterclockwise": ["id": "pc:volume", "type": "PC_VOLUME"],
                ],
            ])
        }
        if let sense = modules.first(where: { $0.type == "SENSE_CUBE" }) {
            // A SENSE_CUBE module entry makes the launcher instantiate the module for
            // this profile; it then publishes temp/humidity/light on the module uid,
            // which is what the SENSE_CUBE_* cards subscribe to. No details needed.
            out.append(["productId": "SENSE_CUBE", "serialNo": sense.serial, "config": []])
        }
        if let dot = modules.first(where: { $0.type == "DOT_KEY" }) {
            var buttons: [[String: Any]] = []
            if let vivo = modules.first(where: { $0.isVivoCube }) {
                let uid = vivo.deviceId.isEmpty ? vivo.serial : vivo.deviceId
                for (keyCode, layer) in [(2, 1), (1, 2)] {
                    buttons.append(["keyCode": keyCode, "singleClick": ["show": false, "name": "Widget \(layer)", "icon": "",
                        "actions": [["type": "VIVO_CUBE_TOGGLE", "id": uid, "name": "Widget \(layer)",
                                     "values": [["id": "1", "value": "\(layer)"], ["id": "2", "value": "\(Self.widgetId(forLayer: layer))"]]]]]])
                }
            }
            buttons.append(["keyCode": 0,
                "singleClick": ["show": false, "name": "Next", "icon": "",
                    "actions": [["type": "PC_CONTROL", "id": "1", "name": "Next",
                                 "values": [["id": "1", "value": ["output": 10, "payload": ["deckhand": "next"]]]]]]],
                "longPress": ["show": false, "name": "Standard page", "icon": "",
                    "actions": [["type": "CHANGE_PROFILE", "id": "profile", "name": "Standard page",
                                 "values": [["id": "1", "value": Self.defaultPageId]]]]]])
            out.append(["productId": "DOT_KEY", "serialNo": dot.serial, "config": buttons])
        }
        return out
    }

    /// Icons for the PC_CONTROL button cards (256×256 PNG, SF Symbol on a tile).
    func uploadButtonIcons(session: CoreBarSession) async throws {
        for (name, symbol) in [("btn-next.png", "forward.end.fill"), ("btn-music.png", "playpause.fill")] {
            if let png = Self.symbolTilePNG(symbol) { try await session.uploadPageAsset(png, name: name) }
        }
    }

    nonisolated static func symbolTilePNG(_ symbol: String, size: Int = 256) -> Data? {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.32, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 48, yRadius: 48).fill()
            if let sym = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: CGFloat(size) * 0.42, weight: .semibold)) {
                let tinted = NSImage(size: sym.size, flipped: false) { r in
                    sym.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true
                }
                let s = tinted.size
                tinted.draw(in: NSRect(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2, width: s.width, height: s.height))
            }
            return true
        }
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// WORLD_TIME offset for this Mac's zone, in the firmware's "GMT+1:00" form.
    nonisolated static func worldTimeOffset(_ tz: TimeZone = .current) -> String {
        let secs = tz.secondsFromGMT()
        let sign = secs < 0 ? "-" : "+"
        let h = abs(secs) / 3600, m = (abs(secs) % 3600) / 60
        return String(format: "GMT%@%d:%02d", sign, h, m)
    }
    nonisolated static func worldTimeName(_ tz: TimeZone = .current) -> String {
        tz.identifier.split(separator: "/").last.map(String.init)?.replacingOccurrences(of: "_", with: " ") ?? tz.identifier
    }

    /// The clock-card cover carries Deckhand's free (Open-Meteo) weather + date.
    /// Refresh it once an hour (and at launch) while the Deckhand page is
    /// published — the CoreBar's own clock shows the live time next to it.
    func startDailyCoverRefresh(settings: AppSettings) {
        coverRefreshTask?.cancel()
        coverRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                if settings.deckhandPagePublished, let self { self.refreshDeckhandCover(settings: settings) }
                try? await Task.sleep(nanoseconds: 3_600_000_000_000) // 1 h
            }
        }
    }

    /// Experimental "keep awake": every 4 minutes re-select whatever page the bar is on. The protocol has no
    /// known screen-timeout setting for the bar; a page switch is the only known action that redraws its screen.
    func startKeepAwake(settings: AppSettings) {
        keepAwakeTask?.cancel()
        keepAwakeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 240_000_000_000)
                guard let self, settings.keepBarAwake, let bar = self.selectedCoreBar, let session = self.session(for: bar) else { continue }
                let id = self.currentPageId ?? Self.defaultPageId
                _ = try? await session.switchPage(id: id)
                WireLog.shared.event("keep-awake: re-selected page \(id)")
            }
        }
    }

    /// Non-destructive: switch pages by id.
    /// After (re)connecting: if the Deckhand page is on the bar, show it. Covers a bar that
    /// rebooted into its default/black screen and Deckhand starting after the bar.
    func showDeckhandPageIfPublished() {
        guard let bar = selectedCoreBar, let session = session(for: bar) else { return }
        Task {
            guard let pages = try? await session.listPages() else { return }
            self.corebarPages = pages
            guard pages.contains(where: { $0.id == Self.deckhandPageId }) else { return }
            if (try? await session.switchPage(id: Self.deckhandPageId)) != nil {
                self.currentPageId = Self.deckhandPageId
                WireLog.shared.event("pages: showing the Deckhand page after connect")
            }
        }
    }

    func switchPage(id: String) {
        guard let bar = selectedCoreBar, let session = session(for: bar) else { return }
        Task {
            do {
                _ = try await session.switchPage(id: id); self.currentPageId = id
                let name = self.corebarPages.first { $0.id == id }?.name ?? id
                self.say("The bar now shows the “\(name)” page.")
            } catch { self.say("Could not switch pages: \(FriendlyError.text(error))") }
        }
    }

    /// Refresh only the cover image: re-upload the same filename. The device
    /// reloads the current profile on every zip upload (ReloadProfileEvent).
    func refreshDeckhandCover(settings: AppSettings) {
        guard let bar = selectedCoreBar, let session = session(for: bar) else { return }
        Task {
            guard let png = await self.renderPageCover(settings: settings) else { return }
            do { try await session.uploadPageAsset(png, name: "cover.png"); self.lastCoverRefreshAt = Date(); self.say("Clock picture updated on the bar.") }
            catch { self.say("Could not update the clock picture: \(FriendlyError.text(error))") }
        }
    }
}
