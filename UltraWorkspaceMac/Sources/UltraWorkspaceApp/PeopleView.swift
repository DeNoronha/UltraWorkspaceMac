import SwiftUI

@MainActor final class DraftContact: ObservableObject {
    @Published var name = ""; @Published var email = ""; @Published var phone = ""
}

struct PeopleView: View {
    @EnvironmentObject var contacts: ContactStore
    @StateObject private var draft = DraftContact()
    @State private var pendingRemove: Contact? = nil
    var body: some View {
        VStack(spacing: 0) {
            Header("People", "One-click Teams, FaceTime and Mail.")
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if contacts.contacts.isEmpty {
                    EmptyState(icon: "person.2", title: "Nobody yet", text: "Add a colleague below to call or message them in one click.") { EmptyView() }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(contacts.contacts) { c in
                                HStack {
                                    VStack(alignment: .leading) { Text(c.name).fontWeight(.medium); Text(c.email).font(.caption).foregroundStyle(.secondary) }
                                    Spacer()
                                    Button { PeopleActions.teamsChat(c) } label: { Image(systemName: "message.fill") }.help("Teams chat").accessibilityLabel("Teams chat with \(c.name)")
                                    Button { PeopleActions.teamsCall(c) } label: { Image(systemName: "phone.fill") }.help("Teams call").accessibilityLabel("Teams call \(c.name)")
                                    Button { PeopleActions.faceTime(c) } label: { Image(systemName: "video.fill") }.help("FaceTime").accessibilityLabel("FaceTime \(c.name)")
                                    Button { PeopleActions.mail(c) } label: { Image(systemName: "envelope.fill") }.help("Mail").accessibilityLabel("Mail \(c.name)")
                                    Button(role: .destructive) { pendingRemove = c } label: { Image(systemName: "trash") }.help("Remove").accessibilityLabel("Remove \(c.name)")
                                }.buttonStyle(.borderless).padding(.vertical, 2)
                                Divider()
                            }
                        }
                    }
                }
                Divider()
                HStack {
                    TextField("Name", text: $draft.name).frame(width: 130)
                    TextField("name@work.com", text: $draft.email).frame(width: 170)
                    TextField("Phone", text: $draft.phone).frame(width: 110)
                    Button("Add") {
                        let n = draft.name.trimmingCharacters(in: .whitespaces); let e = draft.email.trimmingCharacters(in: .whitespaces)
                        guard !n.isEmpty, !e.isEmpty else { return }
                        contacts.add(Contact(name: n, email: e, phone: draft.phone.trimmingCharacters(in: .whitespaces)))
                        draft.name = ""; draft.email = ""; draft.phone = ""
                    }.keyboardShortcut(.defaultAction).disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty || draft.email.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Kept only on this Mac. A name and an email address are needed; the phone number is for Teams calls.").font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }
        // Same guard as every other Remove in the app: ask first.
        .alert("Remove \(pendingRemove?.name ?? "this person")?", isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } })) {
            Button("Remove", role: .destructive) { if let c = pendingRemove { contacts.remove(c) }; pendingRemove = nil }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        }
    }
}
