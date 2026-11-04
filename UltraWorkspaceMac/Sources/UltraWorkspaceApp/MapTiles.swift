import Foundation
import CoreImage
import AppKit

/// Map tiles for the Flights radar. The Mac fetches OpenStreetMap's standard tiles (with a proper
/// User-Agent, as OSM's tile policy asks), turns them into a dark style (invert + hue-rotate + dim, the
/// usual "dark mode" filter) and caches them on disk, so the bar only ever talks to this Mac and a tile is
/// fetched once. A radar needs about four to nine tiles; they are kept for 30 days.
/// CARTO's free dark tiles started answering "API KEY REQUIRED" on 2026-11-04, hence this route.
enum MapTiles {
    static let cacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let d = base.appendingPathComponent("Deckhand/tiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    nonisolated static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// The dark PNG for a tile, from cache or fetched now (blocking, up to 8 s). nil when unavailable.
    nonisolated static func tile(z: Int, x: Int, y: Int) -> Data? {
        guard (0...19).contains(z), x >= 0, y >= 0, x < (1 << z), y < (1 << z) else { return nil }
        let file = cacheDir.appendingPathComponent("\(z)-\(x)-\(y).png")
        if let d = try? Data(contentsOf: file), !d.isEmpty,
           let mod = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, Date().timeIntervalSince(mod) < 30 * 86400 { return d }
        guard let url = URL(string: "https://tile.openstreetmap.org/\(z)/\(x)/\(y).png") else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 8
        req.setValue("Deckhand/1.3 (+https://denoronha.github.io/UltraWorkspaceMac/)", forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var data: Data? }
        let box = Box()
        URLSession.shared.dataTask(with: req) { d, r, _ in
            if let d, (r as? HTTPURLResponse)?.statusCode == 200 { box.data = d }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 9)
        guard let raw = box.data, let dark = darken(raw) else { return nil }
        try? dark.write(to: file)
        return dark
    }

    /// invert → hue-rotate 180° (so water stays blue-ish) → dim and desaturate a little.
    nonisolated static func darken(_ png: Data) -> Data? {
        guard let img = CIImage(data: png) else { return nil }
        var out = img
        if let f = CIFilter(name: "CIColorInvert") { f.setValue(out, forKey: kCIInputImageKey); out = f.outputImage ?? out }
        if let f = CIFilter(name: "CIHueAdjust") { f.setValue(out, forKey: kCIInputImageKey); f.setValue(Float.pi, forKey: kCIInputAngleKey); out = f.outputImage ?? out }
        if let f = CIFilter(name: "CIColorControls") {
            f.setValue(out, forKey: kCIInputImageKey); f.setValue(0.3, forKey: kCIInputSaturationKey); f.setValue(-0.12, forKey: kCIInputBrightnessKey); f.setValue(1.05, forKey: kCIInputContrastKey)
            out = f.outputImage ?? out
        }
        guard let cg = ciContext.createCGImage(out, from: out.extent) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:])
    }
}
