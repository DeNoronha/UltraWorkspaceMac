import Foundation
import AppKit
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
        let cards = Array(settings.vivoCards.prefix(Self.maxVivoLayers))
        guard let bar = selectedCoreBar, let session = session(for: bar), let serial = vivoCubeSerial else {
            cubeProgress.failNow("Pair a CoreBar with a VivoCube first."); themeRunning = false; return
        }
        guard !cards.isEmpty else { cubeProgress.failNow("Add at least one card."); themeRunning = false; return }
        let timed = settings.vivoSwitchMode == .timed && cards.count > 1
        themeRunning = timed
        settings.vivoRotationOn = timed
        themeIndex = 0
        let interval = max(10, settings.vivoSeconds)
        let refreshEvery = TimeInterval(max(300, interval * cards.count))
        cubeProgress.begin([("render", cards.count == 1 ? "Drawing \(cards[0].title)" : "Drawing \(cards.count) cards"),
                            ("upload", "Uploading"), ("apply", "Cube applying"), ("show", "Showing card 1")])
        themeTask = Task {
            defer { if timed { self.themeRunning = false } }
            self.cubeProgress.run("render")
            guard await self.uploadPackage(cards, settings: settings, session: session, serial: serial) else { return }
            if Task.isCancelled { return }
            self.cubeProgress.run("apply", note: "about \(Self.vivoSettleSeconds) s")
            try? await Task.sleep(nanoseconds: Self.vivoSettleSeconds * 1_000_000_000)
            if Task.isCancelled { return }
            self.cubeProgress.done("apply")
            self.cubeProgress.run("show")
            let code = await self.showCubeCard(1, session: session, serial: serial)
            if code == 200 { self.cubeProgress.done("show", note: cards[0].title) }
            else { self.cubeProgress.fail("show", "The bar did not confirm the card switch. Try “Fix black screen” under Maintenance.") }
            self.say(timed ? "Cube: \(cards.map(\.title).joined(separator: ", ")) — switching every \(interval) s."
                           : (cards.count == 1 ? "\(cards[0].title) is on the cube." : "\(cards.count) cards on the cube; switch them with the DotKey or the bar's button."))
            guard timed else { return }
            var lastRefresh = Date()
            var step = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                if Task.isCancelled { break }
                if Date().timeIntervalSince(lastRefresh) >= refreshEvery {
                    if await self.uploadPackage(cards, settings: settings, session: session, serial: serial) {
                        lastRefresh = Date()
                        try? await Task.sleep(nanoseconds: Self.vivoSettleSeconds * 1_000_000_000)
                    }
                    if Task.isCancelled { break }
                }
                step += 1
                let layer = (step % cards.count) + 1
                _ = await self.showCubeCard(layer, session: session, serial: serial)
            }
        }
    }

    /// Kept for the launch-time resume path.
    func startThemeRotation(settings: AppSettings) { sendToCube(settings: settings) }

    /// Point the cube at card `layer` (1-based) and remember what it should be showing.
    @discardableResult
    func showCubeCard(_ layer: Int, session: CoreBarSession? = nil, serial: String? = nil) async -> Int? {
        guard let bar = selectedCoreBar, let session = session ?? self.session(for: bar), let serial = serial ?? vivoCubeSerial else { return nil }
        let code = await session.setLayer(serial: serial, layer: layer, widget: Self.widgetId(forLayer: layer))
        if code == 200 {
            vivoLayerIndex = layer - 1; themeIndex = layer - 1
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
    private func uploadPackage(_ themes: [Theme], settings: AppSettings, session: CoreBarSession, serial: String) async -> Bool {
        var layers: [DeployPackager.Layer] = []
        var names: [String] = []
        var previews: [Int: NSImage] = [:]
        for (i, t) in themes.enumerated() {
            guard let rgba = await renderTheme(t, settings: settings) else {
                say("\(t.title): could not be drawn — skipped."); continue
            }
            names.append(t.title)
            if let png = Self.pngData(fromRGBA: rgba, width: 240, height: 240), let img = NSImage(data: png) { previews[i + 1] = img }
            let bin = DeviceImage.encode(width: 240, height: 240, rgba: rgba)
            layers.append(.init(layerId: i + 1, widgetId: Self.widgetId(forLayer: i + 1), defaultBin: bin, pressedBin: bin))
        }
        guard !layers.isEmpty else { cubeProgress.fail("render", "None of the cards could be drawn."); return false }
        cubeProgress.done("render")
        let tgz = DeployPackager.buildTgz(layers: layers, defaultLayer: 1)
        cubeProgress.run("upload", note: "\(max(1, tgz.count / 1024)) KB")
        do {
            _ = try await session.upload(serial: serial, tgz: tgz)
            lastPublishedVivoLayers = layers.count
            settings.vivoLayerCount = layers.count
            vivoLayerNames = names
            vivoLayerImages = previews
            vivoLayerIndex = 0
            lastCubeSentAt = Date()
            cubeProgress.done("upload")
            return true
        } catch {
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
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
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
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let sz = label.size(withAttributes: attrs)
        label.draw(at: CGPoint(x: (CGFloat(w) - sz.width) / 2, y: (CGFloat(h) - sz.height) / 2), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = ctx.data else { return }
        let rgba = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: w * h * 4))
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

    /// Render one theme now and push it to a specific VivoCube (default: first).
    func pushTheme(_ theme: Theme, settings: AppSettings, to serial: String? = nil) async {
        guard let bar = selectedCoreBar, let session = session(for: bar),
              let target = serial ?? vivoCubeSerial else { return }
        guard let rgba = await renderTheme(theme, settings: settings) else { return }
        let bin = DeviceImage.encode(width: 240, height: 240, rgba: rgba)
        let layer = DeployPackager.Layer(layerId: 1, widgetId: 101, defaultBin: bin, pressedBin: bin)
        let tgz = DeployPackager.buildTgz(layers: [layer], defaultLayer: 1)
        do { _ = try await session.upload(serial: target, tgz: tgz); selectFirstLayerAfterSettle(session: session, serial: target) }
        catch { say("\(theme.title): push failed (\(error.localizedDescription))") }
    }

    /// Publish one add-on to a specific VivoCube now (user-facing, with status).
    func publishAddon(_ theme: Theme, to serial: String, settings: AppSettings) {
        guard let bar = selectedCoreBar, let session = session(for: bar) else { return }
        say("Publishing \(theme.title) to \(serial)…")
        Task {
            guard let rgba = await self.renderTheme(theme, settings: settings) else {
                self.say("\(theme.title): could not render."); return
            }
            let bin = DeviceImage.encode(width: 240, height: 240, rgba: rgba)
            let layer = DeployPackager.Layer(layerId: 1, widgetId: 101, defaultBin: bin, pressedBin: bin)
            let tgz = DeployPackager.buildTgz(layers: [layer], defaultLayer: 1)
            do {
                _ = try await session.upload(serial: serial, tgz: tgz)
                self.selectFirstLayerAfterSettle(session: session, serial: serial)
                self.say("\(theme.title) accepted by \(serial) — the VivoCube applies it in a few seconds. ✓")
            }
            catch { self.say("\(theme.title): publish failed (\(error.localizedDescription))") }
        }
    }

    /// Render a widget to an NSImage for an on-screen preview (240×240 cube).
    /// Pure/local — never touches the device.
    func previewImage(_ theme: Theme, settings: AppSettings) async -> NSImage? {
        guard let rgba = await renderTheme(theme, settings: settings),
              let png = AppModel.pngData(fromRGBA: rgba, width: 240, height: 240) else { return nil }
        return NSImage(data: png)
    }

    /// Render the wide (1424×280) CoreBar card for preview. Only the weather
    /// card has a wide layout today; other widgets get wide layouts later.
    func previewWideImage(_ theme: Theme, settings: AppSettings) async -> NSImage? {
        let rgba: [UInt8]?
        switch theme {
        case .weather:
            let now = try? await resolveWeather(settings: settings, metric: settings.units == .metric)
            rgba = WeatherCard.render(width: 1424, height: 280, now: now, clock24h: settings.clock24h)
        default:
            rgba = nil
        }
        guard let rgba, let png = AppModel.pngData(fromRGBA: rgba, width: 1424, height: 280) else { return nil }
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
        case .cpu:
            _ = sysStats.sample()
            try? await Task.sleep(nanoseconds: 900_000_000)
            return StatCard.system(sysStats.sample(), size: 240)
        case .network:
            _ = netStats.sample()
            try? await Task.sleep(nanoseconds: 900_000_000)
            return StatCard.network(netStats.sample(), size: 240)
        case .claude:
            let snap = await Task.detached { ClaudeUsage.snapshot() }.value
            return StatCard.claude(snap, size: 240)
        case .battery:
            return BatteryCard.render(BatteryStats.sample(), size: 240)
        case .disk:
            return DiskCard.render(size: 240)
        case .worldclock:
            return WorldClockCard.render(size: 240, zones: WorldClockCard.defaultZones, clock24h: settings.clock24h)
        case .crypto:
            let coins = await CryptoStats.fetch(currency: "eur")
            return CryptoCard.render(coins, size: 240, currencySymbol: CryptoStats.suffix(for: "eur"))
        case .calendar:
            var auth = CalendarSource.authStatus()
            if auth == .notDetermined { _ = await CalendarSource.requestAccess(); auth = CalendarSource.authStatus() }
            let events = auth == .authorized ? await CalendarSource.upcoming() : []
            return CalendarCard.render(events, auth: auth, size: 240, clock24h: settings.clock24h)
        case .diskio:
            _ = diskStats.sample()
            try? await Task.sleep(nanoseconds: 900_000_000)
            return DiskActivityCard.render(diskStats.sample(), size: 240)
        case .topcpu:
            let procs = await Task.detached { TopProcStats.top(3) }.value
            return TopProcCard.render(procs, size: 240)
        case .uptime:
            return UptimeCard.render(size: 240)
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
