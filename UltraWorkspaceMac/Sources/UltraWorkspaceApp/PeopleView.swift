import SwiftUI

/// People: saved contacts with one-click Teams chat / call, FaceTime and Mail. Nothing to do with the bar, so it is
/// its own window (Window › People, ⌥⌘P, and the menu bar icon) rather than a page of the main window.
@MainActor
enum PeopleWindow {
    static let id = "people"
    /// SwiftUI's `openWindow(id:)`, handed over by the main window when it appears.
    static var openAction: (() -> Void)?
    static func open() {
        AppActivation.bringToFront()
        if let openAction { openAction() } else { MainWindow.bringForward() }
    }
}

@MainActor final class DraftContact: ObservableObject {
    @Published var name = ""; @Published var email = ""; @Published var phone = ""
}

struct PeopleView: View {
    @EnvironmentObject var contacts: ContactStore
    @StateObject private var draft = DraftContact()
    @State private var pendingRemove: Contact? = nil

    var body: some View {
        Form {
            Section {
                if contacts.contacts.isEmpty {
                    Text("Nobody yet. Add a colleague below.").foregroundStyle(.secondary)
                }
                ForEach(contacts.contacts) { c in
                    LabeledContent {
                        HStack(spacing: 4) {
                            Button { PeopleActions.teamsChat(c) } label: { Image(systemName: "message") }.help("Teams chat").accessibilityLabel("Teams chat with \(c.name)")
                            Button { PeopleActions.teamsCall(c) } label: { Image(systemName: "phone") }.help("Teams call").accessibilityLabel("Teams call with \(c.name)")
                            Button { PeopleActions.faceTime(c) } label: { Image(systemName: "video") }.help("FaceTime").accessibilityLabel("FaceTime \(c.name)")
                            Button { PeopleActions.mail(c) } label: { Image(systemName: "envelope") }.help("Mail").accessibilityLabel("Mail \(c.name)")
                            RemoveMark(title: c.name) { pendingRemove = c }
                        }
                        .buttonStyle(.borderless)
                    } label: {
                        Text(c.name)
                        Text(c.email)
                    }
                }
            } header: {
                Text("People")
            } footer: {
                Footnote("Kept only on this Mac.")
            }
            Section {
                TextField("Name", text: $draft.name, prompt: Text("Anna de Vries"))
                TextField("Email", text: $draft.email, prompt: Text("name@work.com"))
                TextField("Phone", text: $draft.phone, prompt: Text("Optional, for calls"))
                Button("Add Person") {
                    let n = draft.name.trimmingCharacters(in: .whitespaces), e = draft.email.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty, !e.isEmpty else { return }
                    contacts.add(Contact(name: n, email: e, phone: draft.phone.trimmingCharacters(in: .whitespaces)))
                    draft.name = ""; draft.email = ""; draft.phone = ""
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty || draft.email.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Add a person")
            } footer: {
                Footnote("A name and an email address are needed.")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, minHeight: 360)
        .confirmationDialog("Remove \(pendingRemove?.name ?? "this person")?", isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let c = pendingRemove { contacts.remove(c) }; pendingRemove = nil }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        } message: { Text("The contact is deleted from this Mac.") }
    }
}
