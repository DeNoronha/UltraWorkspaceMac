import Foundation
import UltraBarKit

/// The Portfolio bar app's data: what is in the user's Kraken account, what it is worth and how that moved, held on
/// this Mac so the API key never reaches the bar; the app asks for `/portfolio/data.json`.
///
///  - Balances: `POST /0/private/Balance` with the user's own key, which needs only the **Query Funds** permission
///    (Deckhand never asks for more and never trades or withdraws). Every 5 minutes. Earn/staking balances ("ETH2.S",
///    "DOT.S") count as the coin itself (`KrakenPortfolio.normalize`).
///  - Prices and market statistics: the public `Ticker` for each coin's pair in the chosen currency (last, bid, ask,
///    24h high/low, VWAP, volume, number of trades, today's open), every 30 seconds.
///  - History: the public `OHLC` candles per coin (15 min for a day, 1 h for a week, 4 h for a month, 1 day for a
///    year), each refreshed at a pace that fits its interval. The portfolio's line is today's amounts times those
///    closes (`KrakenPortfolio.combine`): how today's holdings would have moved, not past trades.
///
/// Public calls go one at a time, a second apart (Kraken's public limit is about one a second). Nothing runs while
/// the app is not on the bar and nobody asked in the last ten minutes. Kept in memory only.
@MainActor
final class KrakenFeed: ObservableObject {
    @Published var apiKey: String = Store.shared.loadSecret(name: "kraken-key") ?? "" {
        didSet { Store.shared.saveSecret(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), name: "kraken-key", debounce: true); balanceAt = .distantPast; wake.signal() }
    }
    @Published var apiSecret: String = Store.shared.loadSecret(name: "kraken-secret") ?? "" {
        didSet { Store.shared.saveSecret(apiSecret.trimmingCharacters(in: .whitespacesAndNewlines), name: "kraken-secret", debounce: true); balanceAt = .distantPast; wake.signal() }
    }
    @Published private(set) var lastError: String?
    @Published private(set) var updatedAt: Date?
    /// Coins found, for the settings ("ETH, XRP and 10 more").
    @Published private(set) var coinCount = 0

    var hasKey: Bool { !apiKey.trimmingCharacters(in: .whitespaces).isEmpty && !apiSecret.trimmingCharacters(in: .whitespaces).isEmpty }

    private var currency: () -> String = { "EUR" }
    private var minValue: () -> Double = { 10 }
    private var balances: [String: (amount: Double, earn: Double)] = [:]
    private var balanceAt = Date.distantPast
    private var altnames: [String: String] = [:]
    /// "ETH/EUR" → Kraken's pair key ("XETHZEUR"), from AssetPairs (refreshed daily).
    private var pairs: [String: String] = [:]
    private var pairsAt = Date.distantPast
    private var tickers: [String: [String: Any]] = [:]      // symbol → ticker
    private var tickerAt = Date.distantPast
    private var candles: [String: [String: [(t: Int, close: Double)]]] = [:]   // period → symbol → closes
    private var candleAt: [String: [String: Date]] = [:]
    private var lastCurrency = ""
    private var nonce: Int64 = 0
    private var loop: Task<Void, Never>?
    private let wake = WakeSignal()

    /// Period → (OHLC interval in minutes, how many candles, refresh after).
    nonisolated static let periods: [(id: String, interval: Int, count: Int, every: TimeInterval)] = [
        ("1D", 15, 97, 300), ("1W", 60, 169, 900), ("1M", 240, 181, 3600), ("1Y", 1440, 366, 6 * 3600)]

    func start(currency: @escaping @MainActor () -> String, minValue: @escaping @MainActor () -> Double, wanted: @escaping @MainActor () -> Bool) {
        self.currency = currency; self.minValue = minValue
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if currency() != self.lastCurrency {
                    self.lastCurrency = currency(); self.tickers = [:]; self.candles = [:]; self.candleAt = [:]; self.tickerAt = .distantPast
                }
                if self.hasKey, wanted() { await self.refresh() }
                await self.wake.wait(self.hasKey && wanted() ? 30 : 600) { currency() != self.lastCurrency }
            }
        }
    }
    func stop() { loop?.cancel(); loop = nil }
    func poke() { wake.signal() }
    func refreshNow() { balanceAt = .distantPast; tickerAt = .distantPast; candleAt = [:]; wake.signal() }

    // MARK: refresh

    private func refresh() async {
        let cur = currency()
        do {
            if Date().timeIntervalSince(pairsAt) > 86400 || pairs.isEmpty { try await loadPairs() }
            if Date().timeIntervalSince(balanceAt) >= 300 { try await loadBalances() }
            let syms = pricedSymbols(cur)
            if Date().timeIntervalSince(tickerAt) >= 25, !syms.isEmpty { try await loadTickers(syms, cur) }
            // Candles only for the coins that are shown (worth at least the minimum), oldest-refreshed first.
            for p in Self.periods {
                for s in shownSymbols(cur) where Date().timeIntervalSince(candleAt[p.id]?[s] ?? .distantPast) >= p.every {
                    guard let key = pairs["\(KrakenPortfolio.kraken(s))/\(cur)"] else { continue }
                    try await Task.sleep(nanoseconds: 1_100_000_000)
                    let since = Int(Date().timeIntervalSince1970) - p.interval * 60 * p.count
                    let j = try await publicCall("OHLC", ["pair": key, "interval": String(p.interval), "since": String(since)])
                    let rows = (j.first { $0.key != "last" }?.value as? [[Any]]) ?? []
                    let closes = rows.compactMap { r -> (Int, Double)? in
                        guard r.count > 4, let t = (r[0] as? NSNumber)?.intValue, let c = Double("\(r[4])") else { return nil }
                        return (t, c)
                    }.suffix(p.count)
                    candles[p.id, default: [:]][s] = Array(closes).map { (t: $0.0, close: $0.1) }
                    candleAt[p.id, default: [:]][s] = Date()
                }
            }
            lastError = nil; updatedAt = Date()
        } catch let e as KrakenError {
            lastError = e.message
        } catch {
            lastError = "Kraken: \(error.localizedDescription)"
        }
    }

    private struct KrakenError: Error { let message: String }

    private func loadPairs() async throws {
        let j = try await publicCall("AssetPairs", [:])
        var map: [String: String] = [:]
        for (key, v) in j { if let d = v as? [String: Any], let ws = d["wsname"] as? String, d["status"] as? String ?? "online" == "online" { map[ws] = key } }
        let a = try await publicCall("Assets", [:])
        altnames = a.compactMapValues { ($0 as? [String: Any])?["altname"] as? String }
        pairs = map; pairsAt = Date()
    }

    private func loadBalances() async throws {
        let j = try await privateCall("Balance")
        var out: [String: (amount: Double, earn: Double)] = [:]
        for (k, v) in j {
            guard let amount = Double("\(v)"), amount > 0 else { continue }
            let n = KrakenPortfolio.normalize(k, altnames: altnames)
            var e = out[n.symbol] ?? (0, 0)
            e.amount += amount; if n.earn { e.earn += amount }
            out[n.symbol] = e
        }
        balances = out; balanceAt = Date(); coinCount = out.keys.filter { !KrakenPortfolio.fiat.contains($0) }.count
    }

    private func loadTickers(_ syms: [String], _ cur: String) async throws {
        let keys = syms.compactMap { pairs["\(KrakenPortfolio.kraken($0))/\(cur)"] }
        guard !keys.isEmpty else { return }
        let j = try await publicCall("Ticker", ["pair": keys.joined(separator: ",")])
        let back = Dictionary(uniqueKeysWithValues: syms.compactMap { s in pairs["\(KrakenPortfolio.kraken(s))/\(cur)"].map { ($0, s) } })
        for (k, v) in j { if let s = back[k], let d = v as? [String: Any] { tickers[s] = d } }
        tickerAt = Date()
    }

    /// Coins (and other currencies) that have a pair in `cur`.
    private func pricedSymbols(_ cur: String) -> [String] {
        balances.keys.filter { $0 != cur && pairs["\(KrakenPortfolio.kraken($0))/\(cur)"] != nil }.sorted()
    }
    private func price(_ s: String) -> Double? { (tickers[s]?["c"] as? [Any])?.first.flatMap { Double("\($0)") } }
    private func value(_ s: String, _ cur: String) -> Double? { s == cur ? balances[s]?.amount : price(s).map { $0 * (balances[s]?.amount ?? 0) } }
    private func shownSymbols(_ cur: String) -> [String] {
        pricedSymbols(cur).filter { !KrakenPortfolio.fiat.contains($0) && (value($0, cur) ?? 0) >= minValue() }
            .sorted { (value($0, cur) ?? 0) > (value($1, cur) ?? 0) }.prefix(8).map { $0 }
    }

    // MARK: calls

    private func publicCall(_ method: String, _ params: [String: String]) async throws -> [String: Any] {
        var c = URLComponents(string: "https://api.kraken.com/0/public/\(method)")!
        if !params.isEmpty { c.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) } }
        let (data, resp) = try await URLSession.shared.data(for: URLRequest(url: c.url!, timeoutInterval: 20))
        return try Self.result(data, resp)
    }

    private func privateCall(_ method: String) async throws -> [String: Any] {
        let path = "/0/private/\(method)"
        nonce = max(nonce + 1, Int64(Date().timeIntervalSince1970 * 1000))
        let post = "nonce=\(nonce)"
        guard let sign = KrakenSign.sign(path: path, nonce: String(nonce), postData: post, secretBase64: apiSecret) else {
            throw KrakenError(message: "The private key is not valid: paste it again from Kraken.")
        }
        var req = URLRequest(url: URL(string: "https://api.kraken.com" + path)!, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "API-Key")
        req.setValue(sign, forHTTPHeaderField: "API-Sign")
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(post.utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        return try Self.result(data, resp)
    }

    private nonisolated static func result(_ data: Data, _ resp: URLResponse) throws -> [String: Any] {
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw KrakenError(message: "Kraken answered \(code) without data.") }
        if let errs = j["error"] as? [String], let e = errs.first {
            let friendly: String
            switch e {
            case "EAPI:Invalid key": friendly = "Kraken does not know this API key."
            case "EAPI:Invalid signature": friendly = "Kraken rejected the signature: check the private key."
            case "EGeneral:Permission denied": friendly = "This key may not query funds: tick “Query Funds” for it at Kraken."
            case "EAPI:Invalid nonce": friendly = "Kraken refused the request's number (nonce); this key may be used elsewhere too. Make a separate key for Deckhand."
            case let s where s.hasPrefix("EAPI:Rate limit"): friendly = "Kraken's rate limit: Deckhand waits a little."
            default: friendly = "Kraken: \(e)"
            }
            throw KrakenError(message: friendly)
        }
        return j["result"] as? [String: Any] ?? [:]
    }

    // MARK: what the bar gets

    func snapshot() -> [String: Any] {
        let cur = currency()
        var out: [String: Any] = ["hasKey": hasKey, "currency": cur, "at": Int(Date().timeIntervalSince1970)]
        if let e = lastError { out["error"] = e }
        guard hasKey, !balances.isEmpty else { return out }
        let cash = balances[cur]?.amount ?? 0
        let shown = shownSymbols(cur)
        var total = cash, hiddenValue = 0.0, hidden = 0
        for s in pricedSymbols(cur) { let v = value(s, cur) ?? 0; total += v; if !shown.contains(s) { hiddenValue += v; hidden += 1 } }
        hidden += balances.keys.filter { $0 != cur && pairs["\(KrakenPortfolio.kraken($0))/\(cur)"] == nil }.count   // nothing to price them with
        func d(_ x: Any?) -> Double? { x.flatMap { Double("\($0)") } }
        func pair(_ a: Any?, _ i: Int) -> Double? { (a as? [Any]).flatMap { $0.count > i ? d($0[i]) : nil } }
        out["coins"] = shown.map { s -> [String: Any] in
            let t = tickers[s] ?? [:], amount = balances[s]?.amount ?? 0, p = price(s) ?? 0
            let day = candles["1D"]?[s] ?? []
            let ref = day.first?.close ?? d(t["o"])
            var c: [String: Any] = ["sym": s, "amount": amount, "earn": balances[s]?.earn ?? 0, "price": p, "value": amount * p]
            if let ref, ref > 0 { c["chg"] = (p - ref) / ref; c["chgAbs"] = amount * (p - ref) }
            c["high"] = pair(t["h"], 1); c["low"] = pair(t["l"], 1); c["vwap"] = pair(t["p"], 1); c["volume"] = pair(t["v"], 1)
            c["trades"] = (t["t"] as? [Any]).flatMap { $0.count > 1 ? ($0[1] as? NSNumber)?.intValue : nil }
            c["open"] = d(t["o"]); c["bid"] = pair(t["b"], 0); c["ask"] = pair(t["a"], 0)
            c["spark"] = day.map { $0.close }
            return c.compactMapValues { $0 }
        }
        var periods: [String: Any] = [:]
        for p in Self.periods {
            let series = KrakenPortfolio.combine(shown.map { (balances[$0]?.amount ?? 0, candles[p.id]?[$0] ?? []) }, cash: cash + hiddenValue)
            guard series.count > 1 else { continue }
            var vals = series.map(\.value); vals[vals.count - 1] = total   // the last point is now
            let first = vals.first ?? total
            periods[p.id] = ["t": series.map(\.t), "v": vals.map { ($0 * 100).rounded() / 100 }, "hi": vals.max() ?? total, "lo": vals.min() ?? total,
                             "chgAbs": total - first, "chg": first > 0 ? (total - first) / first : 0]
        }
        out["periods"] = periods
        out["total"] = total; out["cash"] = cash; out["hidden"] = hidden; out["hiddenValue"] = hiddenValue
        if let u = updatedAt { out["updated"] = Int(u.timeIntervalSince1970) }
        return out
    }

    /// Deckhand Home's line: the total and today's change.
    func homeLine() -> (line: String, tone: String)? {
        let s = snapshot()
        guard let total = s["total"] as? Double else { return nil }
        let nf = NumberFormatter(); nf.numberStyle = .currency; nf.currencyCode = currency(); nf.maximumFractionDigits = 0
        let chg = ((s["periods"] as? [String: Any])?["1D"] as? [String: Any])?["chg"] as? Double ?? 0
        let pct = abs(chg) >= 0.0005 ? String(format: " %@%.1f%%", chg > 0 ? "▲" : "▼", abs(chg) * 100) : ""
        return ((nf.string(from: total as NSNumber) ?? "") + pct, chg >= 0.0005 ? "up" : chg <= -0.0005 ? "down" : "")
    }
}
