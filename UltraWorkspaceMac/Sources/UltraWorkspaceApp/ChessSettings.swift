import SwiftUI
import UltraBarKit

/// Apps → Chess: the Chess.com username and whether the puzzle of the day is shown.
struct ChessSettings: View {
    @ObservedObject var feed: ChessFeed
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Section {
            TextField("Username", text: $settings.chessUser, prompt: Text("Your Chess.com username"))
                .autocorrectionDisabled()
            TimelineView(.periodic(from: .now, by: 5)) { _ in
                VStack(alignment: .leading, spacing: 4) {
                    let typed = settings.chessUser.trimmingCharacters(in: .whitespaces)
                    if !typed.isEmpty, Chess.cleanUsername(typed) == nil { StatusLabel("That isn't a Chess.com username.", .failed) }
                    else if let e = feed.lastError { StatusLabel(e, .failed) }
                    else if let d = feed.updatedAt { StatusLabel([feed.summary, "updated \(d.formatted(.relative(presentation: .named)))"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "), .ok) }
                    else if !typed.isEmpty { Text("Reads as soon as Chess is on the bar.").font(.callout).foregroundStyle(.secondary) }
                }
            }
        } header: {
            Text("Chess.com")
        } footer: {
            Footnote("Chess.com's public data: no password or key, and nothing is sent but the username. Daily games every 90 seconds, ratings every 10 minutes and finished games every 5 minutes, only while Chess is on the bar. Live games show once they are finished; Chess.com doesn't publish games in progress except daily ones.")
        }
        Section {
            Toggle("Show the puzzle of the day", isOn: $settings.chessPuzzle)
            Button("Refresh Now") { feed.refreshNow() }.disabled(Chess.cleanUsername(settings.chessUser) == nil)
        } footer: {
            Footnote("On the bar: tap the board for the next game, a game in the list to show it, a rating for its chart, and the puzzle chip to solve the puzzle by tapping a piece and then its square.")
        }
    }
}
