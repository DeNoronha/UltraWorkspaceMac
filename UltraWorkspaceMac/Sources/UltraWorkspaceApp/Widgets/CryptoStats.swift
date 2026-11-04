import Foundation

/// Minimal CoinGecko client (no API key). Spot price + 24h change for a set of coins.
/// Self-contained in the app target; the fetch mirrors OpenMeteo's URLSession +
/// JSONSerialization style with defensive parsing and a Sendable result.
enum CryptoStats {
    struct Coin: Sendable {
        var symbol: String
        var price: Double
        var change24h: Double  // percent
    }

    /// Coins offered in the picker: (CoinGecko id, ticker, name). Any other id can be typed.
    static let knownCoins: [(id: String, symbol: String, name: String)] = [
        ("bitcoin", "BTC", "Bitcoin"), ("ethereum", "ETH", "Ethereum"), ("ripple", "XRP", "XRP"),
        ("solana", "SOL", "Solana"), ("cardano", "ADA", "Cardano"), ("dogecoin", "DOGE", "Dogecoin"),
        ("litecoin", "LTC", "Litecoin"), ("polkadot", "DOT", "Polkadot"), ("chainlink", "LINK", "Chainlink"),
        ("binancecoin", "BNB", "BNB"), ("tron", "TRX", "TRON"), ("avalanche-2", "AVAX", "Avalanche"),
        ("stellar", "XLM", "Stellar"), ("monero", "XMR", "Monero"), ("polygon-ecosystem-token", "POL", "Polygon"),
    ]
    static let currencies = ["eur", "usd", "gbp", "chf", "jpy", "btc"]

    /// Map a CoinGecko id to a short ticker symbol.
    static func symbol(for id: String) -> String {
        if let k = knownCoins.first(where: { $0.id == id.lowercased() }) { return k.symbol }
        return String(id.uppercased().prefix(5))
    }

    /// One coin's day: price points since midnight (local), plus derived numbers.
    struct CoinDay: Sendable {
        var points: [Double]
        var open: Double
        var low: Double
        var high: Double
        var current: Double
    }

    // CoinGecko's keyless API allows only a handful of calls a minute per address and answers a burst with
    // `{"status":{"error_code":429}}` inside an HTTP 200 (seen 2026-11-04: the second coin of two drew "no data").
    // So every call goes through one gate: results are cached, callers for the same coin share one request,
    // requests are spaced 1.5 s apart, a 429 is retried once after 10 s, and on failure the last good answer is
    // returned even when stale.
    actor Gate {
        static let shared = Gate()
        private var days: [String: (CoinDay, Date)] = [:]
        private var prices: [String: ([Coin], Date)] = [:]
        private var inflight: [String: Task<CoinDay?, Never>] = [:]
        private var lastRequest = Date.distantPast

        /// Wait so that calls are at least 1.5 s apart, then fetch; retry once on a 429. Returns the raw body.
        func get(_ url: URL) async -> Data? {
            for attempt in 0..<2 {
                let gap = 1.5 - Date().timeIntervalSince(lastRequest)
                if gap > 0 { try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000)) }
                lastRequest = Date()
                guard let (data, resp) = try? await URLSession.shared.data(from: url) else { return nil }
                let http = (resp as? HTTPURLResponse)?.statusCode ?? 200
                let limited = http == 429 || (String(decoding: data.prefix(80), as: UTF8.self).contains("\"error_code\":429"))
                if limited { if attempt == 0 { try? await Task.sleep(nanoseconds: 10_000_000_000) }; continue }
                return data
            }
            return nil
        }

        func day(id: String, currency: String, maxAge: TimeInterval, fetch: @escaping @Sendable () async -> CoinDay?) async -> CoinDay? {
            let key = "\(id)/\(currency)"
            if let (d, at) = days[key], Date().timeIntervalSince(at) < maxAge { return d }
            if let t = inflight[key] { return await t.value }
            let t = Task { await fetch() }
            inflight[key] = t
            let result = await t.value
            inflight[key] = nil
            if let result { days[key] = (result, Date()); return result }
            return days[key]?.0   // stale beats "no data"
        }

        func prices(key: String, maxAge: TimeInterval, fetch: @escaping @Sendable () async -> [Coin]) async -> [Coin] {
            if let (c, at) = prices[key], Date().timeIntervalSince(at) < maxAge { return c }
            let result = await fetch()
            if !result.isEmpty { prices[key] = (result, Date()); return result }
            return prices[key]?.0 ?? []
        }
    }

    /// Today's prices from CoinGecko `market_chart?days=1` (5-minute points), cut at local midnight.
    /// Cached for two minutes; see `Gate`.
    static func today(id: String, currency: String) async -> CoinDay? {
        let cid = id.trimmingCharacters(in: .whitespaces).lowercased(), cur = currency.lowercased()
        guard !cid.isEmpty else { return nil }
        return await Gate.shared.day(id: cid, currency: cur, maxAge: 120) { await fetchToday(cid: cid, currency: cur) }
    }

    private static func fetchToday(cid: String, currency: String) async -> CoinDay? {
        guard let url = URL(string: "https://api.coingecko.com/api/v3/coins/\(cid)/market_chart?vs_currency=\(currency)&days=1") else { return nil }
        guard let data = await Gate.shared.get(url), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let prices = obj["prices"] as? [[Any]] else { return nil }
        let midnight = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000
        var pts: [Double] = []
        var lastBefore: Double?
        for p in prices where p.count >= 2 {
            guard let t = (p[0] as? NSNumber)?.doubleValue, let v = (p[1] as? NSNumber)?.doubleValue else { continue }
            if t < midnight { lastBefore = v } else { pts.append(v) }
        }
        if pts.isEmpty, let lb = lastBefore { pts = [lb] }
        guard let cur = pts.last else { return nil }
        let open = lastBefore ?? pts.first ?? cur
        return CoinDay(points: pts, open: open, low: pts.min() ?? cur, high: pts.max() ?? cur, current: cur)
    }

    /// Currency code → display suffix (symbol).
    static func suffix(for currency: String) -> String {
        switch currency.lowercased() {
        case "eur": return "€"
        case "usd": return "$"
        case "gbp": return "£"
        case "chf": return "CHF "
        case "jpy": return "¥"
        case "btc": return "₿"
        default: return currency.uppercased() + ""
        }
    }

    /// Fetch current prices from CoinGecko's free, keyless simple/price endpoint.
    /// Returns [] on any failure. Order follows `ids`.
    static func fetch(ids: [String] = ["bitcoin", "ethereum"], currency: String = "eur") async -> [Coin] {
        guard !ids.isEmpty else { return [] }
        return await Gate.shared.prices(key: ids.joined(separator: ",") + "/" + currency.lowercased(), maxAge: 90) { await fetchPrices(ids: ids, currency: currency) }
    }

    private static func fetchPrices(ids: [String], currency: String) async -> [Coin] {
        var c = URLComponents(string: "https://api.coingecko.com/api/v3/simple/price")!
        c.queryItems = [
            .init(name: "ids", value: ids.joined(separator: ",")),
            .init(name: "vs_currencies", value: currency.lowercased()),
            .init(name: "include_24hr_change", value: "true"),
        ]
        guard let url = c.url, let data = await Gate.shared.get(url), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        let cur = currency.lowercased()
        func dbl(_ d: [String: Any], _ k: String) -> Double? {
            (d[k] as? Double) ?? (d[k] as? NSNumber)?.doubleValue
        }

        var coins: [Coin] = []
        for id in ids {
            guard let entry = obj[id.lowercased()] as? [String: Any],
                  let price = dbl(entry, cur) else { continue }
            let change = dbl(entry, "\(cur)_24h_change") ?? 0
            coins.append(Coin(symbol: symbol(for: id), price: price, change24h: change))
        }
        return coins
    }
}
