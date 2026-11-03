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
    /// Device-native cards on the Deckhand page (CoreBar renders these itself).
    @Published var coreCards: [String] = AppSettings.defaultCoreCards { didSet { save() } }
    /// Whether the Deckhand page has been published (enables the daily cover refresh).
    @Published var deckhandPagePublished: Bool = false { didSet { save() } }
    /// AccuWeather API key for the CoreBar's OWN weather card (stored on the device via 1010).
    @Published var accuWeatherKey: String = "" { didSet { save() } }
    /// VivoCube rotation was running when the app last quit → resume at launch.
    @Published var vivoRotationOn: Bool = false { didSet { save() } }
    /// Layers in the last VivoCube package that the module accepted (for "next" stepping).
    @Published var vivoLayerCount: Int = 1 { didSet { save() } }
    /// How the cube moves between its cards.
    enum SwitchMode: String, Codable, CaseIterable { case stay, timed, button }
    @Published var vivoSwitchMode: SwitchMode = .timed { didSet { save() } }
    /// Image file for the "Picture" card (copied into Application Support).
    @Published var vivoPicturePath: String = "" { didSet { save() } }

    // MARK: Card preferences (2026-11-03)
    /// World clock: three time-zone identifiers, top to bottom.
    @Published var worldClockZones: [String] = ["Europe/Amsterdam", "America/New_York", "Asia/Tokyo"] { didSet { save() } }
    enum ClockStyle: String, Codable, CaseIterable { case analog, digital }
    @Published var clockStyle: ClockStyle = .analog { didSet { save() } }
    @Published var clockSeconds: Bool = false { didSet { save() } }
    enum DateStyle: String, Codable, CaseIterable { case long, short, numeric }
    @Published var dateStyle: DateStyle = .long { didSet { save() } }
    @Published var dateShowWeekday: Bool = true { didSet { save() } }
    @Published var dateShowYear: Bool = true { didSet { save() } }
    /// CoinGecko coin ids for the five crypto cards (empty slot = card shows "choose a coin").
    @Published var cryptoCoins: [String] = ["ethereum", "ripple", "", "", ""] { didSet { save() } }
    @Published var cryptoCurrency: String = "eur" { didSet { save() } }
    /// Calendar identifiers to show; empty = all calendars.
    @Published var calendarIDs: [String] = [] { didSet { save() } }
    enum ClaudePlan: String, Codable, CaseIterable { case pro, max5, max20, api
        var title: String { switch self { case .pro: return "Pro"; case .max5: return "Max 5×"; case .max20: return "Max 20×"; case .api: return "API / Console" } }
    }
    @Published var claudePlan: ClaudePlan = .max5 { didSet { save() } }
    /// Your own daily token budget (for the % on the card); 0 = no percentage.
    @Published var claudeDailyBudget: Int = 0 { didSet { save() } }
    @Published var claudeNotifyWaiting: Bool = true { didSet { save() } }
    /// Experimental: re-select the bar's current page every few minutes so its screen does not time out.
    @Published var keepBarAwake: Bool = false { didSet { save() } }
    static let defaultCoreCards = ["TIME", "WORLD_TIME", "CPU", "MEMORY"]
    /// The 1424-px strip shows about this many cards without scrolling (the clock card is double width).
    static let coreCardsThatFit = 4
    struct CoreCard: Identifiable { let id: String; let title: String; let needsMac: Bool; let icon: String; let note: String }
    static let allCoreCards: [CoreCard] = [
        CoreCard(id: "TIME", title: "Clock", needsMac: false, icon: "clock", note: "The bar's clock card with Deckhand's picture (weather & date, free, updated hourly while Deckhand runs)."),
        CoreCard(id: "WEATHER", title: "Weather (bar's own)", needsMac: false, icon: "cloud.sun", note: "Drawn by the bar from AccuWeather — needs a key (14-day trial, paid afterwards)."),
        CoreCard(id: "WORLD_TIME", title: "World clock", needsMac: false, icon: "globe", note: "The bar's own world-clock card, set to this Mac's time zone."),
        CoreCard(id: "SENSE_TEMP", title: "Temperature", needsMac: false, icon: "thermometer.medium", note: "From the SenseCube."),
        CoreCard(id: "SENSE_HUM", title: "Humidity", needsMac: false, icon: "humidity", note: "From the SenseCube."),
        CoreCard(id: "SENSE_LUX", title: "Light", needsMac: false, icon: "sun.max", note: "From the SenseCube (illuminance in lux)."),
        CoreCard(id: "CPU", title: "Mac CPU", needsMac: true, icon: "cpu", note: ""),
        CoreCard(id: "MEMORY", title: "Mac memory", needsMac: true, icon: "memorychip", note: ""),
        CoreCard(id: "STORAGE", title: "Mac storage", needsMac: true, icon: "internaldrive", note: ""),
        CoreCard(id: "NETWORK", title: "Mac network", needsMac: true, icon: "network", note: ""),
        CoreCard(id: "NEXT_LAYER", title: "Button: next cube card", needsMac: true, icon: "forward.end", note: "Tapping it on the bar tells Deckhand to show the cube's next card."),
        CoreCard(id: "MUSIC", title: "Button: play / pause", needsMac: true, icon: "playpause", note: "Controls Music on this Mac."),
    ]
    static func coreCard(_ id: String) -> CoreCard? { allCoreCards.first { $0.id == id } }

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
        var coreCards: [String]? = nil
        var deckhandPagePublished: Bool? = nil
        var accuWeatherKey: String? = nil
        var vivoRotationOn: Bool? = nil
        var vivoLayerCount: Int? = nil
        var vivoSwitchMode: SwitchMode? = nil
        var vivoPicturePath: String? = nil
        var worldClockZones: [String]? = nil
        var clockStyle: ClockStyle? = nil
        var clockSeconds: Bool? = nil
        var dateStyle: DateStyle? = nil
        var dateShowWeekday: Bool? = nil
        var dateShowYear: Bool? = nil
        var cryptoCoins: [String]? = nil
        var cryptoCurrency: String? = nil
        var calendarIDs: [String]? = nil
        var claudePlan: ClaudePlan? = nil
        var claudeDailyBudget: Int? = nil
        var claudeNotifyWaiting: Bool? = nil
        var keepBarAwake: Bool? = nil
    }

    // MARK: VivoCube cards (ordered, max 6)

    var vivoCards: [Theme] { vivoThemes.compactMap { Theme(rawValue: $0) }.filter { !$0.isHiddenCryptoSlot && !$0.isLiveFeed } }
    /// Coins configured for the Crypto card (non-empty slots, in order).
    var cryptoCoinsConfigured: [String] { cryptoCoins.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    /// The cards actually sent to the cube: the list with "Crypto" expanded to one card per coin (max 6 in total).
    var cubePackageCards: [Theme] {
        var out: [Theme] = []
        let slots: [Theme] = [.crypto, .crypto2, .crypto3, .crypto4, .crypto5]
        for t in vivoCards {
            if t == .crypto { out += slots.prefix(max(1, cryptoCoinsConfigured.count)) } else { out.append(t) }
        }
        return Array(out.prefix(AppModel.maxVivoLayers))
    }
    var vivoSlotsLeft: Int { max(0, AppModel.maxVivoLayers - cubePackageCards.count) }
    /// Human title for a package card ("Crypto: ETH / EUR" for coin slots).
    func cardTitle(_ t: Theme) -> String {
        if let slot = t.cryptoSlot {
            let coins = cryptoCoinsConfigured
            return slot < coins.count ? "Crypto: \(CryptoStats.symbol(for: coins[slot])) / \(cryptoCurrency.uppercased())" : "Crypto"
        }
        return t.title
    }
    func addVivoCard(_ t: Theme) {
        guard !vivoThemes.contains(t.rawValue), vivoSlotsLeft > 0 else { return }
        vivoThemes.append(t.rawValue)
    }
    func removeVivoCard(_ t: Theme) { vivoThemes.removeAll { $0 == t.rawValue } }
    func moveVivoCards(from: IndexSet, to: Int) { var v = vivoThemes; v.move(fromOffsets: from, toOffset: to); vivoThemes = v }

    /// Move a ticked card left/right in the on-screen order.
    func moveCoreCard(_ id: String, by delta: Int) {
        guard let i = coreCards.firstIndex(of: id) else { return }
        let j = i + delta
        guard j >= 0, j < coreCards.count else { return }
        var c = coreCards; c.swapAt(i, j); coreCards = c
    }

    // MARK: Per-device rotation helpers

    func themes(for t: RotationTarget) -> [String] { t == .vivocube ? vivoThemes : coreThemes }
    /// Cards in the order the user arranged them (not enum order).
    func enabledList(for t: RotationTarget) -> [Theme] { themes(for: t).compactMap { Theme(rawValue: $0) } }
    func isEnabled(_ th: Theme, for t: RotationTarget) -> Bool { themes(for: t).contains(th.rawValue) }
    func setEnabled(_ th: Theme, _ on: Bool, for t: RotationTarget) {
        var list = themes(for: t)
        if on { if !list.contains(th.rawValue) { list.append(th.rawValue) } } else { list.removeAll { $0 == th.rawValue } }
        if t == .vivocube { vivoThemes = list } else { coreThemes = list }
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
            coreCards = p.coreCards ?? AppSettings.defaultCoreCards
            deckhandPagePublished = p.deckhandPagePublished ?? false
            accuWeatherKey = p.accuWeatherKey ?? ""
            vivoRotationOn = p.vivoRotationOn ?? false
            vivoLayerCount = p.vivoLayerCount ?? 1
            vivoSwitchMode = p.vivoSwitchMode ?? ((p.vivoRotationOn ?? false) ? .timed : .timed)
            vivoPicturePath = p.vivoPicturePath ?? ""
            worldClockZones = p.worldClockZones ?? worldClockZones
            clockStyle = p.clockStyle ?? .analog
            clockSeconds = p.clockSeconds ?? false
            dateStyle = p.dateStyle ?? .long
            dateShowWeekday = p.dateShowWeekday ?? true
            dateShowYear = p.dateShowYear ?? true
            cryptoCoins = p.cryptoCoins ?? cryptoCoins
            cryptoCurrency = p.cryptoCurrency ?? "eur"
            calendarIDs = p.calendarIDs ?? []
            claudePlan = p.claudePlan ?? .max5
            claudeDailyBudget = p.claudeDailyBudget ?? 0
            claudeNotifyWaiting = p.claudeNotifyWaiting ?? true
            keepBarAwake = p.keepBarAwake ?? false
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
                          coreThemes: coreThemes, coreSeconds: coreSeconds,
                          coreCards: coreCards, deckhandPagePublished: deckhandPagePublished, accuWeatherKey: accuWeatherKey, vivoRotationOn: vivoRotationOn, vivoLayerCount: vivoLayerCount,
                          vivoSwitchMode: vivoSwitchMode, vivoPicturePath: vivoPicturePath,
                          worldClockZones: worldClockZones, clockStyle: clockStyle, clockSeconds: clockSeconds,
                          dateStyle: dateStyle, dateShowWeekday: dateShowWeekday, dateShowYear: dateShowYear,
                          cryptoCoins: cryptoCoins, cryptoCurrency: cryptoCurrency, calendarIDs: calendarIDs,
                          claudePlan: claudePlan, claudeDailyBudget: claudeDailyBudget, claudeNotifyWaiting: claudeNotifyWaiting, keepBarAwake: keepBarAwake)
        if let data = try? JSONEncoder().encode(p) { try? data.write(to: url, options: .atomic) }
    }

    /// This Mac's timezone identifier (e.g. "Europe/Amsterdam").
    var macTimeZone: String { TimeZone.current.identifier }
}
