import Foundation

/// Inline progress for a multi-step device action (render → upload → apply → show).
/// Replaces narration in the status bar with state the page can draw.
struct StepProgress: Equatable {
    enum State: Equatable { case pending, running, done, failed }
    struct Step: Identifiable, Equatable {
        let id: String
        var title: String
        var state: State = .pending
        var note: String = ""
    }
    var steps: [Step] = []
    var startedAt: Date?
    var finishedAt: Date?
    /// One plain sentence when something went wrong.
    var failure: String?

    var isRunning: Bool { startedAt != nil && finishedAt == nil }
    var succeeded: Bool { finishedAt != nil && failure == nil && !steps.isEmpty }
    var isEmpty: Bool { steps.isEmpty }

    mutating func begin(_ list: [(String, String)]) {
        steps = list.map { Step(id: $0.0, title: $0.1) }
        startedAt = Date(); finishedAt = nil; failure = nil
    }
    mutating func run(_ id: String, note: String = "") {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[i].state = .running; steps[i].note = note
    }
    mutating func done(_ id: String, note: String? = nil) {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[i].state = .done; if let note { steps[i].note = note }
        if steps.allSatisfy({ $0.state == .done }) { finishedAt = Date() }
    }
    mutating func fail(_ id: String, _ message: String) {
        if let i = steps.firstIndex(where: { $0.id == id }) { steps[i].state = .failed; steps[i].note = "" }
        failure = message; finishedAt = Date()
    }
    /// Fail before any step ran (precondition not met).
    mutating func failNow(_ message: String) {
        if steps.isEmpty { steps = [Step(id: "start", title: "Start", state: .failed)] }
        startedAt = startedAt ?? Date(); failure = message; finishedAt = Date()
    }
}

/// Plain-English version of an upload / request error.
enum FriendlyError {
    static func text(_ error: Error) -> String { text(error.localizedDescription) }
    static func text(_ raw: String) -> String {
        let l = raw.lowercased()
        if l.contains("hotspotip") { return "The cube is not on Wi-Fi, so the upload could not reach it. Set the cube's Wi-Fi (Maintenance) or detach and re-attach the cube." }
        if l.contains("reply error:4") || l.contains("reply error:2") { return "The cube says it is not on Wi-Fi (it is usually stuck “connecting”). Send its Wi-Fi settings again under Maintenance, wait until it shows “connected”, then send the cards again." }
        if l.contains("out of upload slots") { return "The bar's launcher has used up its upload slots — a leak in its firmware, one per upload, 100 per start. Deckhand restarts the launcher over Wi-Fi ADB when it can; otherwise restart the bar." }
        if l.contains("reply error") || l.contains("state\":-") || l.contains("state\": -") { return "The cube did not take the upload (it may be busy or off Wi-Fi). Try again in a minute or check the cube's Wi-Fi." }
        if l.contains("timed out") || l.contains("timeout") { return "The bar did not answer in time. Is it on the same Wi-Fi?" }
        if l.contains("token") || l.contains("auth") { return "The bar no longer accepts this Mac — pair again." }
        if l.contains("certificate") || l.contains("pin") { return "The bar's certificate changed — pair again." }
        if l.contains("connection refused") || l.contains("unreachable") || l.contains("host") { return "Could not reach the bar at its last address. Is it on and on the same Wi-Fi?" }
        return raw
    }
}
