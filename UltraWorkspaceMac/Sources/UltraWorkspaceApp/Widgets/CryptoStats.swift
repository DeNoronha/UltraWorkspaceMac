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

    /// Today's prices from CoinGecko `market_chart?days=1` (5-minute points), cut at local midnight.
    static func today(id: String, currency: String) async -> CoinDay? {
        let cid = id.trimmingCharacters(in: .whitespaces).lowercased()
        guard !cid.isEmpty, let url = URL(string: "https://api.coingecko.com/api/v3/coins/\(cid)/market_chart?vs_currency=\(currency.lowercased())&days=1") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prices = obj["prices"] as? [[Any]] else { return nil }
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
        var c = URLComponents(string: "https://api.coingecko.com/api/v3/simple/price")!
        c.queryItems = [
            .init(name: "ids", value: ids.joined(separator: ",")),
            .init(name: "vs_currencies", value: currency.lowercased()),
            .init(name: "include_24hr_change", value: "true"),
        ]
        guard let url = c.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

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
