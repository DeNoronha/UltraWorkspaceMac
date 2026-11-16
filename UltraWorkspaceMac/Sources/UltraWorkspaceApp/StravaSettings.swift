import SwiftUI

/// Apps → Training: the athlete's own Strava API application (Client ID and Secret, in the Keychain on this Mac),
/// Connect / Disconnect, and what the feed last did. The app is called Training on the bar and here because Strava's
/// brand guidelines do not allow "Strava" in an app's name; it says "Powered by Strava" instead.
struct StravaSettings: View {
    @ObservedObject var feed: StravaFeed
    /// Strava's orange for its links ("View on Strava" must be bold, underlined or #FC5200).
    private static let orange = Color(red: 0xFC / 255, green: 0x52 / 255, blue: 0)

    @State private var confirmDisconnect = false

    var body: some View {
        Section {
            TextField("Client ID", text: $feed.clientID, prompt: Text("From strava.com/settings/api"))
            SecureField("Client secret", text: $feed.clientSecret, prompt: Text("Paste the secret here"))
            Link("Open strava.com/settings/api", destination: URL(string: "https://www.strava.com/settings/api")!)
            DetailsDisclosure("How to create it", text: "Create an API application once at strava.com/settings/api: any name without the word Strava, category Visualizer, any website, and Authorization Callback Domain localhost.")
        } header: {
            Text("Your Strava API application")
        } footer: {
            Footnote("Kept in this Mac's Keychain and sent only to strava.com.")
        }
        Section {
            HStack(spacing: 10) {
                if feed.connecting {
                    BusyLabel("Waiting for you to approve in the browser…")
                    Spacer()
                    Button("Cancel") { feed.cancelConnect() }
                } else if feed.connected {
                    StatusLabel(feed.tokens.map { $0.firstName.isEmpty ? "Connected" : "Connected as \($0.firstName)" } ?? "Connected", .ok)
                    Spacer()
                    Button("Connect Again") { feed.connect() }.disabled(!feed.hasClient)
                    Button("Disconnect…") { confirmDisconnect = true }
                } else {
                    StatusLabel(feed.hasClient ? "Not connected." : "Enter the Client ID and secret first.", .info)
                    Spacer()
                    Button("Connect Strava") { feed.connect() }.disabled(!feed.hasClient)
                }
            }
            // All three are published; the timeline only keeps "Updated 3 minutes ago" current.
            if feed.lastError != nil || feed.connected || feed.latestID != nil {
            TimelineView(.periodic(from: .now, by: 5)) { _ in
                VStack(alignment: .leading, spacing: 4) {
                    if let e = feed.lastError { StatusLabel(e, .failed) }
                    if feed.connected {
                        Text(feed.updatedAt.map { "Updated \($0.formatted(.relative(presentation: .named)))" } ?? "Reads as soon as Training is on the bar.")
                            .font(.callout).foregroundStyle(.secondary)
                        if let u = feed.usage { Text("API use: \(u.short)/\(u.shortLimit) in 15 min, \(u.day)/\(u.dayLimit) today").font(.callout).foregroundStyle(.secondary) }
                    }
                    if let id = feed.latestID, let url = URL(string: "https://www.strava.com/activities/\(id)") {
                        Link(destination: url) { Text("View on Strava").fontWeight(.bold).foregroundStyle(Self.orange) }
                    }
                }
            }
            }
        } header: {
            Text("Connection")
        } footer: {
            Footnote("Powered by Strava. Connect asks Strava to let Deckhand read your activities; the bar only gets the numbers.")
        }
        .confirmationDialog("Disconnect Strava?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { feed.disconnect() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Deckhand revokes its access at Strava and forgets it on this Mac. Training on the bar stops updating.") }
    }
}
