import Foundation
import UltraBarKit

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
///
/// `UltraBarError` cases map by type (`text(_ error:)`); only errors from outside the kit (URLSession,
/// POSIX) and bare reply strings go through the word table in `fallback`, which used to match "host"
/// inside "hotspot" and route a module-link error to "could not reach the bar".
enum FriendlyError {
    // The eight sentences, each used from exactly one place below.
    static let cubeNoLink = "The cube is not on Wi-Fi, so the upload could not reach it. Set the cube's Wi-Fi (Maintenance) or detach and re-attach the cube."
    static let cubeOffWiFi = "The cube says it is not on Wi-Fi (it is usually stuck “connecting”). Send its Wi-Fi settings again under Maintenance, wait until it shows “connected”, then send the cards again."
    static let launcherExhausted = "The bar's launcher has used up its upload slots — a leak in its firmware, one per upload, 100 per start. Deckhand restarts the launcher over Wi-Fi ADB when it can; otherwise restart the bar."
    static let cubeModuleOffline = "The bar does not see the cube. Check that it sits firmly on the bar and its battery is not flat; if it does and the bar still says offline, Deckhand restarts the bar's launcher (needs Wi-Fi ADB) or restart the bar."
    static let uploadRefused = "The cube did not take the upload (it may be busy or off Wi-Fi). Try again in a minute or check the cube's Wi-Fi."
    static let noAnswer = "The bar did not answer in time. Is it on the same Wi-Fi?"
    static let pairAgain = "The bar no longer accepts this Mac — pair again."
    static let certChanged = "The bar's certificate changed — pair again."
    static let unreachable = "Could not reach the bar at its last address. Is it on and on the same Wi-Fi?"

    static func text(_ error: Error) -> String {
        guard let e = error as? UltraBarError else { return fallback(error.localizedDescription) }
        switch e {
        case .uploadRejected(let body): return uploadText(body)
        case .timeout, .pairingTimedOut: return noAnswer
        case .authRejected, .pairingNoToken: return pairAgain
        case .certPinMismatch: return certChanged
        case .notConnected: return unreachable
        // Already a plain sentence (Reject was tapped, or the bar's own reason).
        case .pairingRejected: return e.localizedDescription
        // Free text from the kit: a TLS message or a protocol note ("Set a city …", "bad upload URL").
        case .tlsFailed, .protocolError: return fallback(e.localizedDescription)
        }
    }

    /// A bare string: an upload reply as `UploadDiag` kept it, or an already-described error.
    static func text(_ raw: String) -> String {
        if raw.contains("reply error") || raw.contains("\"state\":") || raw.contains("hotspotIp") { return uploadText(raw) }
        return fallback(raw)
    }

    /// The body of an `uploadRejected`, read the way `CoreBarSession.upload` reads the bar's reply.
    private static func uploadText(_ body: String) -> String {
        if body == CoreBarSession.launcherExhaustedText { return launcherExhausted }
        if body == CoreBarSession.moduleOfflineText { return cubeModuleOffline }
        if body.contains("hotspot has no IP") { return cubeNoLink }   // the kit's own sentence for `hotspotNoIp` after its retries
        switch CoreBarSession.UploadReply(accepted: false, text: body) {
        case .accepted: return body
        case .hotspotNoIp: return cubeNoLink
        case .cubeOffline: return cubeOffWiFi
        case .launcherExhausted: return launcherExhausted
        case .moduleOffline: return cubeModuleOffline
        case .moduleNotFound, .other: return body.contains("\"state\":-") || body.contains("\"state\": -") || body.contains("reply error") ? uploadRefused : fallback(body)
        }
    }

    /// Word table for text that did not come from the kit's typed errors (URLSession, POSIX, Process).
    private static func fallback(_ raw: String) -> String {
        let l = raw.lowercased()
        if l.contains("out of upload slots") { return launcherExhausted }
        if l.contains("timed out") || l.contains("timeout") { return noAnswer }
        if l.contains("token") || l.contains("unauthori") || l.contains("authentication") { return pairAgain }
        if l.contains("certificate") || l.contains("pinned") || l.contains("pin mismatch") { return certChanged }
        if l.contains("connection refused") || l.contains("unreachable") || l.contains("hostname") || l.contains("route to host") || l.contains("host is down") { return unreachable }
        return raw
    }
}
