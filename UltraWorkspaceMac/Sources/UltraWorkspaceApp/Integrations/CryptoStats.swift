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

    /// Map a CoinGecko id to a short ticker symbol.
    static func symbol(for id: String) -> String {
        switch id.lowercased() {
        case "bitcoin": return "BTC"
        case "ethereum": return "ETH"
        case "solana": return "SOL"
        case "cardano": return "ADA"
        default: return String(id.uppercased().prefix(4))
        }
    }

    /// Currency code → display suffix (symbol).
    static func suffix(for currency: String) -> String {
        switch currency.lowercased() {
        case "eur": return "€"
        case "usd": return "$"
        case "gbp": return "£"
        default: return currency.uppercased()
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
