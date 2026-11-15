import Foundation

/// The pure parts of the Portfolio bar app (Kraken): asset codes, and the portfolio's value over time.
public enum KrakenPortfolio {
    /// A balance key → the coin it is, and whether it is an Earn/staking variant. Kraken's keys are the old four-letter
    /// codes ("XXBT", "XETH", "ZEUR"), plain codes ("DOT", "USDC"), and Earn variants with a suffix ("ETH2.S", "DOT.S",
    /// "USDC.M", "XBT.F"). `altnames` is Kraken's /Assets map (code → altname) when known.
    public static func normalize(_ key: String, altnames: [String: String] = [:]) -> (symbol: String, earn: Bool) {
        let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
        var base = parts.first ?? key
        let earn = parts.count > 1
        if let alt = altnames[base], !alt.contains(".") { base = alt }
        else if base.count == 4, let f = base.first, f == "X" || f == "Z", legacy.contains(base) { base = String(base.dropFirst()) }
        if base == "ETH2" { base = "ETH" }
        return (display(base), earn)
    }
    private static let legacy: Set<String> = ["XXBT", "XETH", "XXRP", "XLTC", "XXLM", "XXMR", "XZEC", "XREP", "XETC", "XMLN", "XXDG",
                                              "ZEUR", "ZUSD", "ZGBP", "ZCAD", "ZJPY", "ZAUD"]
    /// Kraken's names for two coins → what everyone calls them.
    public static func display(_ s: String) -> String { ["XBT": "BTC", "XDG": "DOGE"][s] ?? s }
    /// The other way, to find a pair ("BTC/EUR" is "XBT/EUR" at Kraken).
    public static func kraken(_ s: String) -> String { ["BTC": "XBT", "DOGE": "XDG"][s] ?? s }
    public static let fiat: Set<String> = ["EUR", "USD", "GBP", "CAD", "JPY", "AUD", "CHF"]

    /// The value over time of fixed amounts of several coins: at each moment of the first (longest) series, the sum of
    /// amount × the latest close at or before it (or the coin's first close, before its series starts), plus `cash`.
    public static func combine(_ holdings: [(amount: Double, closes: [(t: Int, close: Double)])], cash: Double) -> [(t: Int, value: Double)] {
        let withData = holdings.filter { !$0.closes.isEmpty }
        guard let times = withData.map({ $0.closes.map(\.t) }).max(by: { $0.count < $1.count }), !times.isEmpty else { return [] }
        var idx = Array(repeating: 0, count: withData.count)
        return times.sorted().map { t in
            var v = cash
            for (k, h) in withData.enumerated() {
                while idx[k] + 1 < h.closes.count, h.closes[idx[k] + 1].t <= t { idx[k] += 1 }
                v += h.amount * h.closes[idx[k]].close
            }
            return (t, v)
        }
    }
}
