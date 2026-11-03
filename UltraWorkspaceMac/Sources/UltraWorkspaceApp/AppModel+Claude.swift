import Foundation
import UserNotifications
import UltraBarKit

@MainActor
extension AppModel {
    /// While the Claude card is in use and notifications are on, check every minute whether a
    /// Claude Code session has ended its turn and waits for input; post one notification per rise.
    func startClaudeWatch(settings: AppSettings) {
        guard claudeWatchTask == nil else { return }
        claudeWatchTask = Task { [weak self] in
            var last = 0
            while !Task.isCancelled {
                guard let self else { return }
                if settings.claudeNotifyWaiting, settings.vivoCards.contains(.claude) {
                    let n = await Task.detached { ClaudeUsage.waitingSessions() }.value
                    if n > last { self.notify(title: "Claude Code is waiting for you", body: n == 1 ? "A session ended its turn and needs your input." : "\(n) sessions ended their turn and need your input.") }
                    last = n
                }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    private func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let c = UNMutableNotificationContent(); c.title = title; c.body = body; c.sound = .default
            center.add(UNNotificationRequest(identifier: "claude-waiting-\(Date().timeIntervalSince1970)", content: c, trigger: nil))
        }
    }
}
