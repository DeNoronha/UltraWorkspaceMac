import SwiftUI

/// Apps → Training: the athlete's own Strava API application (Client ID and Secret, user-only files on this Mac),
/// Connect / Disconnect, and what the feed last did. The app is called Training on the bar and here because Strava's
/// brand guidelines do not allow "Strava" in an app's name; it says "Powered by Strava" instead.
struct StravaSettings: View {
    @ObservedObject var feed: StravaFeed
    /// Strava's orange for its links ("View on Strava" must be bold, underlined or #FC5200).
    private static let orange = Color(red: 0xFC / 255, green: 0x52 / 255, blue: 0)

    var body: some View {
        Panel("Your Strava API application", footer: "Create it once at strava.com/settings/api: any name without the word Strava, category Visualizer, any website, and Authorization Callback Domain localhost. The Client ID and Client Secret are kept in user-only files on this Mac and only sent to strava.com.") {
            HStack {
                TextField("Client ID", text: $feed.clientID).frame(width: 140)
                SecureField("Client Secret", text: $feed.clientSecret).frame(width: 320)
                Link("Open strava.com/settings/api", destination: URL(string: "https://www.strava.com/settings/api")!).font(.caption)
            }
        }
        Panel("Connection", footer: "Connect opens Strava in your browser, asks to read your activities (scope read,activity:read) and comes back to Deckhand on this Mac (localhost). The tokens stay in a user-only file here; the bar only gets the numbers to show. Deckhand reads every 12 minutes while Training is on the bar, well inside Strava's limits. Year-to-date totals come from Strava's stats, which only count activities visible to Everyone.") {
            HStack(spacing: 10) {
                if feed.connecting {
                    ProgressView().controlSize(.small)
                    Text("Waiting for you to approve in the browser…").font(.caption).foregroundStyle(.secondary)
                    Button("Cancel") { feed.cancelConnect() }
                } else if feed.connected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(feed.tokens.map { $0.firstName.isEmpty ? "Connected" : "Connected as \($0.firstName)" } ?? "Connected")
                    Button("Connect again") { feed.connect() }.disabled(!feed.hasClient)
                    Button("Disconnect") { feed.disconnect() }
                } else {
                    Button("Connect Strava") { feed.connect() }.disabled(!feed.hasClient)
                    Text(feed.hasClient ? "Not connected." : "Enter the Client ID and Secret first.").font(.caption).foregroundStyle(.secondary)
                }
            }
            TimelineView(.periodic(from: .now, by: 5)) { _ in
                VStack(alignment: .leading, spacing: 4) {
                    if let e = feed.lastError { Text(e).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                    if feed.connected {
                        HStack(spacing: 12) {
                            Text(feed.updatedAt.map { "Updated \($0.formatted(.relative(presentation: .named)))" } ?? "Reads as soon as Training is on the bar.")
                            if let u = feed.usage { Text("API use: \(u.short)/\(u.shortLimit) in 15 min, \(u.day)/\(u.dayLimit) today") }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    if let id = feed.latestID, let url = URL(string: "https://www.strava.com/activities/\(id)") {
                        Link(destination: url) { Text("View on Strava").fontWeight(.bold).foregroundStyle(Self.orange) }.font(.caption)
                    }
                }
            }
        }
        Text("Powered by Strava").font(.caption).foregroundStyle(.secondary)
    }
}
