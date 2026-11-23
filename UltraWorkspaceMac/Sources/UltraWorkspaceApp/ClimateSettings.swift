import SwiftUI

/// Apps → Climate: the tado sign-in (device code) and the Netatmo connection (the user's own Netatmo app).
struct ClimateSettings: View {
    @ObservedObject var feed: ClimateFeed
    @State private var confirmTado = false
    @State private var confirmNetatmo = false
    @State private var refreshToken = ""

    var body: some View {
        Section {
            HStack(spacing: 10) {
                if feed.tadoConnecting {
                    if let code = feed.tadoUserCode {
                        BusyLabel("Approve code \(code) in the browser…")
                    } else { BusyLabel("Asking tado…") }
                    Spacer()
                    if let link = feed.tadoLink { Link("Open Page", destination: link) }
                    Button("Cancel") { feed.cancelTadoConnect() }
                } else if feed.tadoConnected {
                    StatusLabel(feed.homeName.map { "Connected · \($0)" } ?? "Connected", .ok)
                    Spacer()
                    Button("Disconnect…") { confirmTado = true }
                } else {
                    StatusLabel("Not connected.", .info)
                    Spacer()
                    Button("Connect tado") { feed.connectTado() }
                }
            }
            if let e = feed.tadoError { StatusLabel(e, .failed) }
            if let left = feed.callsLeft { Text("\(left) tado calls left today.").font(.callout).foregroundStyle(.secondary) }
        } header: {
            Text("tado heating")
        } footer: {
            Footnote("You approve Deckhand on tado's own page; Deckhand never sees your password. The sign-in stays in this Mac's Keychain. Without Auto-Assist tado allows about 100 calls a day, so Deckhand reads the heating every 30 minutes while Climate is on the bar and keeps calls free for your taps.")
        }
        .confirmationDialog("Disconnect tado?", isPresented: $confirmTado, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { feed.disconnectTado() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Deckhand forgets the sign-in on this Mac. The heating can no longer be set from the bar.") }

        Section {
            CredentialRow("Client ID", value: $feed.netatmoClientID, secret: false, status: .from(error: feed.netatmoError, working: feed.netatmoConnected))
            CredentialRow("Client secret", value: $feed.netatmoClientSecret, status: .from(error: feed.netatmoError, working: feed.netatmoConnected))
            Link("Open Netatmo Connect", destination: URL(string: "https://dev.netatmo.com/apps/")!)
            DetailsDisclosure("How to create it", text: "Once, at dev.netatmo.com: sign in with your Netatmo account → My apps → Create. Give it a name (Deckhand) and a description, leave Redirect URI and Webhook URI empty, and save. Copy its Client ID and Client secret here, then press Connect Netatmo.")
            HStack(spacing: 10) {
                if feed.netatmoConnecting {
                    BusyLabel("Waiting for you to approve in the browser…")
                    Spacer()
                    Button("Cancel") { feed.cancelNetatmoConnect() }
                } else if feed.netatmoConnected {
                    StatusLabel(feed.stationName.map { "Connected · \($0)" } ?? "Connected", .ok)
                    Spacer()
                    Button("Disconnect…") { confirmNetatmo = true }
                } else {
                    StatusLabel(feed.netatmoHasClient ? "Not connected." : "Enter the Client ID and secret first.", .info)
                    Spacer()
                    Button("Connect Netatmo") { feed.connectNetatmo() }.disabled(!feed.netatmoHasClient)
                }
            }
            if let e = feed.netatmoError { StatusLabel(e, .failed) }
            if !feed.netatmoConnected {
                DisclosureGroup("Connect with a token instead") {
                    Text("If the browser sign-in fails: on your app's page at dev.netatmo.com, under Token generator, choose the scope read_station, generate a token and paste its refresh token here.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        SecureField("Refresh token", text: $refreshToken, prompt: Text("Paste the refresh token here"))
                        Button("Use") { feed.useNetatmoRefreshToken(refreshToken); refreshToken = "" }
                            .disabled(refreshToken.trimmingCharacters(in: .whitespaces).isEmpty || !feed.netatmoHasClient)
                    }
                }
            }
        } header: {
            Text("Netatmo weather station")
        } footer: {
            Footnote("Deckhand asks only to read the station. The app and the sign-in stay in this Mac's Keychain; the bar only gets the readings.")
        }
        .confirmationDialog("Disconnect Netatmo?", isPresented: $confirmNetatmo, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { feed.disconnectNetatmo() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Deckhand forgets the access on this Mac. Remove it fully at my.netatmo.com → Settings → Third-party apps.") }

        Section {
            TimelineView(.periodic(from: .now, by: 5)) { _ in
                if let d = feed.updatedAt { Text("Updated \(d.formatted(.relative(presentation: .named)))").font(.callout).foregroundStyle(.secondary) }
                else { Text("Reads as soon as Climate is on the bar.").font(.callout).foregroundStyle(.secondary) }
            }
            Button("Refresh Now") { feed.refreshNow() }.disabled(!feed.tadoConnected && !feed.netatmoConnected)
        } footer: {
            Footnote("On the bar, tap a temperature to heat the house for the chosen time or until the schedule's next change; tado then returns to the schedule by itself.")
        }
    }
}
