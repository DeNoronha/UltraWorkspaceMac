import Foundation

/// One entry of the Teletekst rotation: an NOS Teletekst page number ("101") and whether the stories it links to
/// (104, 105, … on the news index) follow it in the rotation.
struct TeletekstEntry: Codable, Equatable, Hashable, Sendable, Identifiable {
    var page: String
    var stories: Bool
    var id: String { page }
}

/// What the Teletekst bar app rotates through, and how fast.
///
/// Kept in `teletekst.json` next to `haven.json` in Deckhand's Application Support folder
/// (`{"pages":[TeletekstEntry…],"interval":20}`) and sent to the bar in the config document (`apps.teletekst`); the bar
/// fetches the pages itself from NOS (teletekst-data.nos.nl, the JSON behind nos.nl/teletekst). Nothing here touches
/// the network: Deckhand only stores the choice.
enum TeletekstPages {
    nonisolated static let maxEntries = 8
    nonisolated static let intervalRange = 8...120
    /// The news index with its stories, the sport index, the weather map and text.
    nonisolated static let defaults = [
        TeletekstEntry(page: "101", stories: true),
        TeletekstEntry(page: "601", stories: false),
        TeletekstEntry(page: "702", stories: false),
    ]
    nonisolated static let defaultInterval = 20

    /// Pages that exist on NOS Teletekst: 100 to 899.
    nonisolated static func isValid(_ page: String) -> Bool { page.range(of: "^[1-8][0-9]{2}$", options: .regularExpression) != nil }

    private struct File: Codable { var pages: [TeletekstEntry]; var interval: Int? }

    nonisolated static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UltraWorkspaceMac", isDirectory: true).appendingPathComponent("teletekst.json")
    }
    /// The rotation (valid pages, once each, at most eight) and seconds per page; the defaults without a file or with an unreadable one.
    nonisolated static func load() -> (entries: [TeletekstEntry], interval: Int) {
        guard let data = try? Data(contentsOf: fileURL), let f = try? JSONDecoder().decode(File.self, from: data) else { return (defaults, defaultInterval) }
        var seen = Set<String>()
        let valid = f.pages.filter { isValid($0.page) && seen.insert($0.page).inserted }
        let interval = min(max(f.interval ?? defaultInterval, intervalRange.lowerBound), intervalRange.upperBound)
        return (valid.isEmpty ? defaults : Array(valid.prefix(maxEntries)), interval)
    }
    /// Writes the choice from Apps → Teletekst; the config feed sends it to the bar within 10 s.
    nonisolated static func save(_ entries: [TeletekstEntry], interval: Int) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(File(pages: Array(entries.prefix(maxEntries)), interval: interval)).write(to: fileURL, options: .atomic)
    }
    /// The `apps.teletekst` section of the bar config.
    nonisolated static func configSection() -> [String: Any] {
        let l = load()
        return ["pages": l.entries.map { ["page": $0.page, "stories": $0.stories] as [String: Any] }, "interval": l.interval]
    }
}
