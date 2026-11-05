import Foundation
import CoreImage
import AppKit

/// Map tiles for the Flights radar. The Mac fetches OpenStreetMap's standard tiles (with a proper
/// User-Agent, as OSM's tile policy asks), tones them down a little so they sit on the dark page without
/// glaring, and caches them on disk, so the bar only ever talks to this Mac and a tile is fetched once.
/// A radar needs about four to nine tiles; they are kept for 30 days. The inverted "dark mode" look of
/// 1.8 was read as a satellite view and went on 2026-11-05: the plain road map is what people expect.
/// CARTO's free dark tiles started answering "API KEY REQUIRED" on 2026-11-04, hence this route.
enum MapTiles {
    static let cacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let d = base.appendingPathComponent("Deckhand/tiles-v3", isDirectory: true)   // bump when the tile filter changes
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    nonisolated static let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    /// The route is open to the LAN while the pages are served: at most this many OSM fetches at a time, so a
    /// client asking for tiles in bulk cannot turn this Mac into a tile proxy or tie up the server's threads.
    nonisolated static let fetchSlots = DispatchSemaphore(value: 4)

    /// The dark PNG for a tile, from cache or fetched now (blocking, up to 8 s). nil when unavailable.
    /// Zoom 2…17 is what the radar asks for (see the page's `map`); anything else is refused.
    nonisolated static func tile(z: Int, x: Int, y: Int) -> Data? {
        guard (2...17).contains(z), x >= 0, y >= 0, x < (1 << z), y < (1 << z) else { return nil }
        let file = cacheDir.appendingPathComponent("\(z)-\(x)-\(y).png")
        var stale: Data?
        if let d = try? Data(contentsOf: file), !d.isEmpty {
            if let mod = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, Date().timeIntervalSince(mod) < 30 * 86400 { return d }
            stale = d   // older than 30 days: try to refresh, but an old map beats no map when OSM is unreachable
        }
        guard let url = URL(string: "https://tile.openstreetmap.org/\(z)/\(x)/\(y).png") else { return nil }
        guard fetchSlots.wait(timeout: .now() + 2) == .success else { return stale }
        defer { fetchSlots.signal() }
        var req = URLRequest(url: url); req.timeoutInterval = 8
        req.setValue("Deckhand/0.2 (+https://denoronha.github.io/UltraWorkspaceMac/)", forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var data: Data? }
        let box = Box()
        URLSession.shared.dataTask(with: req) { d, r, _ in
            if let d, (r as? HTTPURLResponse)?.statusCode == 200 { box.data = d }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 9)
        guard let raw = box.data, let dark = darken(raw) else { return stale }
        try? dark.write(to: file)
        return dark
    }

    /// The standard road map, slightly dimmed and desaturated so it does not glare on the dark page at night.
    nonisolated static func darken(_ png: Data) -> Data? {
        guard let img = CIImage(data: png) else { return nil }
        var out = img
        if let f = CIFilter(name: "CIColorControls") {
            f.setValue(out, forKey: kCIInputImageKey); f.setValue(0.8, forKey: kCIInputSaturationKey); f.setValue(-0.08, forKey: kCIInputBrightnessKey); f.setValue(1.0, forKey: kCIInputContrastKey)
            out = f.outputImage ?? out
        }
        guard let cg = ciContext.createCGImage(out, from: out.extent) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:])
    }
}
