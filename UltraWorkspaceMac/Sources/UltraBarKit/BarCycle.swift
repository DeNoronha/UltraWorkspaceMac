import Foundation

/// The pure parts of cycling through the bar apps: reading what the bar says over the debug bridge (which app is in
/// front, how long ago the screen was touched, whether it is on) and deciding what to do at each turn.
public enum BarCycle {
    /// The intervals offered, in minutes.
    public static let intervals = [1, 3, 5, 10]

    /// The package of the app in front, from `dumpsys activity activities`
    /// (`mResumedActivity: ActivityRecord{5b29d87 u0 nl.denoronha.deckhand.walk/nl.denoronha.deckhand.monitor.MainActivity t305}`).
    public static func resumedPackage(_ dumpsys: String) -> String? {
        for line in dumpsys.split(whereSeparator: \.isNewline) where line.contains("ResumedActivity") {
            for word in line.split(separator: " ") where word.contains("/") {
                let pkg = word.split(separator: "/")[0]
                if pkg.contains(".") { return String(pkg) }
            }
        }
        return nil
    }

    /// How long ago the screen was last touched, in seconds, from `dumpsys power`
    /// (`mLastUserActivityTime=1325708037 (32221172 ms ago)`).
    public static func idleSeconds(_ dumpsys: String) -> TimeInterval? {
        guard let line = dumpsys.split(whereSeparator: \.isNewline).first(where: { $0.contains("mLastUserActivityTime=") }),
              let open = line.firstIndex(of: "("), let ms = line[line.index(after: open)...].split(separator: " ").first.flatMap({ Double($0) })
        else { return nil }
        return ms / 1000
    }

    /// Whether the screen is on, from `dumpsys power` (`mWakefulness=Awake`).
    public static func isAwake(_ dumpsys: String) -> Bool { dumpsys.contains("mWakefulness=Awake") }

    /// The app after `current` in `cycle`, wrapping round; the first one when `current` is not in it.
    public static func next(after current: String?, in cycle: [String]) -> String? {
        guard !cycle.isEmpty else { return nil }
        guard let c = current, let i = cycle.firstIndex(of: c) else { return cycle[0] }
        return cycle[(i + 1) % cycle.count]
    }

    public enum Turn: Equatable, Sendable {
        /// Open this app.
        case open(String)
        /// Leave the bar alone and look again in this many seconds, for this reason.
        case wait(TimeInterval, Reason)
    }
    public enum Reason: Equatable, Sendable { case screenOff, touched, otherApp(String), nothingToCycle }

    /// What to do at a turn. `front` is the package in front, `cycle` the packages in order, `homes` the home screens
    /// (from those, the cycle starts with its first app). The bar is left alone while its screen is off, until it has
    /// not been touched for a whole interval, and while an app that is not in the cycle is open: someone chose it.
    public static func turn(awake: Bool, idle: TimeInterval?, front: String?, cycle: [String], homes: Set<String>, interval: TimeInterval) -> Turn {
        if !awake { return .wait(60, .screenOff) }
        if let idle, idle < interval { return .wait(max(15, interval - idle), .touched) }
        if let f = front, !cycle.contains(f), !homes.contains(f) { return .wait(interval, .otherApp(f)) }
        guard let n = next(after: front, in: cycle), n != front else { return .wait(interval, .nothingToCycle) }
        return .open(n)
    }
}
