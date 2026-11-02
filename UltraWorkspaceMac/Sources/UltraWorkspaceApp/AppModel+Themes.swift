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

    /// Start (or restart) the VivoCube widget carousel.
    ///
    /// Model (mirrors the official client): render every ticked widget into its
    /// own layer, upload ONE package, wait for the module to apply it, then
    /// rotate by writing property 9 (layer|widget) — no flash rewrite per step.
    /// Contents are re-rendered and re-uploaded only every `refreshEvery`.
    func startThemeRotation(settings: AppSettings) {
        themeTask?.cancel(); themeTask = nil
        var themes = settings.enabledList(for: .vivocube)
        guard let bar = selectedCoreBar, let session = session(for: bar), let serial = vivoCubeSerial else {
            say("Pair a CoreBar with a VivoCube first."); themeRunning = false; return
        }
        guard !themes.isEmpty else { say("Tick at least one widget for the VivoCube."); themeRunning = false; return }
        if themes.count > Self.maxVivoLayers {
            say("A VivoCube holds \(Self.maxVivoLayers) layers — using the first \(Self.maxVivoLayers) ticked widgets.")
            themes = Array(themes.prefix(Self.maxVivoLayers))
        }
        themeRunning = true
        settings.vivoRotationOn = true
        themeIndex = 0
        let interval = max(10, settings.vivoSeconds)
        let refreshEvery = TimeInterval(max(300, interval * themes.count)) // re-render + re-upload cadence
        let list = themes

        themeTask = Task {
            defer { self.themeRunning = false }
            // 1. One package with all layers.
            self.say(list.count == 1 ? "Rendering \(list[0].title) for the VivoCube…"
                                     : "Rendering \(list.count) widgets into one VivoCube package…")
            guard await self.uploadPackage(list, settings: settings, session: session, serial: serial) else { return }
            if Task.isCancelled { return }
            self.say("Package accepted — waiting \(Self.vivoSettleSeconds)s for the VivoCube to apply it…")
            try? await Task.sleep(nanoseconds: Self.vivoSettleSeconds * 1_000_000_000)
            if Task.isCancelled { return }

            // 2. Point the module at layer 1 (clears any stale cached layer/widget).
            self.currentThemeLabel = list[0].title
            _ = await session.setLayer(serial: serial, layer: 1, widget: Self.widgetId(forLayer: 1))
            if list.count == 1 {
                self.say("\(list[0].title) is on the VivoCube. ✓ (Publish again to refresh its contents.)")
                return
            }
            self.say("Rotating \(list.map(\.title).joined(separator: ", ")) · every \(interval)s · contents refresh every \(Int(refreshEvery / 60)) min")

            // 3. Rotate via property 9; refresh contents occasionally.
            var lastRefresh = Date()
            var step = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                if Task.isCancelled { break }
                if Date().timeIntervalSince(lastRefresh) >= refreshEvery {
                    self.say("Refreshing widget contents on the VivoCube…")
                    if await self.uploadPackage(list, settings: settings, session: session, serial: serial) {
                        lastRefresh = Date()
                        try? await Task.sleep(nanoseconds: Self.vivoSettleSeconds * 1_000_000_000)
                    }
                    if Task.isCancelled { break }
                }
                step += 1
                let layer = (step % list.count) + 1
                self.themeIndex = layer - 1
                self.currentThemeLabel = list[layer - 1].title
                let code = await session.setLayer(serial: serial, layer: layer, widget: Self.widgetId(forLayer: layer))
                if code != 200 { self.say("Layer switch to \(list[layer - 1].title) not acknowledged (code \(code.map(String.init) ?? "nil")).") }
            }
        }
    }

    /// Render `themes` into layers 1…n (widget 100+n) and upload a single package.
    private func uploadPackage(_ themes: [Theme], settings: AppSettings, session: CoreBarSession, serial: String) async -> Bool {
        var layers: [DeployPackager.Layer] = []
        var names: [String] = []
        var previews: [Int: NSImage] = [:]
        for (i, t) in themes.enumerated() {
            guard let rgba = await renderTheme(t, settings: settings) else {
                say("\(t.title): could not render — skipped."); continue
            }
            names.append(t.title)
            if let png = Self.pngData(fromRGBA: rgba, width: 240, height: 240), let img = NSImage(data: png) { previews[i + 1] = img }
            let bin = DeviceImage.encode(width: 240, height: 240, rgba: rgba)
            layers.append(.init(layerId: i + 1, widgetId: Self.widgetId(forLayer: i + 1), defaultBin: bin, pressedBin: bin))
        }
        guard !layers.isEmpty else { say("Nothing to publish."); return false }
        let tgz = DeployPackager.buildTgz(layers: layers, defaultLayer: 1)
        do {
            _ = try await session.upload(serial: serial, tgz: tgz)
            lastPublishedVivoLayers = layers.count
            settings.vivoLayerCount = layers.count
            vivoLayerNames = names
            vivoLayerImages = previews
            vivoLayerIndex = 0
            return true
        } catch {
            say("VivoCube upload failed: \(error.localizedDescription)")
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
            let was = before.map { "was layer \($0.layer) / widget \($0.widget)" } ?? "cached state unknown"
            self.say(ok ? "VivoCube display recovered (\(was) → layer 1 / widget 101, screen on)."
                        : "Recover sent, but the CoreBar did not acknowledge both writes (\(was)).")
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
        say("Display stopped.")
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
        }
    }
}
