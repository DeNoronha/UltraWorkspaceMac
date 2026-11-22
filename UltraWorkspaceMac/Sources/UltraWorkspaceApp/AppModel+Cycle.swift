import Foundation
import UltraBarKit

/// Bar System → Cycle through apps: every 1, 3, 5 or 10 minutes Deckhand opens the next bar app over the debug
/// bridge (`am start`). The decision is `BarCycle.turn`: nothing happens while the bar's screen is off, until the
/// screen has not been touched for a whole interval, or while an app outside the cycle is open. One loop for the
/// app's life (started with the other services); it only talks to the bar while cycling is on.
extension AppModel {
    /// The activity every Deckhand bar app opens with (android/DeckhandMonitor, namespace `nl.denoronha.deckhand.monitor`).
    nonisolated static let barAppActivity = "nl.denoronha.deckhand.monitor.MainActivity"

    /// The packages in the cycle, in the Apps page's order: the chosen bar apps (all when none are chosen) that are
    /// on the bar.
    func barCyclePackages(settings: AppSettings) -> [String] {
        let chosen = Set(settings.barCyclePages)
        return Self.barAppPages.map(\.page)
            .filter { chosen.isEmpty || chosen.contains($0) }
            .filter { barApps.isEmpty || barAppVersion($0) != nil }
            .map { BarPages.package(for: $0) }
    }

    func startBarCycle(settings: AppSettings) {
        barCycleTask?.cancel()
        barCycleTask = Task { [weak self] in
            var due = Date()
            while !Task.isCancelled {
                guard let self else { return }
                if !settings.barCycle {
                    if self.barCycleStatus != "Off." { self.barCycleStatus = "Off." }
                    due = Date()
                } else if Date() >= due {
                    due = Date().addingTimeInterval(await self.barCycleTurn(settings: settings))
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// One turn; returns the seconds until the next one.
    private func barCycleTurn(settings: AppSettings) async -> TimeInterval {
        let interval = TimeInterval(settings.barCycleMinutes * 60)
        guard let adb = AdbBridge.find(), let ip = ipForSelected() else { barCycleStatus = "Needs the debug bridge and a selected bar."; return 60 }
        let bridge = AdbBridge(path: adb, ip: ip)
        guard await bridge.connect() else { barCycleStatus = "The bar does not accept the debug bridge. See Settings → Debug Bridge."; return 60 }
        let power = await bridge.shell("dumpsys power | grep -E 'mWakefulness=|mLastUserActivityTime='")
        let front = BarCycle.resumedPackage(await bridge.shell("dumpsys activity activities | grep -m2 ResumedActivity"))
        let cycle = barCyclePackages(settings: settings)
        let homes: Set<String> = [Self.homePackage, VendorRelease.launcherPackage]
        switch BarCycle.turn(awake: BarCycle.isAwake(power), idle: BarCycle.idleSeconds(power), front: front, cycle: cycle, homes: homes, interval: interval) {
        case .open(let pkg):
            let out = await bridge.shell("am start -n \(pkg)/\(Self.barAppActivity)")
            let label = Self.barAppPages.first { BarPages.package(for: $0.page) == pkg }?.label ?? pkg
            if out.contains("Error") || out.contains("does not exist") {
                barCycleStatus = "\(label) could not be opened: \(out.trimmingCharacters(in: .whitespacesAndNewlines))"
                return 60
            }
            barCycleStatus = "Showing \(label) since \(Date().formatted(date: .omitted, time: .shortened)); the next app in \(settings.barCycleMinutes) min."
            return interval
        case .wait(let seconds, let reason):
            switch reason {
            case .screenOff: barCycleStatus = "Waiting: the bar's screen is off."
            case .touched: barCycleStatus = "Waiting: the bar was touched less than \(settings.barCycleMinutes) min ago."
            case .otherApp(let pkg): barCycleStatus = "Waiting: another app is open on the bar (\(pkg))."
            case .nothingToCycle: barCycleStatus = cycle.isEmpty ? "No bar apps to cycle through: install some under Apps." : "Only one app to show."
            }
            return seconds
        }
    }
}
