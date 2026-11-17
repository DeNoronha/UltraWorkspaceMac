import Foundation

/// The pure parts of the Chess bar app: positions from FEN, a game's moves from its PGN replayed square by square (so
/// the bar can show the last move, the check and the captured pieces), and the small readings of Chess.com's public
/// data (names from player links, an opening's name from its link, a result code as win, loss or draw).
public enum Chess {
    // MARK: squares

    /// 0 = a1, 7 = h1, 56 = a8, 63 = h8.
    public static func square(_ name: Substring) -> Int? {
        let u = Array(name.unicodeScalars)
        guard u.count == 2, (97...104).contains(u[0].value), (49...56).contains(u[1].value) else { return nil }
        return Int(u[1].value - 49) * 8 + Int(u[0].value - 97)
    }
    public static func name(_ sq: Int) -> String {
        String(UnicodeScalar(UInt8(97 + sq % 8))) + String(sq / 8 + 1)
    }

    // MARK: position

    public struct Move: Equatable, Sendable {
        public var from: Int
        public var to: Int
        public var san: String
        public var captured: Character?
    }

    /// A position: pieces as FEN letters (upper case white), the side to move, castling rights and the en passant square.
    public struct Position: Equatable, Sendable {
        public var board: [Character?]
        public var whiteToMove: Bool
        public var castling: Set<Character>
        public var enPassant: Int?

        public static let startFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
        public static var start: Position { Position(fen: startFEN)! }

        public init?(fen: String) {
            let f = fen.split(separator: " ")
            guard let placement = f.first else { return nil }
            var b = [Character?](repeating: nil, count: 64)
            let ranks = placement.split(separator: "/", omittingEmptySubsequences: false)
            guard ranks.count == 8 else { return nil }
            for (i, r) in ranks.enumerated() {
                var file = 0
                for ch in r {
                    if let n = ch.wholeNumberValue { file += n; continue }
                    guard "pnbrqkPNBRQK".contains(ch), file < 8 else { return nil }
                    b[(7 - i) * 8 + file] = ch; file += 1
                }
                guard file == 8 else { return nil }
            }
            board = b
            whiteToMove = f.count < 2 || f[1] != "b"
            castling = f.count > 2 ? Set(f[2].filter { "KQkq".contains($0) }) : []
            enPassant = f.count > 3 ? Chess.square(f[3]) : nil
        }

        /// Piece placement, side, castling and en passant square (the counters are left out).
        public var fen: String {
            var rows: [String] = []
            for rank in stride(from: 7, through: 0, by: -1) {
                var row = "", empty = 0
                for file in 0..<8 {
                    if let p = board[rank * 8 + file] { if empty > 0 { row += String(empty); empty = 0 }; row.append(p) } else { empty += 1 }
                }
                if empty > 0 { row += String(empty) }
                rows.append(row)
            }
            let c = "KQkq".filter { castling.contains($0) }
            return rows.joined(separator: "/") + (whiteToMove ? " w " : " b ") + (c.isEmpty ? "-" : c) + " " + (enPassant.map(Chess.name) ?? "-")
        }
        public var placement: String { String(fen.split(separator: " ")[0]) }

        static func isWhite(_ p: Character) -> Bool { p.isUppercase }

        /// Whether `sq` is attacked by the given side.
        public func attacked(_ sq: Int, byWhite: Bool) -> Bool {
            let f = sq % 8, r = sq / 8
            func at(_ df: Int, _ dr: Int) -> Character? {
                let nf = f + df, nr = r + dr
                guard (0..<8).contains(nf), (0..<8).contains(nr) else { return nil }
                return board[nr * 8 + nf]
            }
            func own(_ p: Character?, _ kind: Character) -> Bool { p.map { Position.isWhite($0) == byWhite && Character($0.lowercased()) == kind } ?? false }
            let pawnDir = byWhite ? -1 : 1               // an attacking white pawn stands one rank below
            if own(at(-1, pawnDir), "p") || own(at(1, pawnDir), "p") { return true }
            for (df, dr) in Chess.knight where own(at(df, dr), "n") { return true }
            for (df, dr) in Chess.kingSteps where own(at(df, dr), "k") { return true }
            for (dirs, kinds) in [(Chess.straight, "rq"), (Chess.diagonal, "bq")] {
                for (df, dr) in dirs {
                    var k = 1
                    while let nf = Optional(f + df * k), let nr = Optional(r + dr * k), (0..<8).contains(nf), (0..<8).contains(nr) {
                        if let p = board[nr * 8 + nf] {
                            if Position.isWhite(p) == byWhite && kinds.contains(Character(p.lowercased())) { return true }
                            break
                        }
                        k += 1
                    }
                }
            }
            return false
        }

        public func king(white: Bool) -> Int? { board.firstIndex { $0 == (white ? "K" : "k") } }
        public var inCheck: Bool { king(white: whiteToMove).map { attacked($0, byWhite: !whiteToMove) } ?? false }

        /// The squares a piece of `kind` (lower case) of the side to move could come from to reach `to`, ignoring pins.
        func origins(kind: Character, to: Int, capture: Bool) -> [Int] {
            let white = whiteToMove, f = to % 8, r = to / 8
            func mine(_ sq: Int) -> Bool { board[sq].map { Position.isWhite($0) == white && Character($0.lowercased()) == kind } ?? false }
            func valid(_ nf: Int, _ nr: Int) -> Int? { (0..<8).contains(nf) && (0..<8).contains(nr) ? nr * 8 + nf : nil }
            var out: [Int] = []
            switch kind {
            case "p":
                let dir = white ? 1 : -1
                if capture {
                    for df in [-1, 1] { if let s = valid(f + df, r - dir), mine(s) { out.append(s) } }
                } else if board[to] == nil {
                    if let s = valid(f, r - dir) {
                        if mine(s) { out.append(s) }
                        else if board[s] == nil, r == (white ? 3 : 4), let s2 = valid(f, r - 2 * dir), mine(s2) { out.append(s2) }
                    }
                }
            case "n":
                for (df, dr) in Chess.knight { if let s = valid(f + df, r + dr), mine(s) { out.append(s) } }
            case "k":
                for (df, dr) in Chess.kingSteps { if let s = valid(f + df, r + dr), mine(s) { out.append(s) } }
            default:
                let dirs = kind == "r" ? Chess.straight : kind == "b" ? Chess.diagonal : Chess.straight + Chess.diagonal
                for (df, dr) in dirs {
                    var k = 1
                    while let s = valid(f + df * k, r + dr * k) {
                        if board[s] != nil { if mine(s) { out.append(s) }; break }
                        k += 1
                    }
                }
            }
            return out
        }

        /// Plays one move in standard algebraic notation (`e4`, `Nbd7`, `exd6`, `O-O-O`, `e8=Q+`); nil when it is not
        /// a legal move here.
        public mutating func play(_ sanIn: String) -> Move? {
            let san = sanIn.trimmingCharacters(in: CharacterSet(charactersIn: "+#!? "))
            let white = whiteToMove
            let homeRank = white ? 0 : 7
            if san == "O-O" || san == "0-0" || san == "O-O-O" || san == "0-0-0" {
                let long = san.count > 3
                let k = homeRank * 8 + 4, to = homeRank * 8 + (long ? 2 : 6)
                let rook = homeRank * 8 + (long ? 0 : 7), rookTo = homeRank * 8 + (long ? 3 : 5)
                guard board[k] == (white ? "K" : "k"), board[rook] == (white ? "R" : "r") else { return nil }
                let between = long ? [1, 2, 3] : [5, 6]
                guard between.allSatisfy({ board[homeRank * 8 + $0] == nil }) else { return nil }
                guard ![4, long ? 3 : 5, long ? 2 : 6].contains(where: { attacked(homeRank * 8 + $0, byWhite: !white) }) else { return nil }
                board[to] = board[k]; board[k] = nil; board[rookTo] = board[rook]; board[rook] = nil
                castling.subtract(white ? ["K", "Q"] : ["k", "q"])
                enPassant = nil; whiteToMove.toggle()
                return Move(from: k, to: to, san: sanIn, captured: nil)
            }
            var body = Substring(san)
            var promotion: Character?
            if let eq = body.firstIndex(of: "=") {
                promotion = body[body.index(after: eq)...].first; body = body[..<eq]
            } else if let last = body.last, "QRBN".contains(last), body.first.map({ "abcdefgh".contains($0) }) == true, body.count >= 3 {
                promotion = last; body = body.dropLast()
            }
            guard body.count >= 2, let to = Chess.square(body.suffix(2)) else { return nil }
            var head = body.dropLast(2)
            var kind: Character = "p"
            if let first = head.first, "KQRBN".contains(first) { kind = Character(first.lowercased()); head = head.dropFirst() }
            let capture = head.contains("x")
            head.removeAll { $0 == "x" }
            var fromFile: Int?, fromRank: Int?
            for ch in head {
                if let a = ch.asciiValue, (97...104).contains(a) { fromFile = Int(a - 97) }
                else if let n = ch.wholeNumberValue, (1...8).contains(n) { fromRank = n - 1 }
                else { return nil }
            }
            let target = board[to]
            if let t = target, Position.isWhite(t) == white { return nil }
            let isEnPassant = kind == "p" && capture && target == nil && to == enPassant
            if kind == "p", capture, target == nil, !isEnPassant { return nil }
            var cands = origins(kind: kind, to: to, capture: capture || target != nil)
            if let ff = fromFile { cands = cands.filter { $0 % 8 == ff } }
            if let fr = fromRank { cands = cands.filter { $0 / 8 == fr } }
            // Two pieces could go there: the one that is not pinned to its king is meant.
            if cands.count > 1 {
                cands = cands.filter { from in
                    var p = self; p.move(from: from, to: to, enPassant: isEnPassant, promotion: promotion)
                    return !(p.king(white: white).map { p.attacked($0, byWhite: !white) } ?? false)
                }
            }
            guard cands.count == 1, let from = cands.first else { return nil }
            var next = self
            next.move(from: from, to: to, enPassant: isEnPassant, promotion: promotion)
            if let k = next.king(white: white), next.attacked(k, byWhite: !white) { return nil }
            let captured = isEnPassant ? (white ? "p" : "P") : target
            // Castling rights: a king or rook that moves, or a rook that is taken, ends them.
            for (sq, right) in [(4, "KQ"), (0, "Q"), (7, "K"), (60, "kq"), (56, "q"), (63, "k")] where from == sq || to == sq {
                next.castling.subtract(right)
            }
            next.enPassant = kind == "p" && abs(to - from) == 16 ? (from + to) / 2 : nil
            next.whiteToMove.toggle()
            self = next
            return Move(from: from, to: to, san: sanIn, captured: captured)
        }

        private mutating func move(from: Int, to: Int, enPassant ep: Bool, promotion: Character?) {
            var piece = board[from]
            if let pr = promotion, let p = piece { piece = Position.isWhite(p) ? Character(pr.uppercased()) : Character(pr.lowercased()) }
            board[to] = piece; board[from] = nil
            if ep { board[to + (whiteToMove ? -8 : 8)] = nil }
        }

        /// Material on the board per side (pawn 1, knight and bishop 3, rook 5, queen 9).
        public var material: (white: Int, black: Int) {
            var w = 0, b = 0
            for p in board.compactMap({ $0 }) {
                let v = ["p": 1, "n": 3, "b": 3, "r": 5, "q": 9][Character(p.lowercased())] ?? 0
                if Position.isWhite(p) { w += v } else { b += v }
            }
            return (w, b)
        }

        /// The pieces each side has lost, as FEN letters, most valuable first: what is missing from the starting set
        /// (a promoted pawn counts as the piece it became).
        public var missing: (white: String, black: String) {
            let full: [Character: Int] = ["q": 1, "r": 2, "b": 2, "n": 2, "p": 8]
            func lost(_ white: Bool) -> String {
                var have: [Character: Int] = [:]
                for p in board.compactMap({ $0 }) where Position.isWhite(p) == white { have[Character(p.lowercased()), default: 0] += 1 }
                // Promotions: extra queens, rooks, bishops or knights came from pawns.
                var pawnsGone = 0
                for k in ["q", "r", "b", "n"] as [Character] { pawnsGone += max(0, (have[k] ?? 0) - full[k]!) }
                var out = ""
                for k in ["q", "r", "b", "n", "p"] as [Character] {
                    var n = max(0, full[k]! - (have[k] ?? 0))
                    if k == "p" { n = max(0, n - pawnsGone) }
                    out += String(repeating: white ? Character(k.uppercased()) : k, count: n)
                }
                return out
            }
            return (lost(true), lost(false))
        }
    }

    static let knight = [(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)]
    static let kingSteps = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]
    static let straight = [(1, 0), (-1, 0), (0, 1), (0, -1)]
    static let diagonal = [(1, 1), (1, -1), (-1, 1), (-1, -1)]

    // MARK: PGN

    public struct Game: Sendable {
        public var headers: [String: String]
        public var sans: [String]
    }

    /// Headers and main-line moves of one PGN game: comments (`{…}`, `;…`), variations, NAGs, move numbers and the
    /// result are left out.
    public static func pgn(_ text: String) -> Game {
        var headers: [String: String] = [:]
        var movetext = ""
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("["), t.hasSuffix("]"), let sp = t.firstIndex(of: " ") {
                let key = String(t[t.index(after: t.startIndex)..<sp])
                var value = t[t.index(after: sp)..<t.index(before: t.endIndex)].trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
                headers[key] = value
            } else {
                movetext += (t.firstIndex(of: ";").map { String(t[..<$0]) } ?? t) + " "
            }
        }
        var clean = "", brace = false, paren = 0
        for ch in movetext {
            if brace { if ch == "}" { brace = false }; continue }
            if ch == "{" { brace = true; continue }
            if ch == "(" { paren += 1; continue }
            if ch == ")" { paren = max(0, paren - 1); continue }
            if paren == 0 { clean.append(ch) }
        }
        var sans: [String] = []
        for tok in clean.split(separator: " ") {
            guard !["1-0", "0-1", "1/2-1/2", "*"].contains(String(tok)) else { continue }
            // A move number (`12.`, `12...`, or glued to the move as `12.e4`); `0-0` has digits but no dot.
            var s = Substring(tok)
            let digits = s.prefix { $0.isNumber }
            if !digits.isEmpty, s.dropFirst(digits.count).first == "." { s = s.dropFirst(digits.count).drop { $0 == "." } }
            guard !s.isEmpty, !s.hasPrefix("$") else { continue }
            sans.append(String(s))
        }
        return Game(headers: headers, sans: sans)
    }

    /// Replays a game's moves from its start (the `FEN` header, else the normal start); stops at the first move it
    /// cannot play, so `moves.count < sans.count` means the record was not understood to the end.
    public static func replay(_ game: Game) -> (moves: [Move], position: Position) {
        var pos = game.headers["FEN"].flatMap(Position.init(fen:)) ?? .start
        var moves: [Move] = []
        for san in game.sans {
            guard let m = pos.play(san) else { break }
            moves.append(m)
        }
        return (moves, pos)
    }

    // MARK: Chess.com readings

    /// `https://api.chess.com/pub/player/erik` → `erik`.
    public static func username(fromPlayerURL url: String) -> String {
        url.split(separator: "/").last.map(String.init) ?? url
    }

    /// `https://www.chess.com/openings/Pirc-Defense-2.d4-Nf6-3.Bd3-e5` → `Pirc Defense` (the name, without the moves).
    public static func opening(fromURL url: String?) -> String? {
        guard let last = url?.split(separator: "/").last else { return nil }
        var words: [Substring] = []
        for w in last.split(separator: "-") {
            // The moves start at a number ("2.d4") or after an ellipsis glued to a word ("Variation...5.d3").
            if let dots = w.range(of: "...") { if dots.lowerBound > w.startIndex { words.append(w[..<dots.lowerBound]) }; break }
            if let f = w.first, f.isNumber || (w.count <= 3 && w.contains(".")) { break }
            words.append(w)
        }
        let s = words.joined(separator: " ").removingPercentEncoding ?? words.joined(separator: " ")
        return s.isEmpty ? nil : s
    }

    public enum Outcome: String, Sendable { case win, loss, draw }

    /// Chess.com's result codes for one side: `win`; draws (`agreed`, `repetition`, `stalemate`, `insufficient`,
    /// `50move`, `timevsinsufficient`); everything else (`checkmated`, `resigned`, `timeout`, `abandoned`, `lose`) is a loss.
    public static func outcome(_ code: String) -> Outcome {
        if code == "win" { return .win }
        if ["agreed", "repetition", "stalemate", "insufficient", "50move", "timevsinsufficient"].contains(code) { return .draw }
        return .loss
    }

    /// How a game ended, in words, from the loser's (or a draw's) result code.
    public static func ending(_ code: String) -> String {
        switch code {
        case "checkmated": return "checkmate"
        case "resigned": return "resignation"
        case "timeout": return "time"
        case "abandoned": return "abandonment"
        case "agreed": return "agreement"
        case "repetition": return "repetition"
        case "stalemate": return "stalemate"
        case "insufficient", "timevsinsufficient": return "insufficient material"
        case "50move": return "50-move rule"
        default: return code
        }
    }

    /// The order the time classes are shown in, with their labels.
    public static let classes: [(id: String, label: String)] = [("rapid", "Rapid"), ("blitz", "Blitz"), ("bullet", "Bullet"), ("daily", "Daily")]

    /// A Chess.com username as typed: trimmed, without a leading @ or a profile link around it; nil when it cannot be one.
    public static func cleanUsername(_ typed: String) -> String? {
        var s = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "chess.com/member/", options: .caseInsensitive) { s = String(s[r.upperBound...]) }
        else if let r = s.range(of: "/pub/player/", options: .caseInsensitive) { s = String(s[r.upperBound...]) }
        s = String(s.split(separator: "/").first ?? "")
        if s.hasPrefix("@") { s.removeFirst() }
        s = s.lowercased()
        guard (3...25).contains(s.count), s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
        return s
    }
}
