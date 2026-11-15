import AppKit
import UltraBarKit

/// Whether this Mac is in use: awake, its screens on and the session unlocked. Deckhand runs all day in the
/// background, so the loops that only matter while someone looks (the cube's card switching, the Music poll, the
/// bar apps' feeds when no bar app asks) pause while the Mac sleeps, its screens are off or it is locked, and
/// pick up again on their next round. The link to the bar and its heartbeat are not affected.
@MainActor
final class PowerState {
    static let shared = PowerState()

    private(set) var asleep = false
    private(set) var screensAsleep = false
    private(set) var locked = false
    /// Nobody uses this Mac right now.
    var idle: Bool { asleep || screensAsleep || locked }

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    private init() {
        // A launch at login can happen behind the lock screen.
        if let s = CGSessionCopyCurrentDictionary() as? [String: Any] { locked = (s["CGSSessionScreenIsLocked"] as? Bool) ?? false }
        let ws = NSWorkspace.shared.notificationCenter
        observe(ws, NSWorkspace.willSleepNotification) { $0.asleep = true }
        observe(ws, NSWorkspace.didWakeNotification) { $0.asleep = false }
        observe(ws, NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true }
        observe(ws, NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false }
        // Fast user switching away from this session counts as locked.
        observe(ws, NSWorkspace.sessionDidResignActiveNotification) { $0.locked = true }
        observe(ws, NSWorkspace.sessionDidBecomeActiveNotification) { $0.locked = false }
        // The lock screen itself is only announced on the distributed center.
        let dist = DistributedNotificationCenter.default()
        observe(dist, Notification.Name("com.apple.screenIsLocked")) { $0.locked = true }
        observe(dist, Notification.Name("com.apple.screenIsUnlocked")) { $0.locked = false }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ apply: @escaping @MainActor (PowerState) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let was = self.idle
                apply(self)
                if was != self.idle { WireLog.shared.event("power: this Mac is \(self.idle ? "idle (asleep, screens off or locked)" : "in use again")") }
            }
        }
        observers.append((center, token))
    }
}

/// A sleep that ends early when someone calls `signal()`: the loops that used to wake every 2 to 5 s to see whether
/// a bar app had asked for data now sleep for minutes and are woken by the request itself.
@MainActor
final class WakeSignal {
    private var waiters: [UUID: (cont: CheckedContinuation<Bool, Never>, timer: Task<Void, Never>)] = [:]

    /// Wakes every current sleeper.
    func signal() {
        let all = waiters; waiters.removeAll()
        for w in all.values { w.timer.cancel(); w.cont.resume(returning: true) }
    }

    /// Sleeps up to `seconds` (with a fifth as timer tolerance, so the system can batch the wake-up). True when
    /// woken by `signal()`, false when the time ran out or the task was cancelled.
    @discardableResult
    func sleep(_ seconds: Double) async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled { cont.resume(returning: false); return }
                let timer = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(max(0, seconds)), tolerance: .seconds(max(0.1, seconds / 5)))
                    if !Task.isCancelled { self?.finish(id) }
                }
                waiters[id] = (cont, timer)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id) }
        }
    }

    /// Sleeps up to `seconds`, waking on a `signal()` only when `until()` is then true; other signals put it back to
    /// sleep for the time that is left. `until` is not checked before the first sleep.
    func wait(_ seconds: Double, until: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !Task.isCancelled {
            let left = end.timeIntervalSinceNow
            guard left > 0 else { return }
            guard await sleep(left) else { return }
            if until() { return }
        }
    }

    private func finish(_ id: UUID) {
        guard let w = waiters.removeValue(forKey: id) else { return }
        w.timer.cancel(); w.cont.resume(returning: false)
    }
}

extension Task where Success == Never, Failure == Never {
    /// `Task.sleep` with a fifth of the interval as tolerance, so the system can line the wake-up up with others.
    static func relaxedSleep(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds), tolerance: .seconds(max(0.1, seconds / 5)))
    }
}
