import Foundation
import UltraBarKit

/// The Books bar app's data, from the user's e-Boekhouden.nl administration with an API token (Keychain), read on this
/// Mac so the token never reaches the bar; the app asks for `/books/data.json`.
///
///  - Session: `POST /v1/session` with the token, kept until it expires.
///  - Ledgers: `GET /v1/ledger` (names and categories) and `GET /v1/administration` (the company), once a day.
///  - Every 15 minutes while the app is on the bar: the balances today (`GET /v1/ledger/balances?to=`, the bank and
///    cash accounts), this year so far and this month (`…?from=&to=`, revenue, costs, profit), and the outstanding
///    invoices of debtors and creditors (`GET /v1/mutation/invoice/outstanding?credDeb=D|C`).
///  - Once a day: every finished month of this year and last year, for the revenue chart.
///
/// Read only: Deckhand never books anything. A refused token stops the loop until it changes. Nothing runs while the
/// app is not on the bar and nobody asked in the last ten minutes. Kept in memory only.
@MainActor
final class BooksFeed: ObservableObject {
    @Published var token: String = Store.shared.loadSecret(name: "eboekhouden-token") ?? "" {
        didSet { Store.shared.saveSecret(token.trimmingCharacters(in: .whitespacesAndNewlines), name: "eboekhouden-token", debounce: true); changed() }
    }
    @Published private(set) var lastError: String?
    @Published private(set) var updatedAt: Date?
    @Published private(set) var company: String?

    var hasToken: Bool { !token.trimmingCharacters(in: .whitespaces).isEmpty }

    private var session: (token: String, expires: Date)?
    private var ledgers: [Books.Ledger] = []
    private var ledgersAt = Date.distantPast
    private var sign: Double = -1
    private var bank: [(name: String, balance: Double)] = []
    private var ytd: Books.Result?
    private var months: [Int: Double] = [:]          // month 1–12 of this year → revenue
    private var monthsProfit: [Int: Double] = [:]
    private var lastYear: [Int: Double] = [:]
    private var historyDay = ""
    private var debtors: Books.Open?
    private var creditors: Books.Open?
    private var rejected = false
    private var forced = false
    private var loop: Task<Void, Never>?
    private let wake = WakeSignal()
    private var hide: () -> Bool = { false }

    nonisolated static let base = "https://api.e-boekhouden.nl"

    func start(hide: @escaping @MainActor () -> Bool, wanted: @escaping @MainActor () -> Bool) {
        self.hide = hide
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // A token being typed or pasted: wait until it has not changed for 1.5 s.
                while self.forced, !Task.isCancelled { self.forced = false; try? await Task.sleep(for: .seconds(1.5)) }
                let active = self.hasToken && !self.rejected && wanted()
                if active { await self.refresh() }
                await self.wake.wait(active ? 900 : 600) { self.forced || (self.hasToken && !self.rejected && wanted()) != active }
            }
        }
    }
    func stop() { loop?.cancel(); loop = nil }
    func poke() { wake.signal() }
    func refreshNow() { rejected = false; ledgersAt = .distantPast; historyDay = ""; forced = true; wake.signal() }

    private func changed() {
        session = nil; rejected = false; lastError = nil; updatedAt = nil; company = nil; ledgers = []; ledgersAt = .distantPast
        bank = []; ytd = nil; months = [:]; monthsProfit = [:]; lastYear = [:]; historyDay = ""; debtors = nil; creditors = nil
        forced = true; wake.signal()
    }

    // MARK: refresh

    private struct Failure: Error { let message: String }

    private func refresh() async {
        do {
            let cal = Calendar.current, now = Date()
            let year = cal.component(.year, from: now), month = cal.component(.month, from: now)
            let today = Books.dayString(now)
            if Date().timeIntervalSince(ledgersAt) > 86400 || ledgers.isEmpty {
                var all: [Books.Ledger] = []
                var offset = 0
                while true {
                    let j = try await get("/v1/ledger?limit=2000&offset=\(offset)")
                    let page = Books.ledgers(j)
                    all += page; offset += page.count
                    if page.isEmpty || offset >= ((j["count"] as? NSNumber)?.intValue ?? 0) { break }
                }
                ledgers = all; ledgersAt = Date()
                if let a = try? await get("/v1/administration?limit=1"), let c = ((a["items"] as? [[String: Any]])?.first?["company"] as? String) {
                    company = c.trimmingCharacters(in: .whitespaces)
                }
            }
            let first = "\(year)-01-01"
            let ytdBalances = Books.balances(try await get("/v1/ledger/balances?from=\(first)&to=\(today)"))
            if ledgers.contains(where: Books.isRevenue), ytdBalances.values.contains(where: { $0 != 0 }) {
                let s = Books.creditSign(ytdBalances, ledgers: ledgers)
                if ledgers.filter(Books.isRevenue).contains(where: { (ytdBalances[$0.code] ?? 0) != 0 }) { sign = s }
            }
            ytd = Books.result(ytdBalances, ledgers: ledgers, sign: sign)
            bank = Books.bank(Books.balances(try await get("/v1/ledger/balances?to=\(today)")), ledgers: ledgers, sign: sign)
            // This month every time; the finished months of this year and all of last year once a day.
            let thisMonth = Books.result(Books.balances(try await get("/v1/ledger/balances?from=\(monthStart(year, month))&to=\(today)")), ledgers: ledgers, sign: sign)
            months[month] = thisMonth.revenue; monthsProfit[month] = thisMonth.profit
            if historyDay != today {
                for m in 1..<month {
                    let r = Books.result(Books.balances(try await get("/v1/ledger/balances?from=\(monthStart(year, m))&to=\(monthEnd(year, m))")), ledgers: ledgers, sign: sign)
                    months[m] = r.revenue; monthsProfit[m] = r.profit
                }
                for m in 1...12 {
                    lastYear[m] = Books.result(Books.balances(try await get("/v1/ledger/balances?from=\(monthStart(year - 1, m))&to=\(monthEnd(year - 1, m))")), ledgers: ledgers, sign: sign).revenue
                }
                months = months.filter { $0.key <= month }
                historyDay = today
            }
            debtors = Books.open(try await outstanding("D"), now: now)
            creditors = Books.open(try await outstanding("C"), now: now)
            lastError = nil; updatedAt = Date()
        } catch let f as Failure {
            lastError = f.message
        } catch {
            lastError = "e-Boekhouden: \(error.localizedDescription)"
        }
    }

    private func outstanding(_ kind: String) async throws -> [Books.Invoice] {
        var all: [Books.Invoice] = []
        var offset = 0
        while true {
            let j = try await get("/v1/mutation/invoice/outstanding?credDeb=\(kind)&limit=2000&offset=\(offset)")
            let n = ((j["items"] as? [Any]) ?? []).count
            all += Books.outstanding(j); offset += n
            if n == 0 || offset >= ((j["count"] as? NSNumber)?.intValue ?? 0) || offset >= 10000 { break }
        }
        return all
    }

    private func monthStart(_ y: Int, _ m: Int) -> String { String(format: "%04d-%02d-01", y, m) }
    private func monthEnd(_ y: Int, _ m: Int) -> String {
        let cal = Calendar(identifier: .gregorian)
        let d = cal.date(from: DateComponents(year: y, month: m, day: 1)).flatMap { cal.range(of: .day, in: .month, for: $0)?.count } ?? 28
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    private func sessionToken() async throws -> String {
        if let s = session, s.expires.timeIntervalSinceNow > 60 { return s.token }
        var req = URLRequest(url: URL(string: Self.base + "/v1/session")!, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["accessToken": token.trimmingCharacters(in: .whitespacesAndNewlines), "source": "Deckhand"])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let t = j["token"] as? String else {
            if code == 400 || code == 401 || code == 403 {
                // e-Boekhouden answers {"type":"security","title":"Login failed","lockoutMinutes":n} or an API_SESSION_ code.
                rejected = true
                let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let why = [j?["code"] as? String, j?["title"] as? String].compactMap { $0 }.joined(separator: ": ")
                let lock = (j?["lockoutMinutes"] as? NSNumber).map { " Sign-in is locked for \($0.intValue) minutes." } ?? ""
                throw Failure(message: "e-Boekhouden didn't accept the API token" + (why.isEmpty ? "." : " (\(why)).") + lock)
            }
            throw Failure(message: "e-Boekhouden's sign-in answered \(code). Deckhand tries again in 15 minutes.")
        }
        let s = (t, Date().addingTimeInterval(Double((j["expiresIn"] as? NSNumber)?.intValue ?? 600)))
        session = s
        return t
    }

    private func get(_ path: String, retried: Bool = false) async throws -> [String: Any] {
        let t = try await sessionToken()
        var req = URLRequest(url: URL(string: Self.base + path)!, timeoutInterval: 30)
        req.setValue(t, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        case 401 where !retried: session = nil; return try await get(path, retried: true)
        case 401, 403: rejected = true; throw Failure(message: "e-Boekhouden refused access with this token.")
        case 429: throw Failure(message: "e-Boekhouden asked Deckhand to slow down. It tries again in 15 minutes.")
        default: throw Failure(message: "e-Boekhouden answered \(code). Deckhand tries again in 15 minutes.")
        }
    }

    // MARK: what the bar gets

    func snapshot() -> [String: Any] {
        var out: [String: Any] = ["hasToken": hasToken, "hide": hide(), "at": Int(Date().timeIntervalSince1970)]
        if let e = lastError { out["error"] = e }
        if let c = company { out["company"] = c }
        guard hasToken, updatedAt != nil else { return out }
        let now = Date(), year = Calendar.current.component(.year, from: now)
        out["year"] = year
        out["bank"] = bank.prefix(4).map { ["name": $0.name, "balance": $0.balance] }
        out["bankTotal"] = bank.reduce(0) { $0 + $1.balance }
        if let y = ytd { out["ytd"] = ["revenue": y.revenue, "costs": y.costs, "profit": y.profit] }
        out["months"] = (1...12).map { months[$0].map { $0 as Any } ?? NSNull() }
        out["monthsProfit"] = (1...12).map { monthsProfit[$0].map { $0 as Any } ?? NSNull() }
        out["lastYear"] = (1...12).map { lastYear[$0].map { $0 as Any } ?? NSNull() }
        func open(_ o: Books.Open?) -> Any {
            guard let o else { return NSNull() }
            return ["total": o.total, "count": o.count, "overdue": o.overdue, "overdueCount": o.overdueCount,
                    "top": o.top.map { ["company": $0.company, "number": $0.number, "amount": $0.outstanding,
                                        "days": max(0, Int(now.timeIntervalSince($0.date) / 86400))] }]
        }
        out["debtors"] = open(debtors); out["creditors"] = open(creditors)
        if let u = updatedAt { out["updated"] = Int(u.timeIntervalSince1970) }
        return out
    }

    /// Deckhand Home's line: profit so far this year and what customers still owe (amounts hidden when the user chose so).
    func homeLine() -> (line: String, tone: String)? {
        guard hasToken, updatedAt != nil, let y = ytd else { return nil }
        if hide() { return ("Books up to date", "") }
        let f = NumberFormatter(); f.numberStyle = .currency; f.currencyCode = "EUR"; f.locale = Locale(identifier: "nl_NL"); f.maximumFractionDigits = 0
        var parts = ["Profit \(f.string(from: NSNumber(value: y.profit)) ?? "")"]
        if let d = debtors, d.total > 0 { parts.append("\(f.string(from: NSNumber(value: d.total)) ?? "") to collect") }
        return (parts.joined(separator: " · "), (debtors?.overdueCount ?? 0) > 0 ? "warn" : "")
    }
}
