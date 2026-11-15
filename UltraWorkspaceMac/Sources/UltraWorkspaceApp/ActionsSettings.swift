import SwiftUI

/// Apps → GitHub Actions: the fine-grained token (Actions read-only), how many days back, and whether forks count.
struct ActionsSettings: View {
    @ObservedObject var feed: ActionsFeed
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Section {
            SecureField("Token", text: $feed.token, prompt: Text("github_pat_…"))
            DetailsDisclosure("How to make a token", text: "At github.com: Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token. Name it Deckhand, choose an expiry, set Repository access to All repositories, and under Repository permissions set only Actions to Read-only. GitHub adds Metadata read-only by itself. Deckhand can then see your workflow runs and nothing else.")
            TimelineView(.periodic(from: .now, by: 5)) { _ in
                VStack(alignment: .leading, spacing: 4) {
                    if let e = feed.lastError { StatusLabel(e, .failed) }
                    else if let d = feed.updatedAt { StatusLabel("\(feed.repoCount) repositor\(feed.repoCount == 1 ? "y" : "ies") · updated \(d.formatted(.relative(presentation: .named)))", .ok) }
                    else if feed.hasToken { Text("Reads as soon as GitHub Actions is on the bar.").font(.callout).foregroundStyle(.secondary) }
                }
            }
        } header: {
            Text("GitHub")
        } footer: {
            Footnote("Kept in this Mac's Keychain and sent only to GitHub. The bar gets the run names and results, never the token.")
        }
        Section {
            Picker("Show runs from the last", selection: $settings.actionsDays) {
                ForEach([1, 3, 7, 14], id: \.self) { d in Text(d == 1 ? "Day" : "\(d) days").tag(d) }
            }
            Toggle("Include forks", isOn: $settings.actionsForks)
            Button("Refresh Now") { feed.refreshNow() }.disabled(!feed.hasToken)
        } footer: {
            Footnote("Every minute while a run is going, otherwise every 3 minutes, and only while GitHub Actions is on the bar. Up to 30 repositories you pushed to recently.")
        }
    }
}
