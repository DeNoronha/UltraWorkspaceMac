import Foundation

/// The headline sources the Headlines bar app can show. The app fetches them on the bar itself
/// (`android/DeckhandMonitor/.../onbar/Feeds.kt`, which carries the same ids with their feed URLs);
/// Deckhand only offers the choice and sends the id in the config document.
public enum NewsFeed {
    public struct Source: Sendable, Identifiable { public var id: String; public var name: String }
    public static let sources: [Source] = [
        Source(id: "cnn", name: "CNN"),
        Source(id: "bbc", name: "BBC World"),
        Source(id: "nyt", name: "New York Times"),
        Source(id: "guardian", name: "The Guardian"),
        Source(id: "nos", name: "NOS"),
        Source(id: "nu", name: "NU.nl"),
    ]
}
