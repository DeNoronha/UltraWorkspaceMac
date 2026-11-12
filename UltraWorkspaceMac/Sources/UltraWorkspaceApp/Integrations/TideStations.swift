import Foundation

/// A Rijkswaterstaat water-level gauge for the Tide bar app. `code` is the location code of the WaterWebservices
/// ("hoekvanholland", "nijmegen.waal"); `tide` says whether Rijkswaterstaat publishes an astronomical tide for it
/// (high and low waters), which a river gauge such as Nijmegen does not have.
struct TideStation: Codable, Equatable, Hashable, Sendable, Identifiable {
    var code: String
    var name: String
    var tide: Bool
    var id: String { code }
}

/// The gauges the Tide app shows and the catalogue to pick them from.
///
/// The choice is kept in `tide.json` next to `haven.json` in Deckhand's Application Support folder
/// (`{"stations":[TideStation…]}`) and goes to the bar in the config document (`apps.tide.stations`); the bar fetches
/// the levels itself. The catalogue comes from Rijkswaterstaat's open WaterWebservices (DD-API 2.0, no key):
/// `OphalenCatalogus` for every location with a measured water level (WATHTE, cm NAP) and which of them have an
/// astronomical tide, and one `OphalenLaatsteWaarnemingen` call to keep only the gauges that reported in the last two
/// days (the catalogue also lists gauges closed decades ago). Cached for a day in Caches; only fetched when the
/// station picker is opened.
enum TideStations {
    nonisolated static let base = "https://ddapi20-waterwebservices.rijkswaterstaat.nl"
    nonisolated static let maxStations = 4
    nonisolated static let defaults = [
        TideStation(code: "hoekvanholland", name: "Hoek van Holland", tide: true),
        TideStation(code: "rotterdam.nieuwemaas.boerengat", name: "Rotterdam, Nieuwe Maas, Boerengat", tide: true),
        TideStation(code: "nijmegen.waal", name: "Nijmegen, Waal", tide: false),
    ]

    private struct File: Codable { var stations: [TideStation] }

    nonisolated static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UltraWorkspaceMac", isDirectory: true).appendingPathComponent("tide.json")
    }
    /// The chosen gauges (at most four), or the defaults without a file or with an unreadable one.
    nonisolated static func load() -> [TideStation] {
        guard let data = try? Data(contentsOf: fileURL), let f = try? JSONDecoder().decode(File.self, from: data) else { return defaults }
        let valid = f.stations.filter { $0.code.range(of: "^[a-z0-9._-]{2,80}$", options: .regularExpression) != nil }
        return valid.isEmpty ? defaults : Array(valid.prefix(maxStations))
    }
    /// Writes the choice from Apps → Tide; the config feed sends it to the bar within 10 s.
    nonisolated static func save(_ stations: [TideStation]) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(File(stations: Array(stations.prefix(maxStations)))).write(to: fileURL, options: .atomic)
    }
    /// The `apps.tide` section of the bar config.
    nonisolated static func configSection() -> [String: Any] {
        ["stations": load().map { ["code": $0.code, "name": $0.name, "tide": $0.tide] as [String: Any] }]
    }

    // MARK: catalogue

    /// One gauge in the picker, with its last reading.
    struct Entry: Codable, Identifiable, Sendable {
        var code: String, name: String, tide: Bool
        var level: Int?, at: Date?
        var id: String { code }
        var station: TideStation { TideStation(code: code, name: name, tide: tide) }
    }

    nonisolated private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UltraWorkspaceMac", isDirectory: true).appendingPathComponent("tide-stations.json")
    }

    /// Every gauge that reported a water level in the last two days, by name: from the cache when it is less than a
    /// day old, else from Rijkswaterstaat (two requests, a few MB). A failed refresh falls back to an older cache.
    nonisolated static func catalogue() async throws -> [Entry] {
        struct Cache: Codable { var at: Date; var entries: [Entry] }
        let cached = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode(Cache.self, from: $0) }
        if let c = cached, Date().timeIntervalSince(c.at) < 86_400, !c.entries.isEmpty { return c.entries }
        do {
            let fresh = try await fetchCatalogue()
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(Cache(at: Date(), entries: fresh)).write(to: cacheURL, options: .atomic)
            return fresh
        } catch {
            if let c = cached, !c.entries.isEmpty { return c.entries }
            throw error
        }
    }

    private nonisolated static func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: base + path)!, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let o = try JSONSerialization.jsonObject(with: data) as? [String: Any], o["Succesvol"] as? Bool == true else {
            throw NSError(domain: "Tide", code: code, userInfo: [NSLocalizedDescriptionKey: "Rijkswaterstaat answered HTTP \(code)"])
        }
        return o
    }

    private nonisolated static func fetchCatalogue() async throws -> [Entry] {
        let cat = try await post("/METADATASERVICES/OphalenCatalogus", ["CatalogusFilter": ["Grootheden": true, "Hoedanigheden": true, "Groeperingen": true, "ProcesTypes": true, "Compartimenten": true]])
        func code(_ o: Any?) -> String { ((o as? [String: Any])?["Code"] as? String) ?? "" }
        // Which metadata ids are "measured water level in cm NAP" and "astronomical high and low waters".
        var measured = Set<Int>(), extremes = Set<Int>()
        for m in cat["AquoMetadataLijst"] as? [[String: Any]] ?? [] {
            guard let id = m["AquoMetadata_MessageID"] as? Int, code(m["Grootheid"]) == "WATHTE", code(m["Hoedanigheid"]) == "NAP", code(m["Compartiment"]) == "OW" else { continue }
            let proces = m["ProcesType"] as? String ?? "", groep = code(m["Groepering"])
            if proces == "meting", groep.isEmpty { measured.insert(id) }
            if proces == "astronomisch", groep == "GETETBRKD2" { extremes.insert(id) }
        }
        var hasLevel = Set<Int>(), hasTide = Set<Int>()
        for x in cat["AquoMetadataLocatieLijst"] as? [[String: Any]] ?? [] {
            guard let m = x["AquoMetaData_MessageID"] as? Int, let l = x["Locatie_MessageID"] as? Int else { continue }
            if measured.contains(m) { hasLevel.insert(l) }
            if extremes.contains(m) { hasTide.insert(l) }
        }
        var byCode: [String: Entry] = [:]
        for l in cat["LocatieLijst"] as? [[String: Any]] ?? [] {
            guard let id = l["Locatie_MessageID"] as? Int, hasLevel.contains(id), let c = l["Code"] as? String, !c.isEmpty else { continue }
            let name = (l["Naam"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? c
            byCode[c] = Entry(code: c, name: name, tide: hasTide.contains(id) || (byCode[c]?.tide ?? false))
        }
        // The last reading of each; gauges without one in the last two days are left out.
        let latest = try await post("/ONLINEWAARNEMINGENSERVICES/OphalenLaatsteWaarnemingen", [
            "LocatieLijst": byCode.keys.sorted().map { ["Code": $0] },
            "AquoPlusWaarnemingMetadataLijst": [["AquoMetadata": ["Compartiment": ["Code": "OW"], "Grootheid": ["Code": "WATHTE"], "Hoedanigheid": ["Code": "NAP"], "ProcesType": "meting"]]],
        ])
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let cutoff = Date().addingTimeInterval(-2 * 86_400)
        for w in latest["WaarnemingenLijst"] as? [[String: Any]] ?? [] {
            let c = code(w["Locatie"])
            guard var e = byCode[c] else { continue }
            for m in w["MetingenLijst"] as? [[String: Any]] ?? [] {
                guard let t = (m["Tijdstip"] as? String).flatMap(iso.date(from:)), t > cutoff, t > (e.at ?? .distantPast),
                      let v = (m["Meetwaarde"] as? [String: Any])?["Waarde_Numeriek"] as? Double, abs(v) < 5000 else { continue }
                e.level = Int(v.rounded()); e.at = t
            }
            byCode[c] = e
        }
        return byCode.values.filter { $0.at != nil }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
