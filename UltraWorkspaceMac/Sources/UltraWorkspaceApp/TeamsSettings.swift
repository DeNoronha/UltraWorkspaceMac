import SwiftUI
import UltraBarKit

/// Apps → Teams: the speed-dial contacts, which calendars the meetings come from, and whether meetings without a join
/// link show too.
struct TeamsSettings: View {
    @ObservedObject var feed: TeamsFeed
    @EnvironmentObject var settings: AppSettings
    @State private var calendars: [CalendarSource.CalInfo] = []

    var body: some View {
        Section {
            ForEach($settings.teamsContacts) { $c in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("Name", text: $c.name, prompt: Text("Name"))
                            .frame(maxWidth: 160)
                        TextField("E-mail", text: $c.email, prompt: Text("name@company.com"))
                            .autocorrectionDisabled()
                        if !c.email.isEmpty, !Meetings.isEmail(c.email) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("Not an e-mail address")
                        }
                        Button { move(c.id, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless).disabled(settings.teamsContacts.first?.id == c.id).help("Move up")
                        Button { move(c.id, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless).disabled(settings.teamsContacts.last?.id == c.id).help("Move down")
                        Button(role: .destructive) { settings.teamsContacts.removeAll { $0.id == c.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Remove")
                    }
                    HStack(spacing: 8) {
                        TextField("Call from", text: $c.account, prompt: Text("Your account for this person (optional)"))
                            .autocorrectionDisabled()
                        if !accounts.isEmpty {
                            Menu {
                                Button("Whichever account Teams is on") { c.account = "" }
                                Divider()
                                ForEach(accounts, id: \.self) { a in Button(a) { c.account = a } }
                            } label: { Image(systemName: "person.crop.circle") }
                                .menuStyle(.borderlessButton).fixedSize().help("Your accounts on this Mac")
                        }
                        accountStatus(c.account)
                    }
                }
                .padding(.vertical, 2)
            }
            Button("Add Contact") { settings.teamsContacts.append(TeamsContact(name: "", email: "")) }
                .disabled(settings.teamsContacts.count >= 8)
        } header: {
            Text("Speed dial")
        } footer: {
            Footnote("Up to eight people, in this order on the bar. Tap one on the bar, then Call, Video or Chat: Teams opens it on this Mac. With more than one work account in Teams, set Call from to your own address in that organisation: Teams then switches to that account first. Deckhand finds the organisation from the address's domain at Microsoft (only the domain is sent). The e-mail addresses stay on this Mac.")
        }
        .onChange(of: settings.teamsContacts) { _ in feed.resolveTenants() }
        Section {
            if CalendarSource.authStatus() != .authorized {
                Text("Deckhand has no access to your calendars. Allow it in System Settings → Privacy & Security → Calendars.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(calendars) { cal in
                    Toggle(isOn: Binding(
                        get: { settings.teamsCalendars.isEmpty || settings.teamsCalendars.contains(cal.id) },
                        set: { on in toggle(cal.id, on: on) })) {
                        HStack(spacing: 6) {
                            Circle().fill(Color(red: cal.rgb.0, green: cal.rgb.1, blue: cal.rgb.2)).frame(width: 9, height: 9)
                            Text(cal.title)
                            Text(cal.source).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Toggle("Also show meetings without a join link (with other people invited)", isOn: $settings.teamsAllMeetings)
            if let s = feed.lastOpened { StatusLabel(s, .ok) }
        } header: {
            Text("Meetings")
        } footer: {
            Footnote("From the calendars on this Mac (add your work accounts in Calendar or System Settings → Internet Accounts), read every minute while Teams is on the bar. Teams, Zoom and Google Meet links are found in the invitation; Join opens them on this Mac. Declined, cancelled and all-day events are left out.")
        }
        .onAppear { calendars = CalendarSource.calendars(); feed.resolveTenants() }
    }

    /// The user's own e-mail accounts on this Mac, as the calendar accounts name them (Exchange and Microsoft 365
    /// accounts are named by their address).
    private var accounts: [String] {
        Array(Set(calendars.map(\.source).filter(Meetings.isEmail))).sorted()
    }

    /// Whether the organisation of a "Call from" address is known: a tick once found, a note when it is not one.
    @ViewBuilder private func accountStatus(_ account: String) -> some View {
        if let domain = Meetings.domain(ofEmail: account) {
            switch feed.tenants[domain] {
            case .some(let t) where !t.isEmpty:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Microsoft 365 organisation found")
            case .some:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("Not a Microsoft 365 organisation; Teams uses its current account")
            case .none:
                ProgressView().controlSize(.small)
            }
        } else if !account.isEmpty {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("Not an e-mail address")
        }
    }

    private func move(_ id: UUID, by step: Int) {
        guard let i = settings.teamsContacts.firstIndex(where: { $0.id == id }), settings.teamsContacts.indices.contains(i + step) else { return }
        settings.teamsContacts.swapAt(i, i + step)
    }

    /// Empty means all calendars; switching one off turns the list into "all the others".
    private func toggle(_ id: String, on: Bool) {
        var set = settings.teamsCalendars.isEmpty ? Set(calendars.map(\.id)) : Set(settings.teamsCalendars)
        if on { set.insert(id) } else { set.remove(id) }
        settings.teamsCalendars = set.count == calendars.count ? [] : calendars.map(\.id).filter { set.contains($0) }
    }
}
