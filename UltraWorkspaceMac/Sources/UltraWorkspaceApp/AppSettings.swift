import Foundation
import CoreLocation

/// App-wide preferences, persisted to Application Support. These feed the
/// weather feature (location + units) and display preferences.
@MainActor
final class AppSettings: ObservableObject {
    enum LocationMode: String, Codable, CaseIterable { case auto, manual }
    enum Units: String, Codable, CaseIterable { case metric, imperial }

    @Published var locationMode: LocationMode = .auto { didSet { save() } }
    @Published var manualCity: String = "" { didSet { save() } }
    @Published var manualLat: String = "" { didSet { save() } }
    @Published var manualLon: String = "" { didSet { save() } }
    @Published var units: Units = .metric { didSet { save() } }
    @Published var clock24h: Bool = true { didSet { save() } }

    // Display themes (VivoCube carousel)
    @Published var enabledThemes: [String] = [Theme.weather.rawValue] { didSet { save() } }
    @Published var rotateSeconds: Int = 30 { didSet { save() } }

    private let url: URL

    private struct Persisted: Codable {
        var locationMode: LocationMode = .auto
        var manualCity = ""
        var manualLat = ""
        var manualLon = ""
        var units: Units = .metric
        var clock24h = true
        var enabledThemes: [String] = [Theme.weather.rawValue]
        var rotateSeconds: Int = 30
    }

    /// Enabled themes in the canonical display order.
    var enabledThemeList: [Theme] {
        Theme.allCases.filter { enabledThemes.contains($0.rawValue) }
    }
    func isThemeEnabled(_ t: Theme) -> Bool { enabledThemes.contains(t.rawValue) }
    func setTheme(_ t: Theme, _ on: Bool) {
        var set = Set(enabledThemes)
        if on { set.insert(t.rawValue) } else { set.remove(t.rawValue) }
        enabledThemes = Theme.allCases.map(\.rawValue).filter { set.contains($0) }
    }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("UltraWorkspaceMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: url),
           let p = try? JSONDecoder().decode(Persisted.self, from: data) {
            locationMode = p.locationMode
            manualCity = p.manualCity
            manualLat = p.manualLat
            manualLon = p.manualLon
            units = p.units
            clock24h = p.clock24h
            enabledThemes = p.enabledThemes
            rotateSeconds = p.rotateSeconds
        }
    }

    private var saving = false
    func save() {
        guard !saving else { return }
        let p = Persisted(locationMode: locationMode, manualCity: manualCity,
                          manualLat: manualLat, manualLon: manualLon,
                          units: units, clock24h: clock24h,
                          enabledThemes: enabledThemes, rotateSeconds: rotateSeconds)
        if let data = try? JSONEncoder().encode(p) { try? data.write(to: url, options: .atomic) }
    }

    /// This Mac's timezone identifier (e.g. "Europe/Amsterdam").
    var macTimeZone: String { TimeZone.current.identifier }
}
