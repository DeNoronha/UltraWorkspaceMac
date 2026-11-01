import Foundation
import AppKit

/// A saved person: one button can open a Teams chat/call, FaceTime, or mail them.
struct Contact: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var email: String       // used for Teams chat + mail
    var phone: String = ""  // optional, for FaceTime/calls
}

@MainActor
enum PeopleActions {
    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Start a Microsoft Teams chat with the person (opens the Teams app/web).
    static func teamsChat(_ c: Contact) {
        let u = c.email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? c.email
        open("https://teams.microsoft.com/l/chat/0/0?users=\(u)")
    }

    /// Start a Microsoft Teams call with the person.
    static func teamsCall(_ c: Contact) {
        let u = c.email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? c.email
        open("https://teams.microsoft.com/l/call/0/0?users=\(u)")
    }

    static func faceTime(_ c: Contact) {
        let target = c.phone.isEmpty ? c.email : c.phone
        open("facetime://\(target)")
    }

    static func mail(_ c: Contact) {
        open("mailto:\(c.email)")
    }
}

/// Persists the user's contacts list in Application Support.
@MainActor
final class ContactStore: ObservableObject {
    @Published var contacts: [Contact] = []
    private let url: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("UltraWorkspaceMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("contacts.json")
        load()
    }

    func load() {
        if let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([Contact].self, from: data) {
            contacts = list
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(contacts) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func add(_ c: Contact) { contacts.append(c); save() }
    func remove(_ c: Contact) { contacts.removeAll { $0.id == c.id }; save() }
}
