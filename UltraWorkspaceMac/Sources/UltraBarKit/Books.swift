import Foundation

/// The pure parts of the Books bar app (e-Boekhouden.nl's REST API): the ledgers (`GET /v1/ledger`), their balances
/// (`GET /v1/ledger/balances`, at a date or over a period) and the outstanding invoices
/// (`GET /v1/mutation/invoice/outstanding`) → bank accounts, profit and revenue, debtors and creditors.
public enum Books {
    public struct Ledger: Equatable, Sendable {
        public var id: Int
        public var code: String
        public var name: String
        /// e-Boekhouden's category: BAL, VW (profit and loss), FIN (bank and cash), DEB, CRED, or a VAT category.
        public var category: String
        public init(id: Int, code: String, name: String, category: String) { self.id = id; self.code = code; self.name = name; self.category = category }
    }

    public static func ledgers(_ j: [String: Any]) -> [Ledger] {
        ((j["items"] as? [[String: Any]]) ?? []).compactMap { l in
            guard let id = (l["id"] as? NSNumber)?.intValue, let code = l["code"] as? String else { return nil }
            return Ledger(id: id, code: code, name: ((l["description"] as? String) ?? code).trimmingCharacters(in: .whitespaces),
                          category: (l["category"] as? String) ?? "")
        }
    }

    /// `GET /v1/ledger/balances` → balance per ledger code.
    public static func balances(_ j: [String: Any]) -> [String: Double] {
        var out: [String: Double] = [:]
        for b in (j["items"] as? [[String: Any]]) ?? [] {
            guard let code = b["code"] as? String, let v = (b["balance"] as? NSNumber)?.doubleValue else { continue }
            out[code, default: 0] += v
        }
        return out
    }

    /// Revenue ledgers: profit-and-loss ledgers numbered 8000–8999 (the Dutch chart of accounts e-Boekhouden starts from).
    public static func isRevenue(_ l: Ledger) -> Bool { l.category == "VW" && l.code.hasPrefix("8") }

    /// The ledgers' sign: revenue is a credit, so with debit-positive balances it comes out negative. +1 when revenue
    /// balances are positive (credit-positive), −1 otherwise (and when there is no revenue to tell by).
    public static func creditSign(_ period: [String: Double], ledgers: [Ledger]) -> Double {
        let r = ledgers.filter(isRevenue).reduce(0.0) { $0 + (period[$1.code] ?? 0) }
        return r > 0 ? 1 : -1
    }

    public struct Result: Equatable, Sendable {
        public var revenue: Double
        public var costs: Double
        public var profit: Double { revenue - costs }
        public init(revenue: Double, costs: Double) { self.revenue = revenue; self.costs = costs }
    }

    /// Revenue and costs over a period (balances with `from`), as positive amounts; `sign` from `creditSign`.
    public static func result(_ period: [String: Double], ledgers: [Ledger], sign: Double) -> Result {
        var revenue = 0.0, all = 0.0
        for l in ledgers where l.category == "VW" {
            let v = (period[l.code] ?? 0) * sign            // credit positive
            all += v
            if isRevenue(l) { revenue += v }
        }
        return Result(revenue: revenue, costs: revenue - all)
    }

    /// The bank and cash accounts (category FIN) at a date, as money in the bank (debit positive), largest first.
    public static func bank(_ now: [String: Double], ledgers: [Ledger], sign: Double) -> [(name: String, balance: Double)] {
        ledgers.filter { $0.category == "FIN" }
            .map { (name: $0.name, balance: -sign * (now[$0.code] ?? 0)) }
            .sorted { abs($0.balance) > abs($1.balance) }
    }

    public struct Invoice: Equatable, Sendable {
        public var number: String
        public var company: String
        public var date: Date
        public var outstanding: Double
        public init(number: String, company: String, date: Date, outstanding: Double) {
            self.number = number; self.company = company; self.date = date; self.outstanding = outstanding
        }
    }

    public static func outstanding(_ j: [String: Any]) -> [Invoice] {
        ((j["items"] as? [[String: Any]]) ?? []).compactMap { i in
            guard let amount = (i["outstandingAmount"] as? NSNumber)?.doubleValue, abs(amount) >= 0.005,
                  let date = (i["date"] as? String).flatMap(day) else { return nil }
            return Invoice(number: (i["invoiceNumber"] as? String) ?? "", company: ((i["company"] as? String) ?? "").trimmingCharacters(in: .whitespaces),
                           date: date, outstanding: amount)
        }
    }

    public struct Open: Equatable, Sendable {
        public var total: Double
        public var count: Int
        /// Older than `days` (e-Boekhouden does not return the payment term, so the age of the invoice decides).
        public var overdue: Double
        public var overdueCount: Int
        /// The largest, oldest first among equals.
        public var top: [Invoice]
    }

    public static func open(_ invoices: [Invoice], now: Date, days: Int = 30) -> Open {
        let limit = now.addingTimeInterval(-Double(days) * 86400)
        let old = invoices.filter { $0.date < limit }
        return Open(total: invoices.reduce(0) { $0 + $1.outstanding }, count: invoices.count,
                    overdue: old.reduce(0) { $0 + $1.outstanding }, overdueCount: old.count,
                    top: invoices.sorted { $0.outstanding != $1.outstanding ? $0.outstanding > $1.outstanding : $0.date < $1.date }.prefix(5).map { $0 })
    }

    /// "2026-11-14" or "2026-11-14T00:00:00" → that day (local midnight).
    public static func day(_ s: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(s.prefix(10)))
    }
    public static func dayString(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }
}
