import Foundation
import UltraBarKit

/// The Chess bar app's data: one Chess.com player's ratings, daily games and recent games, and the puzzle of the day,
/// all from Chess.com's public data API (no account, no key, read only; the username is the only thing sent). Read on
/// this Mac, one request at a time, each with its last ETag so an unchanged answer is a 304:
///
///  - `/pub/player/{u}/games` (the daily games in progress) every 90 seconds;
///  - `/pub/player/{u}/stats` (ratings, best, win/loss/draw) every 10 minutes;
///  - this month's archive `/pub/player/{u}/games/{yyyy}/{mm}` every 5 minutes, last month's every 6 hours;
///  - `/pub/player/{u}` (name, title) and the archive list every 6 hours; `/pub/puzzle` every 3 hours.
///
/// Only while the app is on the bar or asked in the last ten minutes. The games are replayed here (UltraBarKit `Chess`)
/// so the bar gets the board, the last move and the captured pieces ready to draw. Kept in memory only.
@MainActor
final class ChessFeed: ObservableObject {
    @Published private(set) var lastError: String?
    @Published private(set) var updatedAt: Date?
    /// The player as Chess.com names them, for the settings ("Erik · Rapid 1904").
    @Published private(set) var summary: String?

    private var user: () -> String = { "" }
    private var showPuzzle: () -> Bool = { true }
    private var me = ""
    private var profile: [String: Any] = [:]
    private var stats: [String: Any] = [:]
    private var current: [[String: Any]] = []
    private var archives: [String] = []
    private var months: [String: [[String: Any]]] = [:]
    private var puzzle: [String: Any] = [:]
    private var fetchedAt: [String: Date] = [:]
    private var etags: [String: String] = [:]
    private var built: [String: Any] = [:]
    private var rateUntil: Date?
    /// Chess.com has no player by this name: no more requests until the name changes.
    private var unknown = false
    private var forced = false
    private var loop: Task<Void, Never>?
    private let wake = WakeSignal()

    func start(user: @escaping @MainActor () -> String, showPuzzle: @escaping @MainActor () -> Bool, wanted: @escaping @MainActor () -> Bool) {
        self.user = user; self.showPuzzle = showPuzzle
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let name = Chess.cleanUsername(user()) ?? ""
                if name != self.me {
                    // A name being typed: let it settle before asking Chess.com about it.
                    if !self.me.isEmpty || !name.isEmpty { try? await Task.sleep(for: .seconds(1.5)) }
                    let settled = Chess.cleanUsername(user()) ?? ""
                    if settled != name { continue }
                    self.reset(for: name)
                }
                let active = !self.me.isEmpty && !self.unknown && wanted()
                if active, (self.rateUntil ?? .distantPast) <= Date() || self.forced { self.forced = false; await self.refresh() }
                var wait: Double = active ? 90 : 600
                if active, let r = self.rateUntil, r > Date() { wait = max(30, r.timeIntervalSinceNow + 2) }
                await self.wake.wait(wait) { self.forced || (Chess.cleanUsername(user()) ?? "") != self.me || (!self.me.isEmpty && !self.unknown && wanted()) != active }
            }
        }
    }
    func stop() { loop?.cancel(); loop = nil }
    func poke() { wake.signal() }
    func refreshNow() { fetchedAt = [:]; etags = [:]; unknown = false; rateUntil = nil; forced = true; wake.signal() }

    private func reset(for name: String) {
        me = name; profile = [:]; stats = [:]; current = []; archives = []; months = [:]; fetchedAt = [:]; etags = [:]
        built = [:]; unknown = false; rateUntil = nil; lastError = nil; updatedAt = nil; summary = nil
    }

    // MARK: refresh

    private struct Failure: Error { let message: String }
    private enum Answer { case fresh(Any), unchanged }

    private func due(_ key: String, _ seconds: Double) -> Bool { Date().timeIntervalSince(fetchedAt[key] ?? .distantPast) >= seconds }

    private func refresh() async {
        let base = "https://api.chess.com/pub/player/\(me)"
        do {
            if due("games", 85), case .fresh(let j) = try await get(base + "/games", key: "games") {
                current = (j as? [String: Any])?["games"] as? [[String: Any]] ?? []
            }
            if due("stats", 600), case .fresh(let j) = try await get(base + "/stats", key: "stats") { stats = j as? [String: Any] ?? [:] }
            if due("profile", 21600), case .fresh(let j) = try await get(base, key: "profile") { profile = j as? [String: Any] ?? [:] }
            if due("archives", 21600) || !archives.contains(where: { $0.hasSuffix(Self.monthPath(Date())) }) && due("archives", 600),
               case .fresh(let j) = try await get(base + "/games/archives", key: "archives") {
                archives = (j as? [String: Any])?["archives"] as? [String] ?? []
            }
            // This month and the one before: enough for the last games and a month of rating history.
            let wantedMonths = Array(archives.suffix(2))
            months = months.filter { wantedMonths.contains($0.key) }
            for (i, url) in wantedMonths.enumerated() {
                let isLatest = i == wantedMonths.count - 1
                if due(url, isLatest ? 290 : 21600), case .fresh(let j) = try await get(url, key: url) {
                    months[url] = (j as? [String: Any])?["games"] as? [[String: Any]] ?? []
                }
            }
            if showPuzzle(), due("puzzle", 10800), case .fresh(let j) = try await get("https://api.chess.com/pub/puzzle", key: "puzzle") {
                puzzle = j as? [String: Any] ?? [:]
            }
            lastError = nil; updatedAt = Date()
        } catch let f as Failure {
            lastError = f.message
        } catch {
            lastError = "Chess.com: \(error.localizedDescription)"
        }
        built = build()
    }

    static func monthPath(_ d: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: d)
        return String(format: "/games/%04d/%02d", c.year ?? 2000, c.month ?? 1)
    }

    private func get(_ urlString: String, key: String) async throws -> Answer {
        guard let url = URL(string: urlString) else { throw Failure(message: "Chess.com: not a valid address.") }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Deckhand (+https://openbarx.com/)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let e = etags[key] { req.setValue(e, forHTTPHeaderField: "If-None-Match") }
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw Failure(message: "Chess.com answered without a status.") }
        switch http.statusCode {
        case 304:
            fetchedAt[key] = Date(); return .unchanged
        case 200:
            guard let j = try? JSONSerialization.jsonObject(with: data) else { throw Failure(message: "Chess.com sent something Deckhand couldn't read.") }
            fetchedAt[key] = Date()
            if let e = http.value(forHTTPHeaderField: "ETag") { etags[key] = e }
            return .fresh(j)
        case 404, 410:
            if key == "profile" || key == "stats" || key == "games" {
                unknown = true
                throw Failure(message: "Chess.com has no player called “\(me)”. Check the username.")
            }
            fetchedAt[key] = Date(); return .fresh([String: Any]())
        case 429:
            let wait = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 60
            rateUntil = Date().addingTimeInterval(wait)
            throw Failure(message: "Chess.com asked Deckhand to slow down. It waits \(Int(wait)) seconds.")
        default:
            throw Failure(message: "Chess.com answered \(http.statusCode). Deckhand tries again in a few minutes.")
        }
    }

    // MARK: what the bar gets

    func snapshot() -> [String: Any] {
        var out = built
        out["hasUser"] = !me.isEmpty
        out["user"] = me
        out["at"] = Int(Date().timeIntervalSince1970)
        if let e = lastError { out["error"] = e }
        return out
    }

    private func build() -> [String: Any] {
        guard !me.isEmpty, updatedAt != nil || !stats.isEmpty else { return [:] }
        var out: [String: Any] = [:]
        out["profile"] = [
            "name": (profile["name"] as? String) ?? (profile["username"] as? String) ?? me,
            "username": (profile["username"] as? String) ?? me,
            "title": profile["title"] as? String ?? "",
            "league": profile["league"] as? String ?? "",
            "country": (profile["country"] as? String).map(Chess.username(fromPlayerURL:)) ?? "",
        ]

        // Finished games, oldest first, with the user's side.
        let finished = months.values.flatMap { $0 }
            .filter { ($0["end_time"] as? Double) != nil }
            .sorted { ($0["end_time"] as? Double ?? 0) < ($1["end_time"] as? Double ?? 0) }
        func side(_ g: [String: Any]) -> (mine: [String: Any], theirs: [String: Any], white: Bool)? {
            guard let w = g["white"] as? [String: Any], let b = g["black"] as? [String: Any] else { return nil }
            if (w["username"] as? String)?.lowercased() == me { return (w, b, true) }
            if (b["username"] as? String)?.lowercased() == me { return (b, w, false) }
            return nil
        }

        // Ratings: Chess.com's current and best per time class, the change over 30 days from the games.
        var history: [String: [Int]] = [:]
        var counts: [String: Int] = [:]
        let monthAgo = Date().addingTimeInterval(-30 * 86400).timeIntervalSince1970
        var startOfWindow: [String: Int] = [:]
        for g in finished where g["rules"] as? String == "chess" && g["rated"] as? Bool != false {
            guard let cls = g["time_class"] as? String, let s = side(g), let r = s.mine["rating"] as? Int else { continue }
            history[cls, default: []].append(r)
            if (g["end_time"] as? Double ?? 0) >= monthAgo {
                counts[cls, default: 0] += 1
                if startOfWindow[cls] == nil { startOfWindow[cls] = history[cls]!.count >= 2 ? history[cls]![history[cls]!.count - 2] : r }
            }
        }
        var ratings: [[String: Any]] = []
        for c in Chess.classes {
            guard let s = stats["chess_\(c.id)"] as? [String: Any], let last = (s["last"] as? [String: Any])?["rating"] as? Int else { continue }
            var d: [String: Any] = ["id": c.id, "label": c.label, "rating": last]
            if let best = (s["best"] as? [String: Any])?["rating"] as? Int { d["best"] = best }
            if let rec = s["record"] as? [String: Any] { d["w"] = rec["win"] as? Int ?? 0; d["l"] = rec["loss"] as? Int ?? 0; d["d"] = rec["draw"] as? Int ?? 0 }
            if let start = startOfWindow[c.id] { d["delta"] = last - start }
            ratings.append(d)
        }
        out["ratings"] = ratings
        if let t = (stats["tactics"] as? [String: Any])?["highest"] as? [String: Any], let r = t["rating"] as? Int { out["puzzleBest"] = r }
        out["history"] = history.mapValues { Array($0.suffix(60)) }
        let main = counts.max { $0.value < $1.value }?.key ?? (ratings.first?["id"] as? String) ?? "rapid"
        out["main"] = main

        // Daily games in progress: the user's move first, soonest deadline first.
        var games: [[String: Any]] = []
        for g in current {
            guard let w = g["white"] as? String, let b = g["black"] as? String else { continue }
            let white = Chess.username(fromPlayerURL: w).lowercased() == me
            let pgn = Chess.pgn(g["pgn"] as? String ?? "")
            var d = board(pgn: pgn, fen: g["fen"] as? String, rules: g["rules"] as? String)
            d["kind"] = "daily"; d["id"] = g["url"] as? String ?? UUID().uuidString
            d["you"] = white ? "w" : "b"
            d["opp"] = pgn.headers[white ? "Black" : "White"] ?? Chess.username(fromPlayerURL: white ? b : w)
            if let r = Int(pgn.headers[white ? "BlackElo" : "WhiteElo"] ?? "") { d["oppRating"] = r }
            if let r = Int(pgn.headers[white ? "WhiteElo" : "BlackElo"] ?? "") { d["youRating"] = r }
            d["turn"] = (g["turn"] as? String) == (white ? "white" : "black")
            if let t = g["move_by"] as? Double, t > 0 { d["moveBy"] = Int(t) }
            d["cls"] = "daily"; d["tc"] = Self.timeControl(g["time_control"] as? String ?? "")
            d["url"] = (g["url"] as? String ?? "").replacingOccurrences(of: "https://www.", with: "")
            if let o = Chess.opening(fromURL: pgn.headers["ECOUrl"]) { d["opening"] = o }
            games.append(d)
        }
        games.sort { a, b in
            let ta = a["turn"] as? Bool == true, tb = b["turn"] as? Bool == true
            if ta != tb { return ta }
            return (a["moveBy"] as? Int ?? .max) < (b["moveBy"] as? Int ?? .max)
        }
        out["waiting"] = games.filter { $0["turn"] as? Bool == true }.count

        // The last finished games, newest first.
        var recent: [String] = []
        for g in finished.reversed().prefix(12) {
            guard let s = side(g) else { continue }
            let pgn = Chess.pgn(g["pgn"] as? String ?? "")
            var d = board(pgn: pgn, fen: g["fen"] as? String, rules: g["rules"] as? String)
            let mineCode = s.mine["result"] as? String ?? "", theirsCode = s.theirs["result"] as? String ?? ""
            let outcome = Chess.outcome(mineCode)
            d["kind"] = "done"; d["id"] = g["url"] as? String ?? UUID().uuidString
            d["you"] = s.white ? "w" : "b"
            d["opp"] = s.theirs["username"] as? String ?? "?"
            if let r = s.theirs["rating"] as? Int { d["oppRating"] = r }
            if let r = s.mine["rating"] as? Int { d["youRating"] = r }
            d["result"] = outcome.rawValue
            d["how"] = Chess.ending(outcome == .win ? theirsCode : mineCode)
            if let a = g["accuracies"] as? [String: Any], let me = a[s.white ? "white" : "black"] as? Double, let them = a[s.white ? "black" : "white"] as? Double {
                d["acc"] = [me, them].map { ($0 * 10).rounded() / 10 }
            }
            if let t = g["end_time"] as? Double { d["ended"] = Int(t) }
            d["cls"] = g["time_class"] as? String ?? ""
            d["tc"] = Self.timeControl(g["time_control"] as? String ?? "")
            d["url"] = (g["url"] as? String ?? "").replacingOccurrences(of: "https://www.", with: "")
            if let o = Chess.opening(fromURL: g["eco"] as? String ?? pgn.headers["ECOUrl"]) { d["opening"] = o }
            games.append(d)
            if recent.count < 10 { recent.append(outcome.rawValue) }
        }
        out["games"] = games
        out["recent"] = recent

        // The puzzle of the day: every position on the way, so the bar can check taps without knowing the rules.
        if showPuzzle(), let fen = puzzle["fen"] as? String, var pos = Chess.Position(fen: fen) {
            let start = pos
            var steps: [[String: Any]] = []
            for san in Chess.pgn(puzzle["pgn"] as? String ?? "").sans {
                guard let m = pos.play(san) else { break }
                steps.append(["from": m.from, "to": m.to, "san": m.san, "fen": pos.placement, "check": pos.inCheck])
            }
            if !steps.isEmpty {
                out["puzzle"] = ["title": puzzle["title"] as? String ?? "Puzzle of the day", "fen": start.placement, "toMove": start.whiteToMove ? "w" : "b",
                                 "steps": steps, "url": (puzzle["url"] as? String ?? "").replacingOccurrences(of: "https://www.", with: "")]
            }
        }

        // For the settings: who this is, and the rating that matters most.
        let mainRating = ratings.first { $0["id"] as? String == main }.flatMap { r in (r["label"] as? String).map { "\($0) \(r["rating"] as? Int ?? 0)" } }
        summary = [(out["profile"] as? [String: Any])?["name"] as? String, mainRating].compactMap { $0 }.joined(separator: " · ")
        return out
    }

    /// One game's position for the bar: the board, whose move, the last move and check, the captured pieces and the
    /// last moves written out. A game the rules here do not cover (Chess960) gets only Chess.com's own position.
    private func board(pgn: Chess.Game, fen: String?, rules: String?) -> [String: Any] {
        var d: [String: Any] = [:]
        let given = fen.flatMap(Chess.Position.init(fen:))
        var pos = given
        if rules == nil || rules == "chess" {
            let r = Chess.replay(pgn)
            if r.moves.count == pgn.sans.count {
                pos = r.position
                if let m = r.moves.last { d["last"] = [m.from, m.to] }
                d["ply"] = r.moves.count
                // "11. Ng5 Nbd5": the last six half-moves, numbered from the game's start.
                let startBlack = pgn.headers["FEN"].flatMap(Chess.Position.init(fen:)).map { !$0.whiteToMove } ?? false
                let startNumber = Int(pgn.headers["FEN"]?.split(separator: " ").last ?? "1") ?? 1
                var words: [String] = []
                let from = max(0, r.moves.count - 6)
                for i in from..<r.moves.count {
                    let ply = i + (startBlack ? 1 : 0), number = startNumber + ply / 2
                    if ply % 2 == 0 { words.append("\(number). \(r.moves[i].san)") }
                    else { words.append(i == from ? "\(number)… \(r.moves[i].san)" : r.moves[i].san) }
                }
                d["moves"] = words
            }
        }
        guard let p = pos ?? given else { return d }
        d["fen"] = p.placement
        d["toMove"] = p.whiteToMove ? "w" : "b"
        d["check"] = p.inCheck
        let lost = p.missing, m = p.material
        d["lost"] = ["w": lost.white, "b": lost.black]
        d["diff"] = m.white - m.black
        return d
    }

    /// `1/259200` → `3 days`, `600` → `10 min`, `180+2` → `3 | 2`.
    static func timeControl(_ s: String) -> String {
        if s.hasPrefix("1/"), let secs = Int(s.dropFirst(2)) { let days = secs / 86400; return days == 1 ? "1 day" : "\(days) days" }
        let parts = s.split(separator: "+").compactMap { Int($0) }
        guard let base = parts.first else { return s }
        let minutes = base >= 60 ? (base % 60 == 0 ? "\(base / 60)" : String(format: "%.1f", Double(base) / 60)) : "\(base)s"
        return parts.count > 1 && parts[1] > 0 ? "\(minutes) | \(parts[1])" : base >= 60 ? "\(minutes) min" : minutes
    }

    /// Deckhand Home's line: the games waiting for the user's move, else the main rating.
    func homeLine() -> (line: String, tone: String, badge: Int)? {
        guard !built.isEmpty else { return nil }
        let waiting = built["waiting"] as? Int ?? 0
        if waiting > 0 { return ("Your move in \(waiting) game\(waiting == 1 ? "" : "s")", "warn", waiting) }
        let main = built["main"] as? String
        guard let r = (built["ratings"] as? [[String: Any]])?.first(where: { $0["id"] as? String == main }),
              let label = r["label"] as? String, let rating = r["rating"] as? Int else { return nil }
        let delta = r["delta"] as? Int ?? 0
        return ("\(label) \(rating)" + (delta != 0 ? (delta > 0 ? " ▲\(delta)" : " ▼\(-delta)") : ""), delta > 0 ? "up" : delta < 0 ? "down" : "", 0)
    }
}
