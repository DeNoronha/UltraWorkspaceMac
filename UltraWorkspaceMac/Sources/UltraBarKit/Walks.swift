import Foundation

/// The pure parts of the Walk bar app: when the dog's next walk is due, the free gaps between meetings, whether it is
/// dry, and the best moment to go (the first free gap long enough for a walk, a dry one if there is one).
public enum Walks {
    public struct Span: Equatable, Sendable {
        public var start: Date
        public var end: Date
        public init(_ start: Date, _ end: Date) { self.start = start; self.end = end }
        public var length: TimeInterval { end.timeIntervalSince(start) }
    }

    /// The gaps of at least `minLength` between `from` and `to` that no busy span covers. Busy spans may overlap and
    /// come in any order.
    public static func freeGaps(busy: [Span], from: Date, to: Date, minLength: TimeInterval) -> [Span] {
        guard to > from else { return [] }
        var out: [Span] = []
        var cursor = from
        for b in busy.filter({ $0.end > from && $0.start < to }).sorted(by: { $0.start < $1.start }) {
            if b.start > cursor, b.start.timeIntervalSince(cursor) >= minLength { out.append(Span(cursor, b.start)) }
            if b.end > cursor { cursor = b.end }
        }
        if to.timeIntervalSince(cursor) >= minLength { out.append(Span(cursor, to)) }
        return out
    }

    /// The span in `spans` that `date` falls in.
    public static func covering(_ date: Date, in spans: [Span]) -> Span? {
        spans.filter { $0.start <= date && $0.end > date }.max { $0.end < $1.end }
    }

    /// Whether it is wet now and until when it stays that way, from rain samples (the start of each period and the
    /// rain in millimetres in it, in time order). `until` is nil when it stays so for all the samples there are; the
    /// whole answer is nil without a sample for now.
    public enum Sky: Equatable, Sendable { case dry(until: Date?), wet(until: Date?) }

    public static func sky(_ rain: [(Date, Double)], now: Date, period: TimeInterval = 900, threshold: Double = 0.1) -> Sky? {
        guard let i = rain.firstIndex(where: { $0.0 <= now && now < $0.0.addingTimeInterval(period) }) else { return nil }
        let wet = rain[i].1 >= threshold
        let change = rain[(i + 1)...].first { ($0.1 >= threshold) != wet }?.0
        return wet ? .wet(until: change) : .dry(until: change)
    }

    /// Whether there is no rain from `start` for `length`, as far as the samples reach (a period without a sample
    /// counts as dry: the forecast doesn't reach that far).
    public static func isDry(_ rain: [(Date, Double)], from start: Date, length: TimeInterval, period: TimeInterval = 900, threshold: Double = 0.1) -> Bool {
        let end = start.addingTimeInterval(length)
        return !rain.contains { $0.1 >= threshold && $0.0 < end && $0.0.addingTimeInterval(period) > start }
    }

    /// The best moment for a walk of `length` from `earliest` on: in the first free gap long enough, at its start or a
    /// little later when that is dry and the start is not (a dry slot in a later gap wins over a wet one now only when
    /// it is within an hour and a half of the first). Nil without a gap long enough.
    public static func suggestion(gaps: [Span], rain: [(Date, Double)], length: TimeInterval, earliest: Date) -> (span: Span, dry: Bool)? {
        let usable = gaps.compactMap { g -> Span? in
            let s = max(g.start, earliest)
            return g.end.timeIntervalSince(s) >= length ? Span(s, g.end) : nil
        }
        guard let first = usable.first else { return nil }
        // Every quarter of an hour in each gap where a whole walk fits.
        for g in usable where g.start.timeIntervalSince(first.start) <= 90 * 60 {
            var t = g.start
            while t.addingTimeInterval(length) <= g.end, t.timeIntervalSince(first.start) <= 90 * 60 {
                if isDry(rain, from: t, length: length) { return (Span(t, t.addingTimeInterval(length)), true) }
                // On to the next quarter of the hour (the rain comes in quarters, so a shower ends on one).
                t = Date(timeIntervalSince1970: (t.timeIntervalSince1970 / 900).rounded(.down) * 900 + 900)
            }
        }
        return (Span(first.start, first.start.addingTimeInterval(length)), false)
    }

    /// Whether an hour of the day is inside the active hours `from..<to` (hours 0–24; `from` > `to` runs past midnight).
    public static func isActive(hour: Int, from: Int, to: Int) -> Bool {
        from == to ? true : from < to ? (hour >= from && hour < to) : (hour >= from || hour < to)
    }

    /// The active window of the day `date` is in: from `from` o'clock to `to` o'clock (the next day when `to` <= `from`).
    public static func window(on date: Date, from: Int, to: Int, calendar: Calendar = .current) -> Span {
        let day = calendar.startOfDay(for: date)
        let s = calendar.date(byAdding: .hour, value: from, to: day) ?? day
        var e = calendar.date(byAdding: .hour, value: to, to: day) ?? day
        if e <= s { e = calendar.date(byAdding: .day, value: 1, to: e) ?? e }
        return Span(s, e)
    }

    /// When the next walk is due: `interval` after the last one ended, but not before the active hours start (the
    /// first walk of the day is due when they start), and nil once the day's active hours are over.
    public static func due(lastEnd: Date?, interval: TimeInterval, now: Date, from: Int, to: Int, calendar: Calendar = .current) -> Date? {
        var w = window(on: now, from: from, to: to, calendar: calendar)
        // Before today's window starts, a window that started yesterday and runs past midnight may still be on.
        if now < w.start, from > to {
            let y = window(on: calendar.date(byAdding: .day, value: -1, to: now) ?? now, from: from, to: to, calendar: calendar)
            if now < y.end { w = y }
        }
        if now >= w.end { return nil }
        guard let last = lastEnd, last >= w.start else { return w.start }
        let d = last.addingTimeInterval(interval)
        return d < w.end ? d : nil
    }

    /// "1 h 20 min", "45 min", "0 min".
    public static func duration(_ seconds: TimeInterval) -> String {
        let m = max(0, Int((seconds / 60).rounded(.down)))
        return m < 60 ? "\(m) min" : "\(m / 60) h" + (m % 60 > 0 ? " \(m % 60) min" : "")
    }

    /// The dog's name for the bar's lines; "the dog" when none is set.
    public static func dogName(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "the dog" : String(t.prefix(24))
    }
}
