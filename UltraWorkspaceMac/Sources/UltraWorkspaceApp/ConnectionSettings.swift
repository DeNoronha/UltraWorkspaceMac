import SwiftUI

/// Apps → Connection: the optional ASUS router login (Keychain) and its address.
struct ConnectionSettings: View {
    @ObservedObject var feed: ConnectionFeed
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Section {
            TextField("Address", text: $settings.routerAddress, prompt: Text("The router this Mac uses"))
            TextField("User name", text: $feed.routerUser, prompt: Text("admin"))
            SecureField("Password", text: $feed.routerPassword, prompt: Text("The router's admin password"))
            Toggle("Use HTTPS", isOn: $settings.routerHTTPS)
            TimelineView(.periodic(from: .now, by: 5)) { _ in
                if let e = feed.routerError { StatusLabel(e, .failed) }
                else if let n = feed.routerName { StatusLabel("Connected to \(n)", .ok) }
                else if feed.hasRouterLogin { Text("Reads the router while Connection is on the bar.").font(.callout).foregroundStyle(.secondary) }
            }
            Button("Try Again") { feed.refreshRouter() }.disabled(!feed.hasRouterLogin)
        } header: {
            Text("ASUS router (optional)")
        } footer: {
            Footnote("The admin login of your ASUS router (ZenWiFi, RT-…), the same as in the router's web page or the ASUS app; kept in this Mac's Keychain and sent only to the router, once a minute while Connection is on the bar. With HTTPS the router's own certificate is trusted the first time and only that one afterwards. Without a login the app still measures the whole path.")
        }
        Section {
        } footer: {
            Footnote("Only while Connection is on the bar's screen: Wi-Fi signal every 10 seconds, ten pings to the router, your provider and the internet every 10 seconds, a traceroute every 30 minutes, and one HTTPS request to Microsoft 365, Zoom, Google, GitHub and Apple every minute. No administrator rights and no packet capture.")
        }
    }
}
