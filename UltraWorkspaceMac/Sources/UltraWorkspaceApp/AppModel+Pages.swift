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
                self.say(pages.isEmpty ? "The CoreBar reports no pages (30710 returned an empty list)."
                                       : "Pages on the CoreBar: " + pages.map { "\($0.name) [\($0.id)]" }.joined(separator: ", "))
            } catch { self.say("Could not list pages: \(error.localizedDescription)") }
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

    /// DESTRUCTIVE (user-confirmed): upload the cover, then write the page list =
    /// the device's standard page (re-sent so it survives; its clock keeps the
    /// image the user picked on the device because `icon` is empty) + a
    /// Deckhand page whose clock cover is our image, then switch to it.
    func publishDeckhandPage(settings: AppSettings) {
        guard let bar = selectedCoreBar, let session = session(for: bar) else { say("Pair a CoreBar first."); return }
        guard !isWorking else { return }
        isWorking = true
        say("Rendering the clock-card cover…")
        Task {
            defer { self.isWorking = false }
            guard let png = await self.renderPageCover(settings: settings) else { self.say("Could not render the cover."); return }
            do {
                try await session.uploadPageAsset(png, name: "cover.png")
                self.say("Cover uploaded (deckhand/cover.png). Writing pages…")
                // Device-first: every card below is rendered and updated by the CoreBar
                // itself. Cards marked "fed by Deckhand" get their numbers from the
                // persistent link (the Mac answers CPU/MEMORY/STORAGE/NETWORK queries).
                let coords = await self.resolveCoordinates(settings: settings)
                let weatherParam: [String: String] = ["lat": coords?.lat ?? "", "lon": coords?.lon ?? ""]
                if coords == nil { self.say("No location available — the CoreBar's weather card will use the device's network location.") }
                try await self.uploadButtonIcons(session: session)
                // The CoreBar's own weather card needs an AccuWeather key (the firmware ships a placeholder).
                let key = settings.accuWeatherKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty {
                    do { _ = try await session.setWeatherAPIKey(key, metric: settings.units == .metric); self.say("AccuWeather key stored on the CoreBar for its weather card.") }
                    catch { self.say("Weather key not accepted: \(error.localizedDescription)") }
                } else if settings.coreCards.contains("WEATHER") {
                    self.say("Note: the CoreBar's weather card shows “--” until you enter an AccuWeather API key (free at developer.accuweather.com).")
                }
                let cards = Set(settings.coreCards)
                let senseSerial = self.modules.first(where: { $0.type == "SENSE_CUBE" })?.serial
                let standard: [String: Any] = [
                    "id": Self.defaultPageId, "name": "Standard Mode", "isDefault": true, "showName": true, "iconScale": 100,
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
                        // Own id: TimeParamConverter copies the DEVICE-stored picture for a
                        // widget id if one exists (that is how the tiger kept winning on
                        // sys.component.time). A Deckhand-only id has no stored picture.
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
                        w.append(["id": "deckhand.next", "type": "PC_CONTROL", "name": "Next widget", "icon": "deckhand/btn-next.png", "iconScale": 80,
                                  "param": ["output": 10, "payload": ["deckhand": "next"]]])
                    case "MUSIC":
                        w.append(["id": "deckhand.music", "type": "PC_CONTROL", "name": "Play / Pause", "icon": "deckhand/btn-music.png", "iconScale": 80,
                                  "param": ["output": 10, "payload": ["deckhand": "music.playpause"]]])
                    default: break
                    }
                }
                let deckhandWidgets = w
                let deckhand: [String: Any] = [
                    "id": Self.deckhandPageId, "name": "Deckhand", "isDefault": false, "showName": true, "iconScale": 100,
                    "icon": "deckhand/cover.png",
                    "module": self.moduleBindings(),
                    "widget": deckhandWidgets,
                ]
                let reply = try await session.savePages([standard, deckhand])
                self.say("Pages written (\(reply.prefix(80))). Switching to the Deckhand page…")
                // The launcher ignores a switch to the page that is already showing, so
                // a re-publish would keep the old card order on screen. Bounce via the
                // standard page to force a reload of the new layout.
                if self.currentPageId == Self.deckhandPageId {
                    _ = try? await session.switchPage(id: Self.defaultPageId)
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
                _ = try await session.switchPage(id: Self.deckhandPageId)
                self.currentPageId = Self.deckhandPageId
                settings.deckhandPagePublished = true
                let fed = deckhandWidgets.filter { ["CPU", "MEMORY", "STORAGE", "NETWORK"].contains(($0["type"] as? String) ?? "") }.count
                self.say("CoreBar is showing the Deckhand page: \(deckhandWidgets.count) cards rendered by the CoreBar itself\(coords.map { " · weather for \($0.place)" } ?? "")\(fed > 0 ? " · \(fed) fed live by this Mac" : ""). KnobKey → Mac volume, DotKey → VivoCube widgets. ✓")
                self.refreshPages()
            } catch { self.say("Page publish failed: \(error.localizedDescription)") }
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

    /// Keep the clock-card cover's DATE right without rendering a clock on the
    /// Mac every minute: refresh the cover once a day shortly after midnight
    /// (and at launch) — only if the Deckhand page was published.
    func startDailyCoverRefresh(settings: AppSettings) {
        coverRefreshTask?.cancel()
        coverRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                if settings.deckhandPagePublished, let self { self.refreshDeckhandCover(settings: settings) }
                // Sleep until 00:02 local time.
                let cal = Calendar.current
                let next = cal.nextDate(after: Date(), matching: DateComponents(hour: 0, minute: 2), matchingPolicy: .nextTime) ?? Date().addingTimeInterval(86_400)
                let secs = max(60, next.timeIntervalSinceNow)
                try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
            }
        }
    }

    /// Non-destructive: switch pages by id.
    func switchPage(id: String) {
        guard let bar = selectedCoreBar, let session = session(for: bar) else { return }
        Task {
            do { _ = try await session.switchPage(id: id); self.currentPageId = id; self.say("Switched the CoreBar to page \(id). ✓") }
            catch { self.say("Switch failed: \(error.localizedDescription)") }
        }
    }

    /// Refresh only the cover image: re-upload the same filename. The device
    /// reloads the current profile on every zip upload (ReloadProfileEvent).
    func refreshDeckhandCover(settings: AppSettings) {
        guard let bar = selectedCoreBar, let session = session(for: bar) else { return }
        Task {
            guard let png = await self.renderPageCover(settings: settings) else { return }
            do { try await session.uploadPageAsset(png, name: "cover.png"); self.say("Cover refreshed on the CoreBar. ✓") }
            catch { self.say("Cover refresh failed: \(error.localizedDescription)") }
        }
    }
}
