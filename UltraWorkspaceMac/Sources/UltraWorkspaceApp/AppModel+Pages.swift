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

    /// Render the square cover we put on the clock card.
    func renderPageCover(settings: AppSettings) async -> Data? {
        let now = try? await resolveWeather(settings: settings, metric: settings.units == .metric)
        guard let rgba = WeatherCard.render(width: 480, height: 480, now: now, clock24h: settings.clock24h) else { return nil }
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
                let lat = settings.manualLat.replacingOccurrences(of: ",", with: ".")
                let lon = settings.manualLon.replacingOccurrences(of: ",", with: ".")
                let standard: [String: Any] = [
                    "id": Self.defaultPageId, "name": "Standard Mode", "isDefault": true, "showName": true, "iconScale": 100,
                    "icon": "http://cdn.lifex360.com/ultrabar/desktop/default.png",
                    "module": [],
                    "widget": [
                        ["id": "sys.component.time", "type": "TIME", "name": "Time", "icon": ""],
                        ["id": "sys.component.weather", "type": "WEATHER", "name": "Weather", "param": ["lat": lat, "lon": lon]],
                    ],
                ]
                let deckhand: [String: Any] = [
                    "id": Self.deckhandPageId, "name": "Deckhand", "isDefault": false, "showName": true, "iconScale": 100,
                    "icon": "deckhand/cover.png",
                    "module": [],
                    "widget": [
                        ["id": "sys.component.time", "type": "TIME", "name": "Deckhand", "icon": "deckhand/cover.png"],
                    ],
                ]
                let reply = try await session.savePages([standard, deckhand])
                self.say("Pages written (\(reply.prefix(80))). Switching to the Deckhand page…")
                _ = try await session.switchPage(id: Self.deckhandPageId)
                self.currentPageId = Self.deckhandPageId
                self.say("CoreBar is showing the Deckhand page. ✓ Look at the clock card.")
                self.refreshPages()
            } catch { self.say("Page publish failed: \(error.localizedDescription)") }
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
