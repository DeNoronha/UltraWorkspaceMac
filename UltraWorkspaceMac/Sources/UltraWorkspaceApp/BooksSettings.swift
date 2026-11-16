import SwiftUI

/// Apps → Books: the e-Boekhouden API token (Keychain) and whether the bar hides the amounts until tapped.
struct BooksSettings: View {
    @ObservedObject var feed: BooksFeed
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Section {
            SecureField("API token", text: $feed.token, prompt: Text("Paste the token here"))
            DetailsDisclosure("How to make an API token", text: "Sign in at e-boekhouden.nl and open your account's settings, where API tokens are managed. Create a token named Deckhand and copy it here; e-Boekhouden shows it only once. Deckhand only reads balances and open invoices and never books anything.")
            TimelineView(.periodic(from: .now, by: 5)) { _ in
                VStack(alignment: .leading, spacing: 4) {
                    if let e = feed.lastError { StatusLabel(e, .failed) }
                    else if let d = feed.updatedAt {
                        StatusLabel([feed.company, "updated \(d.formatted(.relative(presentation: .named)))"].compactMap { $0 }.joined(separator: " · "), .ok)
                    } else if feed.hasToken { Text("Reads as soon as Books is on the bar.").font(.callout).foregroundStyle(.secondary) }
                }
            }
            Button("Refresh Now") { feed.refreshNow() }.disabled(!feed.hasToken)
        } header: {
            Text("e-Boekhouden")
        } footer: {
            Footnote("Kept in this Mac's Keychain and sent only to e-Boekhouden. Every 15 minutes while Books is on the bar; the bar gets the totals and the largest open invoices, never the token.")
        }
        Section {
            Toggle("Hide amounts until tapped", isOn: $settings.booksHide)
        } footer: {
            Footnote("For a desk others can see, or a video call: the bar shows dots instead of amounts, and a tap shows them for 30 seconds.")
        }
    }
}
