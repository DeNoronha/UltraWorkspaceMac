import SwiftUI

/// Apps → Jira Board: the Atlassian site, the e-mail and API token (Keychain), the board, and whose cards to show.
struct JiraSettings: View {
    @ObservedObject var feed: JiraFeed
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Section {
            TextField("Site", text: $settings.jiraSite, prompt: Text("yourcompany.atlassian.net"))
            CredentialRow("E-mail", value: $feed.email, secret: false, prompt: "you@company.com", status: .from(error: feed.lastError, working: feed.displayName != nil))
            CredentialRow("API token", value: $feed.token, status: .from(error: feed.lastError, working: feed.displayName != nil))
            DetailsDisclosure("How to make an API token", text: "Sign in at id.atlassian.com → Security → Create and manage API tokens → Create API token. Name it Deckhand and copy it here. Deckhand only reads boards and cards and never changes anything in Jira.")
            TimelineView(.periodic(from: .now, by: 5)) { _ in
                VStack(alignment: .leading, spacing: 4) {
                    if let e = feed.lastError { StatusLabel(e, .failed) }
                    else if let name = feed.displayName {
                        StatusLabel(signedIn(name), .ok)
                    } else if feed.hasToken && !settings.jiraSite.isEmpty && feed.host == nil {
                        StatusLabel("Enter the site as yourcompany.atlassian.net.", .failed)
                    } else if feed.configured { Text("Signing in…").font(.callout).foregroundStyle(.secondary) }
                }
            }
        } header: {
            Text("Atlassian")
        } footer: {
            Footnote("Kept in this Mac's Keychain and sent only to your Atlassian site. The bar gets the column names and card titles, never the token.")
        }
        Section {
            Picker("Board", selection: $settings.jiraBoard) {
                Text(feed.boards.isEmpty ? "No boards yet" : "Choose a board").tag(0)
                ForEach(feed.boards) { b in Text(b.project.isEmpty ? b.name : "\(b.name) (\(b.project))").tag(b.id) }
                // The chosen board before the list has loaded, so the picker never shows an empty selection.
                if settings.jiraBoard != 0 && !feed.boards.contains(where: { $0.id == settings.jiraBoard }) {
                    Text("Chosen board").tag(settings.jiraBoard)
                }
            }
            .disabled(!feed.configured)
            Picker("Show cards", selection: $settings.jiraOnlyMine) {
                Text("All").tag(false)
                Text("Only mine").tag(true)
            }
            Button("Refresh Now") { feed.refreshNow() }.disabled(!feed.configured)
        } footer: {
            Footnote("Every 2 minutes while Jira Board is on the bar. On a scrum board the open sprint; on a kanban board the open cards and what was done in the last 14 days.")
        }
        .onAppear { feed.settingsOpened() }
        .onChange(of: settings.jiraSite) { _ in feed.settingsOpened() }
    }

    private func signedIn(_ name: String) -> String {
        var parts = ["Signed in as \(name)"]
        if feed.columnCount > 0 { parts.append("\(feed.columnCount) column\(feed.columnCount == 1 ? "" : "s")") }
        if let d = feed.updatedAt { parts.append("updated \(d.formatted(.relative(presentation: .named)))") }
        return parts.joined(separator: " · ")
    }
}
