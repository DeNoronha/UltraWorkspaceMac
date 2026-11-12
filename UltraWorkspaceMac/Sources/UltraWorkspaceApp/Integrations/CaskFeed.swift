import Foundation
import UltraBarKit

/// One bottle in the user's whisky collection, as kept in `cask.json`. `whiskyId` is a Whiskystats Whisky ID:
/// "WB<Whiskybase id>" or "BG<bottle group id>". The purchase price is per bottle, in euros.
struct CaskBottle: Codable, Equatable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    var whiskyId: String
    var name: String
    var quantity: Int = 1
    var price: Double?
    /// Purchase date, "YYYY-MM-DD".
    var bought: String?

    init(whiskyId: String, name: String, quantity: Int = 1, price: Double? = nil, bought: String? = nil) {
        self.whiskyId = whiskyId; self.name = name; self.quantity = quantity; self.price = price; self.bought = bought
    }
    /// Hand-edited files may leave out anything but the Whisky ID.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        whiskyId = try c.decode(String.self, forKey: .whiskyId)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? whiskyId
        quantity = max(1, try c.decodeIfPresent(Int.self, forKey: .quantity) ?? 1)
        price = try c.decodeIfPresent(Double.self, forKey: .price)
        bought = try c.decodeIfPresent(String.self, forKey: .bought)
    }
}

/// The Whiskystats Data API (data.api.whiskystats.com), the few calls Cask needs. Every call but the credit
/// balance costs credits (Whiskystats' rate card, checked live 2026-11-12): search 1, bottle details 1, auction
/// listings 7, auction pricing 10. Prices are buyer prices (hammer plus fees), global market, in euros.
enum WhiskyStats {
    static let base = "https://data.api.whiskystats.com/v01"
    enum Cost { static let search = 1, pricing = 10, lots = 7 }

    struct Credits: Codable, Equatable, Sendable { var usage: Int; var limit: Int; var cycle: String?; var at: Date }
    struct Hit: Sendable, Identifiable { var id: String { whiskyId }; let whiskyId: String; let name: String; let group: String? }
    struct Point: Codable, Equatable, Sendable { var d: String; var v: Double }
    struct Pricing: Codable, Equatable, Sendable {
        var whiskyId: String
        var marketValue: Double?
        var marketValueDate: String?
        var totalTrades: Int?
        var latestDate: String?, latestAvg: Double?, latestMin: Double?, latestMax: Double?, latestTrades: Int?
        var maxDate: String?, maxPrice: Double?
        var y12Change: Double?, y12Min: Double?, y12Max: Double?, y12Avg: Double?, y12Trades: Int?
        /// Market value on every day it changed, newest first (as the API gives it).
        var history: [Point]
    }
    struct Lot: Codable, Equatable, Sendable { var house: String; var auction: String; var end: String?; var lot: String?; var market: String? }

    enum Failure: LocalizedError {
        case key, notFound, rateLimited, http(Int), budget(String), paced(String)
        var errorDescription: String? {
            switch self {
            case .key: return "Whiskystats refused the key."
            case .notFound: return "Whiskystats does not know this Whisky ID."
            case .rateLimited: return "Whiskystats: too many requests, trying later."
            case .http(let c): return "Whiskystats answered HTTP \(c)."
            case .budget(let s), .paced(let s): return s
            }
        }
    }

    /// One GET with the key as a bearer token. The key never goes into the URL, a log or an error message.
    static func get(_ path: String, _ query: [String: String], key: String) async throws -> Any {
        var comps = URLComponents(string: base + path)!
        comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: comps.url!, timeoutInterval: 25)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: return try JSONSerialization.jsonObject(with: data)
        case 401, 403: throw Failure.key
        case 404: throw Failure.notFound
        case 429: throw Failure.rateLimited
        default: throw Failure.http(code)
        }
    }

    /// Free.
    static func credits(key: String) async throws -> Credits {
        let o = try await get("/utilities/credit_balance", [:], key: key) as? [String: Any] ?? [:]
        return Credits(usage: num(o["credit_usage"]).map(Int.init) ?? 0, limit: num(o["credit_limit"]).map(Int.init) ?? 0, cycle: o["credit_cycle"] as? String, at: Date())
    }

    /// 1 credit per call. A Whisky ID as the query finds that bottle (Whiskystats' search accepts them).
    static func search(_ q: String, key: String) async throws -> [Hit] {
        let o = try await get("/whisky/bottle_search", ["query": q, "page": "1"], key: key) as? [String: Any] ?? [:]
        return ((o["results"] as? [[String: Any]]) ?? []).compactMap { r in
            guard let id = r["whisky_id"] as? String, let n = r["whisky_name"] as? String else { return nil }
            return Hit(whiskyId: id, name: n, group: r["parent_bottle_group_id"] as? String)
        }
    }

    /// 10 credits. With the bottle group fallback a single bottling without trades of its own gets its group's.
    static func pricing(_ id: String, key: String) async throws -> Pricing {
        let o = try await get("/whisky/auction_pricing", ["whisky_id": id, "currency_code": "EUR", "bottle_group_fallback": "true"], key: key) as? [String: Any] ?? [:]
        let l = o["latest_auction_price"] as? [String: Any] ?? [:], m = o["max_auction_price"] as? [String: Any] ?? [:], y = o["latest_12m"] as? [String: Any] ?? [:]
        let hist = ((o["market_value_history"] as? [[String: Any]]) ?? []).compactMap { h -> Point? in
            guard let d = h["date"] as? String, let v = num(h["market_value"]) else { return nil }
            return Point(d: d, v: v)
        }
        return Pricing(whiskyId: o["whisky_id"] as? String ?? id, marketValue: num(o["market_value"]), marketValueDate: o["market_value_date"] as? String,
                       totalTrades: num(o["total_trades"]).map(Int.init),
                       latestDate: l["price_date"] as? String, latestAvg: num(l["buyer_price_avg"]), latestMin: num(l["buyer_price_min"]),
                       latestMax: num(l["buyer_price_max"]), latestTrades: num(l["number_of_trades"]).map(Int.init),
                       maxDate: m["price_date"] as? String, maxPrice: num(m["buyer_price"]),
                       y12Change: num(y["market_value_change_pct"]), y12Min: num(y["buyer_price_min"]), y12Max: num(y["buyer_price_max"]),
                       y12Avg: num(y["buyer_price_avg"]), y12Trades: num(y["number_of_trades"]).map(Int.init), history: hist)
    }

    /// 7 credits. Lots on offer now (no prices: the API has no per-lot hammer prices).
    static func lots(_ id: String, key: String) async throws -> [Lot] {
        let o = try await get("/whisky/auction_listings", ["whisky_id": id, "bottle_group_fallback": "true"], key: key) as? [String: Any] ?? [:]
        return ((o["listings"] as? [[String: Any]]) ?? []).map { r in
            Lot(house: (r["auction_house"] as? String) ?? "", auction: ((r["auction"] as? String) ?? "").trimmingCharacters(in: .whitespaces),
                end: r["auction_end_date"] as? String, lot: r["lot_number"] as? String, market: r["price_market_code"] as? String)
        }
    }

    static func num(_ a: Any?) -> Double? { (a as? NSNumber)?.doubleValue }

    /// "WB51469", "51469", "BG1390" or a Whiskybase / Whiskystats URL → a Whisky ID; nil for anything else.
    static func whiskyID(from text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: "^(WB|BG)?[0-9]{1,8}$", options: [.regularExpression, .caseInsensitive]), r == t.startIndex..<t.endIndex {
            let u = t.uppercased(); return u.hasPrefix("WB") || u.hasPrefix("BG") ? u : "WB" + u
        }
        for pattern in ["whiskybase\\.com/whiskies/whisky/([0-9]+)", "whiskystats\\.com/whisky/([0-9]+)"] {
            if let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), let r = Range(m.range(at: 1), in: t) { return "WB" + t[r] }
        }
        return nil
    }
}

/// The Cask bar app's data: the user's bottles (`cask.json`), their auction prices from Whiskystats, and the
/// credit budget. Whiskystats sells data by the credit (a membership has a fixed number a month, e.g. 500) and
/// auction prices are the expensive call, so everything is cached on disk (`cask-cache.json`) and spent by rule:
///
/// - The credit balance (free) is read before every paid call. Nothing is spent that would leave fewer than
///   `reserve` credits in the cycle, whoever asks.
/// - Scheduled refreshes also keep to a pace through the cycle (spent ≤ the cycle's share so far plus a quarter),
///   one bottle at a time, at most one refresh every 15 minutes, only while Cask is on the bar.
/// - Each Whisky ID is refreshed every `refreshDays` (at least 7; longer when the collection is large, so the
///   refreshes of a month fit in 85 % of the budget). Market values are 90-day averages and auctions monthly,
///   so a week old is current.
/// - A failure waits 6 hours (an unknown Whisky ID a week) before it is tried again; that survives a restart.
@MainActor
final class CaskFeed: ObservableObject {
    struct Entry: Codable, Equatable {
        var pricing: WhiskyStats.Pricing?
        var pricedAt: Date?
        var lots: [WhiskyStats.Lot]?
        var lotsAt: Date?
        var error: String?
        var retryAt: Date?
    }
    struct Cache: Codable { var entries: [String: Entry] = [:]; var credits: WhiskyStats.Credits?; var lastSpend: Date?; var lots: Bool? }

    /// Credits never spent, for the website and anything else on the same key.
    nonisolated static let reserve = 100
    nonisolated static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("UltraWorkspaceMac", isDirectory: true)
    }
    nonisolated static var bottlesURL: URL { folder.appendingPathComponent("cask.json") }
    nonisolated static var cacheURL: URL { folder.appendingPathComponent("cask-cache.json") }

    nonisolated static func loadBottles() -> (bottles: [CaskBottle], error: String?) {
        guard let data = try? Data(contentsOf: bottlesURL) else { return ([], nil) }
        struct File: Codable { var bottles: [CaskBottle] }
        do { return (try JSONDecoder().decode(File.self, from: data).bottles, nil) }
        catch { return ([], "cask.json: \(error.localizedDescription)") }
    }
    /// User-only, like the key files: what someone owns is nobody else's business.
    nonisolated static func writePrivate(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    @Published private(set) var bottles: [CaskBottle] = []
    @Published private(set) var fileError: String?
    @Published private(set) var cache = Cache()
    @Published private(set) var lastError: String?
    /// Why a scheduled refresh is waiting (pacing); shown in Deckhand, not on the bar.
    @Published private(set) var note: String?
    /// The Whisky ID being fetched right now.
    @Published private(set) var busy: String?
    private var fileStamp: Date?
    private var loop: Task<Void, Never>?
    private var key: () -> String = { "" }
    private var snapshotMemo: (stamp: String, body: [String: Any])?

    init() {
        if let d = try? Data(contentsOf: Self.cacheURL) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
            if let c = try? dec.decode(Cache.self, from: d) { cache = c }
        }
        reloadBottles()
    }

    /// Fetch the lots on offer at auction too (7 credits per bottle per refresh).
    var lotsOn: Bool { cache.lots ?? true }
    func setLots(_ on: Bool) { cache.lots = on; saveCache() }

    func reloadBottles() {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: Self.bottlesURL.path))?[.modificationDate] as? Date
        let l = Self.loadBottles()
        bottles = l.bottles; fileError = l.error; fileStamp = stamp; snapshotMemo = nil
    }

    func saveBottles(_ next: [CaskBottle]) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        struct File: Codable { var bottles: [CaskBottle] }
        try Self.writePrivate(enc.encode(File(bottles: next)), to: Self.bottlesURL)
        reloadBottles()
        // Drop what no bottle needs any more, so the cache follows the list.
        let ids = Set(next.map(\.whiskyId))
        if cache.entries.keys.contains(where: { !ids.contains($0) }) { cache.entries = cache.entries.filter { ids.contains($0.key) }; saveCache() }
    }

    private func saveCache() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        if let d = try? enc.encode(cache) { try? Self.writePrivate(d, to: Self.cacheURL) }
        snapshotMemo = nil
    }

    // MARK: budget

    /// Days between two refreshes of one Whisky ID: weekly, or longer when a month of weekly refreshes for the whole
    /// collection would not fit in 85 % of what may be spent.
    func refreshDays() -> Int {
        let n = Set(bottles.map(\.whiskyId)).count
        let limit = cache.credits?.limit ?? 500
        let usable = Double(max(1, limit - Self.reserve)) * 0.85
        let perRefresh = Double(WhiskyStats.Cost.pricing + (lotsOn ? WhiskyStats.Cost.lots : 0))
        return max(7, Int((30 * Double(n) * perRefresh / usable).rounded(.up)))
    }

    /// The cycle's share of the usable credits so far, plus a quarter: scheduled refreshes stay under it.
    func pacedAllowance(_ c: WhiskyStats.Credits) -> Int {
        let usable = Double(max(0, c.limit - Self.reserve))
        guard let s = c.cycle, let end = Self.day.date(from: s), let start = Calendar.current.date(byAdding: .month, value: -1, to: end) else { return Int(usable) }
        let f = min(1, max(0, Date().timeIntervalSince(start) / end.timeIntervalSince(start)))
        return Int(usable * min(1, f + 0.25))
    }

    /// Reads the balance (free) and refuses a call that would break the reserve or, for a scheduled one, the pace.
    private func checkBudget(_ cost: Int, scheduled: Bool, key: String) async throws {
        let c = try await WhiskyStats.credits(key: key)
        cache.credits = c
        if c.usage + cost > c.limit - Self.reserve {
            throw WhiskyStats.Failure.budget("Stopped: \(c.limit - c.usage) of \(c.limit) credits left, \(Self.reserve) are kept free. Prices refresh again after \(c.cycle.map(Self.shortDate) ?? "the cycle ends").")
        }
        if scheduled, c.usage + cost > pacedAllowance(c) {
            throw WhiskyStats.Failure.paced("\(c.usage) credits used so far this cycle: the next refresh waits a little, to spread them over the month.")
        }
    }

    // MARK: fetching

    func start(key: @escaping @MainActor () -> String, wanted: @escaping @MainActor () -> Bool) {
        self.key = key
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self else { return }
                // A hand edit of cask.json is picked up within a minute.
                let stamp = (try? FileManager.default.attributesOfItem(atPath: Self.bottlesURL.path))?[.modificationDate] as? Date
                if stamp != self.fileStamp { self.reloadBottles() }
                let k = key().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !k.isEmpty, wanted(), self.busy == nil else { continue }
                if let last = self.cache.lastSpend, Date().timeIntervalSince(last) < 15 * 60 { continue }
                guard let id = self.nextDue() else { continue }
                await self.refresh(id, key: k, scheduled: true)
            }
        }
    }

    func stop() { loop?.cancel(); loop = nil }

    /// The Whisky ID most overdue for a refresh: never priced first, then the oldest; nil when all are fresh.
    func nextDue() -> String? {
        let now = Date(), every = TimeInterval(refreshDays()) * 86400
        var best: (String, Date)?
        for id in Set(bottles.map(\.whiskyId)) {
            let e = cache.entries[id]
            if let r = e?.retryAt, r > now { continue }
            let due = e?.pricedAt.map { $0.addingTimeInterval(every) } ?? .distantPast
            if due <= now, best.map({ due < $0.1 }) ?? true { best = (id, due) }
        }
        return best?.0
    }

    /// Prices for a bottle that was just added, or "Refresh now": the user asked, so no pacing, but the reserve holds.
    func refreshNow(_ id: String) {
        let k = key().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty, busy == nil else { return }
        Task { await refresh(id, key: k, scheduled: false) }
    }

    private func refresh(_ id: String, key: String, scheduled: Bool) async {
        busy = id
        defer { busy = nil; saveCache() }
        var e = cache.entries[id] ?? Entry()
        do {
            try await checkBudget(WhiskyStats.Cost.pricing, scheduled: scheduled, key: key)
            cache.lastSpend = Date()
            let p = try await WhiskyStats.pricing(id, key: key)
            e.pricing = p; e.pricedAt = Date(); e.error = nil; e.retryAt = nil
            cache.entries[id] = e
            WireLog.shared.event("cask: prices for \(id)\(p.whiskyId != id ? " (group \(p.whiskyId))" : "")")
            if lotsOn {
                try await checkBudget(WhiskyStats.Cost.lots, scheduled: scheduled, key: key)
                e.lots = try await WhiskyStats.lots(id, key: key); e.lotsAt = Date()
                cache.entries[id] = e
            }
            cache.credits = try? await WhiskyStats.credits(key: key)
            lastError = nil; note = nil
        } catch WhiskyStats.Failure.budget(let s) {
            lastError = s   // not the bottle's fault: no retry mark, the scheduler simply finds it due again later
        } catch WhiskyStats.Failure.paced(let s) {
            note = s
        } catch {
            let notFound = (error as? WhiskyStats.Failure).map { if case .notFound = $0 { return true } else { return false } } ?? false
            e.error = error.localizedDescription
            e.retryAt = Date().addingTimeInterval(notFound ? 7 * 86400 : 6 * 3600)
            cache.entries[id] = e
            lastError = "\(id): \(error.localizedDescription)"
            WireLog.shared.event("cask: \(id) failed: \(error.localizedDescription)")
        }
    }

    /// A search from the editor (1 credit), under the same reserve.
    func search(_ q: String) async throws -> [WhiskyStats.Hit] {
        let k = key().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { throw WhiskyStats.Failure.key }
        try await checkBudget(WhiskyStats.Cost.search, scheduled: false, key: k)
        defer { saveCache() }
        let hits = try await WhiskyStats.search(q, key: k)
        cache.credits = try? await WhiskyStats.credits(key: k)
        return hits
    }

    /// The balance only (free), for the settings page.
    func checkCredits() async {
        let k = key().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        do { cache.credits = try await WhiskyStats.credits(key: k); saveCache(); if lastError == WhiskyStats.Failure.key.errorDescription { lastError = nil } }
        catch { lastError = error.localizedDescription }
    }

    // MARK: what the bar gets

    nonisolated static let day: DateFormatter = {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"; return f
    }()
    nonisolated static func shortDate(_ s: String) -> String {
        guard let d = day.date(from: s) else { return s }
        let f = DateFormatter()
        let sameYear = Calendar.current.component(.year, from: d) == Calendar.current.component(.year, from: Date())
        f.setLocalizedDateFormatFromTemplate(sameYear ? "d MMM" : "d MMM yyyy")
        return f.string(from: d)
    }

    /// The market value on a day: the history holds the value on each day it changed, newest first.
    nonisolated static func value(on date: String, _ hist: [WhiskyStats.Point]) -> Double? { hist.first { $0.d <= date }?.v }

    /// About 48 points over the last two years (or since the first trade), for a sparkline.
    nonisolated static func spark(_ hist: [WhiskyStats.Point], months: Int = 24, points: Int = 48) -> (from: Date, values: [Double]) {
        let now = Date()
        guard let oldest = hist.last.flatMap({ day.date(from: $0.d) }) else { return (now, []) }
        let from = max(oldest, Calendar.current.date(byAdding: .month, value: -months, to: now)!)
        let step = now.timeIntervalSince(from) / Double(points - 1)
        guard step > 0 else { return (from, hist.first.map { [$0.v, $0.v] } ?? []) }
        return (from, (0..<points).compactMap { i in value(on: day.string(from: from.addingTimeInterval(Double(i) * step)), hist) })
    }

    func snapshot(hasKey: Bool) -> [String: Any] {
        let today = Self.day.string(from: Date())
        let stamp = "\(hasKey)|\(today)|\(busy ?? "")|\(lastError ?? "")"
        if let m = snapshotMemo, m.stamp == stamp { return m.body }
        let monthAgo = Self.day.string(from: Calendar.current.date(byAdding: .day, value: -30, to: Date())!)
        var total = 0.0, then = 0.0, cost = 0.0, costValue = 0.0, priced = 0
        var rows: [(Double, [String: Any])] = []
        for b in bottles {
            let e = cache.entries[b.whiskyId], p = e?.pricing
            let q = Double(b.quantity)
            var row: [String: Any] = ["id": b.id, "name": b.name, "qty": b.quantity, "wid": b.whiskyId]
            if let pr = b.price { row["buy"] = pr }
            if let s = b.bought { row["bought"] = Self.shortDate(s) }
            if let err = e?.error { row["err"] = err }
            let mv = p?.marketValue ?? p?.latestAvg
            if let p, let mv {
                priced += 1
                total += mv * q
                let old = Self.value(on: monthAgo, p.history) ?? mv
                then += old * q
                if let pr = b.price { cost += pr * q; costValue += mv * q; row["vsBuy"] = pr > 0 ? (mv - pr) / pr : 0 }
                row["value"] = mv; row["sub"] = mv * q
                row["d30"] = old > 0 ? (mv - old) / old : 0
                let sp = Self.spark(p.history)
                row["spark"] = sp.values.map { ($0 * 100).rounded() / 100 }
                row["sparkFrom"] = Self.shortDate(Self.day.string(from: sp.from))
                if let d = p.latestDate { row["last"] = ["date": Self.shortDate(d), "avg": p.latestAvg ?? 0, "min": p.latestMin ?? 0, "max": p.latestMax ?? 0, "n": p.latestTrades ?? 0] as [String: Any] }
                if let m = p.maxPrice, let d = p.maxDate { row["high"] = ["date": Self.shortDate(d), "p": m] as [String: Any] }
                if let n = p.y12Trades, n > 0 { row["y12"] = ["min": p.y12Min ?? 0, "max": p.y12Max ?? 0, "avg": p.y12Avg ?? 0, "n": n, "chg": p.y12Change ?? 0] as [String: Any] }
                row["trades"] = p.totalTrades ?? 0
                if p.whiskyId != b.whiskyId { row["group"] = p.whiskyId }
                if let at = e?.pricedAt { row["age"] = Int(Date().timeIntervalSince(at) / 86400) }
            } else {
                row["pending"] = busy == b.whiskyId ? "fetching prices…" : (e?.error ?? (hasKey ? "waiting for prices" : ""))
            }
            if let lots = e?.lots {
                let upcoming = lots.filter { ($0.end ?? today) >= today }.sorted { ($0.end ?? "") < ($1.end ?? "") }
                row["lots"] = upcoming.prefix(4).map { l -> [String: Any] in ["house": l.house, "auction": l.auction, "end": l.end.map(Self.shortDate) ?? "", "lot": l.lot ?? ""] }
                row["nLots"] = upcoming.count
            }
            rows.append(((row["sub"] as? Double) ?? -1, row))
        }
        var out: [String: Any] = ["hasKey": hasKey, "currency": "EUR", "locale": Locale.current.identifier(.bcp47),
                                  "bottles": rows.sorted { $0.0 > $1.0 }.map(\.1), "n": bottles.reduce(0) { $0 + $1.quantity },
                                  "priced": priced, "total": total, "d30": then > 0 ? (total - then) / then : 0,
                                  "at": Int(Date().timeIntervalSince1970), "every": refreshDays()]
        if cost > 0 { out["cost"] = cost; out["costValue"] = costValue; out["vsBuy"] = (costValue - cost) / cost }
        if let c = cache.credits { out["credits"] = ["used": c.usage, "limit": c.limit, "left": max(0, c.limit - c.usage), "cycle": c.cycle.map(Self.shortDate) ?? ""] as [String: Any] }
        if let e = fileError ?? lastError { out["error"] = e }
        snapshotMemo = (stamp, out)
        return out
    }
}
