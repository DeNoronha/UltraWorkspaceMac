import SwiftUI

/// Apps → Portfolio: the Kraken key (read-only), the currency and which small holdings to leave out.
struct PortfolioSettings: View {
    @ObservedObject var feed: KrakenFeed
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Section {
            CredentialRow("API key", value: $feed.apiKey, prompt: "From Kraken → Settings → API", status: .from(error: feed.lastError, working: feed.updatedAt != nil))
            CredentialRow("Private key", value: $feed.apiSecret, status: .from(error: feed.lastError, working: feed.updatedAt != nil))
            DetailsDisclosure("How to make a read-only key", text: "At kraken.com: Settings → Connections & API → Create API key. Name it Deckhand and tick only Funds → Query. Leave every other permission off: Deckhand only reads your balances and can then never trade, deposit or withdraw. Copy the API key and the private key here; Kraken shows the private key only once.")
            TimelineView(.periodic(from: .now, by: 5)) { _ in
                VStack(alignment: .leading, spacing: 4) {
                    if let e = feed.lastError { StatusLabel(e, .failed) }
                    else if let d = feed.updatedAt { StatusLabel("\(feed.coinCount) coin\(feed.coinCount == 1 ? "" : "s") · updated \(d.formatted(.relative(presentation: .named)))", .ok) }
                    else if feed.hasKey { Text("Reads as soon as Portfolio is on the bar.").font(.callout).foregroundStyle(.secondary) }
                }
            }
        } header: {
            Text("Kraken")
        } footer: {
            Footnote("Kept in this Mac's Keychain and sent only to Kraken. The bar gets the amounts and values, never the key.")
        }
        Section {
            Picker("Currency", selection: $settings.portfolioCurrency) {
                ForEach(["EUR", "USD", "GBP", "CHF"], id: \.self) { Text($0).tag($0) }
            }
            Picker("Show coins worth at least", selection: $settings.portfolioMinValue) {
                ForEach([0.0, 1, 10, 100], id: \.self) { v in Text(v == 0 ? "Everything" : "\(settings.portfolioCurrency) \(Int(v))").tag(v) }
            }
            Button("Refresh Now") { feed.refreshNow() }.disabled(!feed.hasKey)
        } footer: {
            Footnote("Balances every 5 minutes, prices every 30 seconds, while Portfolio is on the bar. The line shows how today's holdings moved, not your past trades.")
        }
    }
}
