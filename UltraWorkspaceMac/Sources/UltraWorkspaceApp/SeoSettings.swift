import SwiftUI

/// Apps → SEO: the site, the optional PageSpeed key, and the Google sign-in for Search Console.
struct SeoSettings: View {
    @ObservedObject var feed: SiteFeed
    @EnvironmentObject var settings: AppSettings
    @State private var confirmDisconnect = false

    var body: some View {
        Section {
            TextField("Website", text: $settings.seoURL, prompt: Text("https://example.com"))
            if !settings.seoURL.isEmpty && SiteAudit.normalized(settings.seoURL).isEmpty { StatusLabel("Not a web address.", .failed) }
            TimelineView(.periodic(from: .now, by: 5)) { _ in
                VStack(alignment: .leading, spacing: 4) {
                    if let e = feed.auditError { StatusLabel(e, .failed) }
                    if let e = feed.psiError { StatusLabel(e, .attention) }
                    if let d = feed.updatedAt { Text("Updated \(d.formatted(.relative(presentation: .named)))").font(.callout).foregroundStyle(.secondary) }
                    else if !SiteAudit.normalized(settings.seoURL).isEmpty { Text("Checks as soon as SEO is on the bar.").font(.callout).foregroundStyle(.secondary) }
                }
            }
            Button("Check Now") { feed.refreshAll() }.disabled(SiteAudit.normalized(settings.seoURL).isEmpty)
        } header: {
            Text("SEO")
        } footer: {
            Footnote("The page itself is checked every hour, PageSpeed and Search Console every six hours, only while SEO is on the bar.")
        }
        Section {
            SecureField("PageSpeed API key", text: $feed.pageSpeedKey, prompt: Text("AIza…"))
            DetailsDisclosure("How to get it", text: "In the same Google Cloud project as below: APIs & Services → Library → PageSpeed Insights API → Enable, then Credentials → Create credentials → API key. Restrict it to the PageSpeed Insights API. Without a key Google's shared allowance is usually used up.")
        } header: {
            Text("PageSpeed Insights")
        } footer: {
            Footnote("Kept in this Mac's Keychain and sent only to Google.")
        }
        Section {
            TextField("Client ID", text: $feed.clientID, prompt: Text("…apps.googleusercontent.com"))
            SecureField("Client secret", text: $feed.clientSecret, prompt: Text("Paste the secret here"))
            Link("Open Google Cloud Console", destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
            DetailsDisclosure("How to create it", text: "Once, at console.cloud.google.com: create a project; APIs & Services → Library → Google Search Console API → Enable; OAuth consent screen: External, add yourself as a test user, then Publish app so the sign-in does not expire after a week (Google then shows an \"unverified app\" warning, which is fine for your own use); Credentials → Create credentials → OAuth client ID → Desktop app. Paste its Client ID and Client secret here.")
            HStack(spacing: 10) {
                if feed.connecting {
                    BusyLabel("Waiting for you to approve in the browser…")
                    Spacer()
                    Button("Cancel") { feed.cancelConnect() }
                } else if feed.connected {
                    StatusLabel(feed.property.map { "Connected · \($0)" } ?? "Connected", .ok)
                    Spacer()
                    Button("Connect Again") { feed.connect() }.disabled(!feed.hasClient)
                    Button("Disconnect…") { confirmDisconnect = true }
                } else {
                    StatusLabel(feed.hasClient ? "Not connected." : "Enter the Client ID and secret first.", .info)
                    Spacer()
                    Button("Connect Google") { feed.connect() }.disabled(!feed.hasClient)
                }
            }
            if let e = feed.gscError { StatusLabel(e, .failed) }
        } header: {
            Text("Google Search Console")
        } footer: {
            Footnote("Deckhand asks only to view Search Console data. The sign-in and the client stay in this Mac's Keychain; the bar only gets the numbers.")
        }
        .confirmationDialog("Disconnect Google?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { feed.disconnect() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Deckhand revokes its access at Google and forgets it on this Mac. The search numbers on the bar stop updating.") }
    }
}
