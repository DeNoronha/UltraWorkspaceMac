import Foundation
import CoreLocation

/// Which display device a rotation is configured for. Each device keeps its own
/// set of enabled widgets and its own interval (a VivoCube is 240×240, the
/// CoreBar screen is 1424×280, so they don't share a widget selection).
enum RotationTarget: String, Codable, CaseIterable, Sendable { case vivocube, corebar }

/// App-wide preferences, persisted to Application Support. These feed the
/// weather feature (location + units) and the per-device widget rotations.
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

    // Per-device widget rotations.
    @Published var vivoThemes: [String] = [Theme.weather.rawValue] { didSet { save() } }
    @Published var vivoSeconds: Int = 30 { didSet { save() } }
    @Published var coreThemes: [String] = [] { didSet { save() } }
    @Published var coreSeconds: Int = 30 { didSet { save() } }

    private let url: URL

    private struct Persisted: Codable {
        var locationMode: LocationMode = .auto
        var manualCity = ""
        var manualLat = ""
        var manualLon = ""
        var units: Units = .metric
        var clock24h = true
        // Legacy single list (pre per-device). Migrated into vivoThemes on load.
        var enabledThemes: [String]? = nil
        var rotateSeconds: Int? = nil
        var vivoThemes: [String]? = nil
        var vivoSeconds: Int? = nil
        var coreThemes: [String]? = nil
        var coreSeconds: Int? = nil
    }

    // MARK: Per-device rotation helpers

    func themes(for t: RotationTarget) -> [String] { t == .vivocube ? vivoThemes : coreThemes }
    func enabledList(for t: RotationTarget) -> [Theme] {
        let raw = themes(for: t)
        return Theme.allCases.filter { raw.contains($0.rawValue) }
    }
    func isEnabled(_ th: Theme, for t: RotationTarget) -> Bool { themes(for: t).contains(th.rawValue) }
    func setEnabled(_ th: Theme, _ on: Bool, for t: RotationTarget) {
        var set = Set(themes(for: t))
        if on { set.insert(th.rawValue) } else { set.remove(th.rawValue) }
        let ordered = Theme.allCases.map(\.rawValue).filter { set.contains($0) }
        if t == .vivocube { vivoThemes = ordered } else { coreThemes = ordered }
    }
    func seconds(for t: RotationTarget) -> Int { t == .vivocube ? vivoSeconds : coreSeconds }

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
            // Prefer the new per-device fields; fall back to the legacy single list.
            vivoThemes = p.vivoThemes ?? p.enabledThemes ?? [Theme.weather.rawValue]
            vivoSeconds = p.vivoSeconds ?? p.rotateSeconds ?? 30
            coreThemes = p.coreThemes ?? []
            coreSeconds = p.coreSeconds ?? 30
        }
    }

    private var saving = false
    func save() {
        guard !saving else { return }
        let p = Persisted(locationMode: locationMode, manualCity: manualCity,
                          manualLat: manualLat, manualLon: manualLon,
                          units: units, clock24h: clock24h,
                          enabledThemes: nil, rotateSeconds: nil,
                          vivoThemes: vivoThemes, vivoSeconds: vivoSeconds,
                          coreThemes: coreThemes, coreSeconds: coreSeconds)
        if let data = try? JSONEncoder().encode(p) { try? data.write(to: url, options: .atomic) }
    }

    /// This Mac's timezone identifier (e.g. "Europe/Amsterdam").
    var macTimeZone: String { TimeZone.current.identifier }
}
