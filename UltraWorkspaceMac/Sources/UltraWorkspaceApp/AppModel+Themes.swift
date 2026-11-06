import Foundation
import AppKit
import CryptoKit
import UltraBarKit

@MainActor
extension AppModel {
    /// Max layers in one VivoCube package (official client limit).
    static let maxVivoLayers = 6
    /// Widget id used for layer N (layer 1 → 101, the id "Recover display" falls back to).
    static func widgetId(forLayer n: Int) -> Int { 100 + n }
    /// Seconds to let the VivoCube download + apply a package after the CoreBar
    /// accepts it (`state:200` only means the module acknowledged the command).
    static let vivoSettleSeconds: UInt64 = 10

    /// Send the picked cards to the VivoCube as ONE package (≤6 layers), wait for the
    /// cube to apply it, then show card 1. "Switch every n s" = a Mac timer that writes
    /// property 9; "only by button" leaves switching to the DotKey / bar button.
    func sendToCube(settings: AppSettings) {
        themeTask?.cancel(); themeTask = nil
        let cards = settings.cubePackageCards
        guard let bar = selectedCoreBar, let session = session(for: bar), let serial = vivoCubeSerial else {
            cubeProgress.failNow("Pair a CoreBar with a VivoCube first."); themeRunning = false; return
        }
        guard !cards.isEmpty else { cubeProgress.failNow("Add at least one card."); themeRunning = false; return }
        let timed = settings.vivoSwitchMode == .timed && cards.count > 1
        themeRunning = timed
        settings.vivoRotationOn = timed
        let interval = max(10, settings.vivoSeconds)
        let refreshEvery = TimeInterval(max(300, interval * cards.count))
        cubeProgress.begin([("render", cards.count == 1 ? "Drawing \(settings.cardTitle(cards[0]))" : "Drawing \(cards.count) cards"),
                            ("upload", "Uploading"), ("apply", "Cube applying"), ("show", "Showing card 1")])
        themeTask = Task {
            defer { if timed { self.themeRunning = false } }
            self.cubeProgress.run("render")
            guard await self.uploadPackage(cards, settings: settings, session: session, serial: serial, force: true) else {
                // Timed switching stays wanted (vivoRotationOn): try the whole Send again in a minute instead of
                // leaving the cube on one card until someone presses Send (seen after a restart, "reply error:238").
                if timed, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    // A new task, so this one's defer (themeRunning = false) runs before the new Send sets it again.
                    if !Task.isCancelled, settings.vivoRotationOn { Task { @MainActor in self.sendToCube(settings: settings) } }
                }
                return
            }
            if Task.isCancelled { return }
            self.cubeProgress.run("apply", note: "about \(Self.vivoSettleSeconds) s")
            try? await Task.sleep(nanoseconds: Self.vivoSettleSeconds * 1_000_000_000)
            if Task.isCancelled { return }
            if let st = await session.readProperty(serial: serial, propertyId: Proto.Property.wifi) { self.vivoWiFiState = Int(st) }
            if self.cubeOffline {
                self.cubeProgress.fail("apply", "The bar accepted the package, but the cube's Wi-Fi is \(self.cubeWiFiLabel), so it cannot download it. The cube keeps showing its previous cards. Set the cube's Wi-Fi (Maintenance) and send again.")
                self.say("The cube is not on Wi-Fi — it still shows its previous cards.")
                self.themeRunning = false; settings.vivoRotationOn = false
                return
            }
            self.cubeProgress.done("apply")
            self.cubeProgress.run("show")
            let code = await self.showCubeCard(1, session: session, serial: serial)
            if code == 200 { self.cubeProgress.done("show", note: settings.cardTitle(cards[0])) }
            else { self.cubeProgress.fail("show", "The bar did not confirm the card switch. Try “Fix black screen” under Maintenance.") }
            self.say(timed ? "Cube: \(cards.map { settings.cardTitle($0) }.joined(separator: ", ")) — switching every \(interval) s."
                           : (cards.count == 1 ? "\(settings.cardTitle(cards[0])) is on the cube." : "\(cards.count) cards on the cube; switch them with the DotKey or the bar's button."))
            guard timed else { return }
            var lastRefresh = Date()
            var step = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                if Task.isCancelled { break }
                if Date().timeIntervalSince(lastRefresh) >= refreshEvery {
                    // One attempt per refresh interval, whatever the outcome: a failing upload is not something to
                    // hammer every tick (2026-11-04: 259 retries in two hours, a failure line in Activity each time).
                    lastRefresh = Date()
                    if await self.uploadPackage(cards, settings: settings, session: session, serial: serial, force: false) {
                        try? await Task.sleep(nanoseconds: Self.vivoSettleSeconds * 1_000_000_000)
                    }
                    if Task.isCancelled { break }
                }
                step += 1
                // Step over the layers the cube actually has (a card that could not be drawn was skipped), not the list.
                let layer = (step % max(1, self.lastPublishedVivoLayers)) + 1
                _ = await self.showCubeCard(layer, session: session, serial: serial)
            }
        }
    }

    /// Ask for macOS permissions a card needs the moment it is added, so the
    /// prompt appears while the user is looking (not later from a timer).
    func requestCardPermissions(_ t: Theme) {
        guard t == .calendar else { return }
        Task {
            if CalendarSource.authStatus() == .notDetermined {
                let ok = await CalendarSource.requestAccess()
                self.say(ok ? "Calendar access granted — the card shows your next events." : "Calendar access was not granted. Allow it in System Settings → Privacy & Security → Calendars.")
            } else if CalendarSource.authStatus() == .denied {
                self.say("Calendar access is off for Deckhand. Allow it in System Settings → Privacy & Security → Calendars.")
            }
        }
    }

    /// Point the cube at card `layer` (1-based) and remember what it should be showing.
    @discardableResult
    func showCubeCard(_ layer: Int, session: CoreBarSession? = nil, serial: String? = nil) async -> Int? {
        guard let bar = selectedCoreBar, let session = session ?? self.session(for: bar), let serial = serial ?? vivoCubeSerial else { return nil }
        let code = await session.setLayer(serial: serial, layer: layer, widget: Self.widgetId(forLayer: layer))
        if code == 200 {
            vivoLayerIndex = layer - 1
            vivoLayerShowing = layer; vivoWidgetShowing = Self.widgetId(forLayer: layer)
            currentThemeLabel = (layer - 1 < vivoLayerNames.count) ? vivoLayerNames[layer - 1] : ""
        }
        return code
    }

    /// ◀ ▶ on the VivoCube page: step through the last package from the Mac.
    func stepCube(_ delta: Int) {
        let count = max(1, vivoLayerNames.count)
        let current = (vivoLayerShowing ?? (vivoLayerIndex + 1)) - 1
        let next = ((current + delta) % count + count) % count + 1
        Task { _ = await self.showCubeCard(next) }
    }

    /// Render `themes` into layers 1…n (widget 100+n) and upload a single package.
    /// True when the cube reports "connected". If it reports "connecting", re-send its
    /// current Wi-Fi settings once and wait up to 30 s for the join to complete.
    func ensureCubeOnWiFi(session: CoreBarSession, serial: String) async -> Bool {
        if let st = await session.readProperty(serial: serial, propertyId: Proto.Property.wifi) { vivoWiFiState = Int(st) }
        if !cubeOffline { return true }
        guard vivoWiFiState == CoreBarSession.CubeWiFiState.connecting.rawValue,
              let w = await session.readModuleWiFi(serial: serial), !w.ssid.isEmpty else { return false }
        cubeProgress.run("upload", note: "cube still joining “\(w.ssid)” — nudging it")
        say("The cube is still joining “\(w.ssid)” — sending its Wi-Fi settings again to complete the join…")
        _ = await session.writeModuleWiFi(serial: serial, w)
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { return false }
            if let st = await session.readProperty(serial: serial, propertyId: Proto.Property.wifi) { vivoWiFiState = Int(st) }
            if !cubeOffline { return true }
        }
        return false
    }

    /// `force: false` (the timed refresh) skips the upload when the pictures are the same as last time: every
    /// accepted upload rewrites the cube's flash and uses one of the launcher's upload slots (see
    /// `CoreBarSession.UploadReply.launcherExhausted`). When the launcher is out of slots, Deckhand restarts it
    /// over ADB and sends once more.
    private func uploadPackage(_ themes: [Theme], settings: AppSettings, session: CoreBarSession, serial: String, force: Bool) async -> Bool {
        var layers: [DeployPackager.Layer] = []
        var names: [String] = []
        var previews: [Int: NSImage] = [:]
        for (i, t) in themes.enumerated() {
            guard let rgba = await renderTheme(t, settings: settings) else {
                say("\(settings.cardTitle(t)): could not be drawn — skipped."); continue
            }
            names.append(settings.cardTitle(t))
            if let png = Self.pngData(fromRGBA: rgba, width: 240, height: 240), let img = NSImage(data: png) { previews[i + 1] = img }
            let bin = DeviceImage.encode(width: 240, height: 240, rgba: rgba)
            layers.append(.init(layerId: i + 1, widgetId: Self.widgetId(forLayer: i + 1), defaultBin: bin, pressedBin: bin))
        }
        guard !layers.isEmpty else { cubeProgress.fail("render", "None of the cards could be drawn."); return false }
        cubeProgress.done("render")
        var hasher = SHA256()
        for l in layers { hasher.update(data: Data(l.defaultBin)) }
        let digest = Data(hasher.finalize())
        if !force, digest == lastCubeDigest {
            WireLog.shared.event("cube: pictures unchanged — not uploaded again")
            vivoLayerNames = names; vivoLayerImages = previews
            return true
        }
        let tgz = DeployPackager.buildTgz(layers: layers, defaultLayer: 1)
        cubeProgress.run("upload", note: "\(max(1, tgz.count / 1024)) KB")
        // The cube downloads the package itself over Wi-Fi, and the bar only forwards
        // the command while the cube reports "connected" (property 6 = 1). A cube
        // stuck at "connecting" (3) rejects every upload with error 4; re-sending its
        // own Wi-Fi settings completes the join (hardware, 2026-11-03).
        if await !ensureCubeOnWiFi(session: session, serial: serial) {
            cubeProgress.fail("upload", "The cube's Wi-Fi is \(cubeWiFiLabel), so it cannot download cards. Set its Wi-Fi under Maintenance, wait for “connected”, then send again.")
            return false
        }
        func accepted() {
            lastPublishedVivoLayers = layers.count
            settings.vivoLayerCount = layers.count
            vivoLayerNames = names
            vivoLayerImages = previews
            vivoLayerIndex = 0
            lastCubeSentAt = Date()
            lastCubeDigest = digest
            cubeProgress.done("upload")
        }
        do {
            _ = try await session.upload(serial: serial, tgz: tgz)
            // A newer Send replaced this task while the upload was in flight: its package is the one on the
            // cube now, so this one's names and previews must not overwrite it.
            if Task.isCancelled { return false }
            accepted()
            return true
        } catch {
            if case UltraBarError.uploadRejected(let why) = error, why == CoreBarSession.launcherExhaustedText,
               await restartBarLauncher(reason: "it is out of upload slots") {
                // The launcher takes ~15 s to come back and re-enumerate its modules; then once more.
                cubeProgress.run("upload", note: "launcher restarted — sending again")
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                if Task.isCancelled { return false }
                if (try? await session.upload(serial: serial, tgz: tgz)) == true { accepted(); return true }
            }
            let msg = FriendlyError.text(error)
            cubeProgress.fail("upload", msg)
            say("Sending to the cube did not complete: \(msg)")
            return false
        }
    }

    /// Panel-size experiment: push an opaque `size`×`size` test pattern (frame,
    /// rings, label) as layer 1 / widget 101 so the physical resolution of the
    /// VivoCube can be read off the glass. 240 is the official 100 % icon size;
    /// Hardware test 2026-11-01: the panel IS 240 × 240 (280 px is not shown);
    /// the wide-looking border is the bezel. Kept as an upload diagnostic.
    func sendPanelSizeTest(serial: String, size: Int) {
        guard let bar = selectedCoreBar, let session = session(for: bar) else { return }
        let w = size, h = size
        guard let g = CardKit.context(width: w, height: h) else { return }
        let ctx = g.ctx
        ctx.setFillColor(CGColor(red: 0.06, green: 0.06, blue: 0.10, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // 4 px frame at the very edge: if visible on all sides, the panel is ≥ size.
        ctx.setStrokeColor(CGColor(red: 1, green: 0.3, blue: 0.2, alpha: 1)); ctx.setLineWidth(8)
        ctx.stroke(CGRect(x: 4, y: 4, width: w - 8, height: h - 8))
        // Rings every 40 px from the centre to read the scale.
        ctx.setStrokeColor(CGColor(gray: 0.7, alpha: 1)); ctx.setLineWidth(2)
        var r = 40
        while r < size / 2 { ctx.strokeEllipse(in: CGRect(x: w/2 - r, y: h/2 - r, width: 2*r, height: 2*r)); r += 40 }
        // Label
        let label = "\(size)" as NSString
        let font = NSFont.systemFont(ofSize: CGFloat(size) * 0.28, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        CardKit.withAppKit(g) {
            let sz = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: (CGFloat(w) - sz.width) / 2, y: (CGFloat(h) - sz.height) / 2), withAttributes: attrs)
        }
        guard let rgba = CardKit.rgba(g, width: w, height: h) else { return }
        let bin = DeviceImage.encode(width: w, height: h, rgba: rgba)
        let tgz = DeployPackager.buildTgz(layers: [.init(layerId: 1, widgetId: 101, defaultBin: bin, pressedBin: bin)], defaultLayer: 1)
        say("Sending \(size)×\(size) test pattern to \(serial)… (\(tgz.count) B)")
        Task {
            do {
                _ = try await session.upload(serial: serial, tgz: tgz)
                self.selectFirstLayerAfterSettle(session: session, serial: serial)
                self.say("\(size)×\(size) test accepted — in ~10 s: is the red frame visible on all four sides? Then the panel is ≥ \(size) px.")
            } catch { self.say("Size test failed: \(error.localizedDescription)") }
        }
    }

    /// Put a black VivoCube back: screen on + layer 1 / widget 101.
    func recoverVivoDisplay(serial: String) {
        guard let bar = selectedCoreBar, let session = session(for: bar) else { return }
        Task {
            let before = await session.readLayerWidget(serial: serial)
            let ok = await session.recoverDisplay(serial: serial)
            WireLog.shared.event("recover: before=\(before.map { "\($0.layer)/\($0.widget)" } ?? "?") ok=\(ok)")
            if ok { self.vivoScreenOn = true; self.vivoLayerShowing = 1; self.vivoWidgetShowing = Self.widgetId(forLayer: 1); self.vivoLayerIndex = 0 }
            self.say(ok ? "Cube fixed: screen on, showing card 1." : "The bar did not confirm the fix — try again, or restart the cube.")
        }
    }

    /// After a single-layer upload, make sure the cached layer/widget points at it.
    func selectFirstLayerAfterSettle(session: CoreBarSession, serial: String) {
        Task {
            try? await Task.sleep(nanoseconds: Self.vivoSettleSeconds * 1_000_000_000)
            _ = await session.setLayer(serial: serial, layer: 1, widget: Self.widgetId(forLayer: 1))
        }
    }

    func stopThemeRotation(settings: AppSettings? = nil) {
        themeTask?.cancel(); themeTask = nil
        themeRunning = false
        settings?.vivoRotationOn = false
        say("Timed switching is off; the cube stays on its current card.")
    }

    /// Render a widget to an NSImage for an on-screen preview (240×240 cube).
    /// Pure/local — never touches the device.
    func previewImage(_ theme: Theme, settings: AppSettings) async -> NSImage? {
        guard let rgba = await renderTheme(theme, settings: settings),
              let png = AppModel.pngData(fromRGBA: rgba, width: 240, height: 240) else { return nil }
        return NSImage(data: png)
    }

    private func renderTheme(_ theme: Theme, settings: AppSettings) async -> [UInt8]? {
        switch theme {
        case .weather:
            do {
                let now = try await resolveWeather(settings: settings, metric: settings.units == .metric)
                lastWeather = now
                WireLog.shared.event("weather: \(Int(now.temperature.rounded()))\(now.unitSuffix) \(now.sky.label) @ \(now.place.isEmpty ? "?" : now.place)")
                return WeatherCard.render(width: 240, height: 240, now: now, clock24h: settings.clock24h)
            } catch {
                say("Weather unavailable: \(error.localizedDescription)")
                WireLog.shared.event("weather FAILED: \(error.localizedDescription)")
                return WeatherCard.render(width: 240, height: 240, now: nil, clock24h: settings.clock24h)
            }
        case .music:
            refreshNowPlaying()
            let art = AppleMusic.currentArtwork()
            return NowPlayingCard.render(size: 240, art: art, title: nowPlaying.title, artist: nowPlaying.artist)
        case .cpu, .network, .battery, .disk, .worldclock, .clock, .diskio, .topcpu, .uptime:
            // `isLiveFeed`: not offered for the cube since 2026-11-03 (the bar draws its own live
            // cards); only reachable through a stale settings.json, which `vivoCards` filters out.
            return nil
        case .claude:
            let snap = await Task.detached { ClaudeUsage.snapshot() }.value
            return StatCard.claude(snap, plan: settings.claudePlan.title, dailyBudget: settings.claudeDailyBudget, size: 240)
        case .crypto, .crypto2, .crypto3, .crypto4, .crypto5:
            let slot = theme.cryptoSlot ?? 0
            let coins = settings.cryptoCoinsConfigured
            let id = slot < coins.count ? coins[slot] : ""
            let day = id.isEmpty ? nil : await CryptoStats.today(id: id, currency: settings.cryptoCurrency)
            return CryptoCoinCard.render(day, coinId: id, currency: settings.cryptoCurrency, size: 240)
        case .date:
            return DateCard.render(size: 240, style: settings.dateStyle, showWeekday: settings.dateShowWeekday, showYear: settings.dateShowYear)
        case .calendar:
            var auth = CalendarSource.authStatus()
            if auth == .notDetermined { _ = await CalendarSource.requestAccess(); auth = CalendarSource.authStatus() }
            let events = auth == .authorized ? await CalendarSource.upcoming(calendarIDs: settings.calendarIDs) : []
            return CalendarCard.render(events, auth: auth, size: 240, clock24h: settings.clock24h)
        case .picture:
            return Self.pictureRGBA(path: settings.vivoPicturePath, size: 240)
        }
    }

    /// The "Picture" card: a user image scaled to the panel (letterboxed on black).
    nonisolated static func pictureRGBA(path: String, size: Int) -> [UInt8]? {
        guard !path.isEmpty, let img = NSImage(contentsOfFile: path),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return DeviceImage.rgba(from: cg, width: size, height: size)
    }
}
