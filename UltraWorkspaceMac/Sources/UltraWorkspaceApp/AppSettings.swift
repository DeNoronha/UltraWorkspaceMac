import Foundation
import CoreLocation

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

    // VivoCube cards + switching interval.
    @Published var vivoThemes: [String] = [Theme.weather.rawValue] { didSet { save() } }
    @Published var vivoSeconds: Int = 30 { didSet { save() } }
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
    /// Serve the live Monitor page for the bar's Monitor app (LAN, read-only Mac stats).
    @Published var monitorServe: Bool = false { didSet { save() } }
    /// Serve the pages only to the paired bar (and this Mac): any other host on the LAN gets 403. Off by default
    /// so the pages can be previewed in a browser on another machine (SECURITY.md, path 2).
    @Published var pagesOnlyForBar: Bool = false { didSet { save() } }
    /// Presence-aware bar screen over ADB: on while the SenseCube sees someone, off after `presenceSleepMinutes`.
    @Published var presenceWake: Bool = false { didSet { save() } }
    @Published var presenceSleepMinutes: Int = 10 { didSet { save() } }
    // Bar apps (2026-11-04): Flights radius, Headlines source. The Linear key lives in Store (user-only file).
    @Published var flightsRadiusKm: Int = 3 { didSet { save() } }
    @Published var newsSource: String = "cnn" { didSet { save() } }
    static let defaultCoreCards = ["TIME", "WORLD_TIME", "CPU", "MEMORY"]
    /// The 1424-px strip shows this many single cards without scrolling (the clock card takes two slots) — counted on the bar 2026-11-04.
    static let coreCardsThatFit = 5
    struct CoreCard: Identifiable {
        let id: String; let title: String; let needsMac: Bool; let icon: String; let note: String
        /// The bar's own icon for an app card (from its app list); nil for Deckhand's fixed cards.
        var imageURL: URL? = nil
    }
    static let allCoreCards: [CoreCard] = [
        CoreCard(id: "TIME", title: "Clock", needsMac: false, icon: "clock", note: "The bar's clock card with Deckhand's picture (weather & date, free, updated hourly while Deckhand runs)."),
        CoreCard(id: "WEATHER", title: "Weather (bar's own)", needsMac: false, icon: "cloud.sun", note: "Drawn by the bar from AccuWeather — needs a key (14-day trial, paid afterwards)."),
        CoreCard(id: "WORLD_TIME", title: "World clock", needsMac: false, icon: "globe", note: "The bar's own world-clock card, set to this Mac's time zone."),
        CoreCard(id: "SENSE_TEMP", title: "Temperature", needsMac: false, icon: "thermometer.medium", note: "From the SenseCube."),
        CoreCard(id: "SENSE_HUM", title: "Humidity", needsMac: false, icon: "humidity", note: "From the SenseCube."),
        CoreCard(id: "SENSE_LUX", title: "Light", needsMac: false, icon: "sun.max", note: "From the SenseCube (illuminance in lux)."),
        CoreCard(id: "SENSE_PRESENCE", title: "Presence", needsMac: false, icon: "person.wave.2", note: "From the SenseCube's radar — only the bar can show it; the Mac cannot read it."),
        CoreCard(id: "SENSE_SOUND", title: "Sound level", needsMac: false, icon: "waveform", note: "From the SenseCube's microphone (dB) — only the bar can show it; the Mac cannot read it."),
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
        // Retired (CoreBar-screen rotation, 2026-11-03); kept so old settings.json still decodes.
        var coreThemes: [String]? = nil
        var coreSeconds: Int? = nil
        var coreCards: [String]? = nil
        var deckhandPagePublished: Bool? = nil
        var accuWeatherKey: String? = nil
        var vivoRotationOn: Bool? = nil
        var vivoLayerCount: Int? = nil
        var vivoSwitchMode: SwitchMode? = nil
        var vivoPicturePath: String? = nil
        // Retired cube cards (world clock / clock, 2026-11-03); kept so old settings.json still decodes.
        var worldClockZones: [String]? = nil
        var clockStyle: String? = nil
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
        var monitorServe: Bool? = nil
        var pagesOnlyForBar: Bool? = nil
        var presenceWake: Bool? = nil
        var presenceSleepMinutes: Int? = nil
        var flightsRadiusKm: Int? = nil
        var newsSource: String? = nil
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

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("UltraWorkspaceMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("settings.json")
        var loaded: Persisted?
        if let data = try? Data(contentsOf: url) {
            do { loaded = try JSONDecoder().decode(Persisted.self, from: data) }
            // A settings file that no longer decodes would be silently replaced by defaults on the next save:
            // at least say so in the log.
            catch { NSLog("Deckhand: settings.json could not be read, using defaults: \(error)") }
        }
        if let p = loaded {
            locationMode = p.locationMode
            manualCity = p.manualCity
            manualLat = p.manualLat
            manualLon = p.manualLon
            units = p.units
            clock24h = p.clock24h
            // Prefer the new per-device fields; fall back to the legacy single list.
            vivoThemes = p.vivoThemes ?? p.enabledThemes ?? [Theme.weather.rawValue]
            vivoSeconds = p.vivoSeconds ?? p.rotateSeconds ?? 30
            coreCards = p.coreCards ?? AppSettings.defaultCoreCards
            deckhandPagePublished = p.deckhandPagePublished ?? false
            accuWeatherKey = p.accuWeatherKey ?? ""
            vivoRotationOn = p.vivoRotationOn ?? false
            vivoLayerCount = p.vivoLayerCount ?? 1
            vivoSwitchMode = p.vivoSwitchMode ?? .timed
            vivoPicturePath = p.vivoPicturePath ?? ""
            dateStyle = p.dateStyle ?? .long
            dateShowWeekday = p.dateShowWeekday ?? true
            dateShowYear = p.dateShowYear ?? true
            cryptoCoins = p.cryptoCoins ?? cryptoCoins
            cryptoCurrency = p.cryptoCurrency ?? "eur"
            calendarIDs = p.calendarIDs ?? []
            claudePlan = p.claudePlan ?? .max5
            claudeDailyBudget = p.claudeDailyBudget ?? 0
            claudeNotifyWaiting = p.claudeNotifyWaiting ?? true
            monitorServe = p.monitorServe ?? false
            pagesOnlyForBar = p.pagesOnlyForBar ?? false
            presenceWake = p.presenceWake ?? false
            presenceSleepMinutes = p.presenceSleepMinutes ?? 10
            flightsRadiusKm = p.flightsRadiusKm ?? 3
            newsSource = p.newsSource ?? "cnn"
        }
    }

    func save() {
        let p = Persisted(locationMode: locationMode, manualCity: manualCity,
                          manualLat: manualLat, manualLon: manualLon,
                          units: units, clock24h: clock24h,
                          enabledThemes: nil, rotateSeconds: nil,
                          vivoThemes: vivoThemes, vivoSeconds: vivoSeconds,
                          coreCards: coreCards, deckhandPagePublished: deckhandPagePublished, accuWeatherKey: accuWeatherKey, vivoRotationOn: vivoRotationOn, vivoLayerCount: vivoLayerCount,
                          vivoSwitchMode: vivoSwitchMode, vivoPicturePath: vivoPicturePath,
                          dateStyle: dateStyle, dateShowWeekday: dateShowWeekday, dateShowYear: dateShowYear,
                          cryptoCoins: cryptoCoins, cryptoCurrency: cryptoCurrency, calendarIDs: calendarIDs,
                          claudePlan: claudePlan, claudeDailyBudget: claudeDailyBudget, claudeNotifyWaiting: claudeNotifyWaiting, monitorServe: monitorServe, pagesOnlyForBar: pagesOnlyForBar, presenceWake: presenceWake, presenceSleepMinutes: presenceSleepMinutes,
                          flightsRadiusKm: flightsRadiusKm, newsSource: newsSource)
        do {
            try JSONEncoder().encode(p).write(to: url, options: .atomic)
            // Holds the AccuWeather key and the manual location: user-only, like the token files.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { NSLog("Deckhand: settings.json could not be saved: \(error)") }
    }

    /// This Mac's timezone identifier (e.g. "Europe/Amsterdam").
    var macTimeZone: String { TimeZone.current.identifier }
}
