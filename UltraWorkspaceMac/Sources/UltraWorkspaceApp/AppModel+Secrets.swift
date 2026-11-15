import Foundation
import AppKit
import UltraBarKit

/// The secret store at launch and quit (see UltraBarKit/SecretStore.swift).
extension AppModel {
    /// One Activity line about the move of the old plain-file secrets, and the quit hook that writes keys still
    /// waiting for their debounce.
    func reportSecretMigration() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            Store.shared.flushPendingSecrets()
        }
        guard let r = Store.shared.migrationReport, !r.skipped else { return }
        let kind = Store.shared.secrets.kind
        if !r.failed.isEmpty {
            say("\(r.failed.count) secret\(r.failed.count == 1 ? "" : "s") could not be moved to the \(kind); the old copies are kept and it is tried again at the next launch.")
        } else if !r.moved.isEmpty {
            say("Moved \(r.moved.count) secret\(r.moved.count == 1 ? "" : "s") to the \(kind) and deleted the old files. Older Time Machine backups may still hold those files.")
        }
    }
}
