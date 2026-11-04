import Foundation

/// A Bible verse for the day: a fixed list of well-known passages, one per day of the year, with the text
/// fetched from bible-api.com in the World English Bible (public domain, so it can be shown anywhere).
public enum DailyVerse {
    public struct Verse: Sendable { public var reference: String; public var text: String; public var translation: String }

    public static let references: [String] = [
        "John 3:16", "Psalm 23:1-4", "Philippians 4:6-7", "Proverbs 3:5-6", "Isaiah 41:10", "Romans 8:28", "Jeremiah 29:11",
        "Matthew 11:28-30", "Psalm 46:1", "Joshua 1:9", "Psalm 119:105", "Romans 12:2", "1 Corinthians 13:4-7", "Galatians 5:22-23",
        "Hebrews 11:1", "Philippians 4:13", "Psalm 27:1", "Matthew 6:33-34", "Isaiah 40:31", "2 Timothy 1:7", "Psalm 37:4-5",
        "Proverbs 16:3", "Romans 15:13", "Ephesians 2:8-10", "1 Peter 5:7", "Psalm 139:13-14", "Micah 6:8", "John 14:27",
        "Lamentations 3:22-23", "Psalm 118:24", "James 1:5", "Colossians 3:23-24", "Deuteronomy 31:6", "Psalm 121:1-2",
        "Matthew 5:14-16", "1 John 4:7-8", "Isaiah 26:3", "Romans 5:8", "Psalm 100:4-5", "Proverbs 18:10", "Ephesians 4:32",
        "John 16:33", "Psalm 34:8", "Philippians 1:6", "Hebrews 13:8", "2 Corinthians 5:17", "Psalm 91:1-2", "Matthew 7:7-8",
        "Nahum 1:7", "1 Thessalonians 5:16-18", "Psalm 19:1", "Romans 8:38-39", "Proverbs 22:6", "John 15:5", "Psalm 51:10",
        "Isaiah 43:2", "Galatians 6:9", "Psalm 103:2-4", "Matthew 28:19-20", "Ecclesiastes 3:1", "Hebrews 4:16", "Psalm 16:11",
        "James 1:2-4", "1 Corinthians 10:13", "Psalm 62:1-2", "Zephaniah 3:17", "John 8:12", "Ephesians 6:10-11", "Psalm 90:12",
        "Proverbs 4:23", "Romans 12:12", "Psalm 56:3", "Matthew 22:37-39", "Isaiah 55:8-9", "Colossians 3:2", "Psalm 32:8",
        "Luke 1:37", "2 Chronicles 7:14", "Psalm 145:18", "Titus 3:5", "John 10:10", "Habakkuk 3:17-18", "Psalm 4:8",
        "Proverbs 15:1", "Mark 12:30-31", "1 John 1:9", "Psalm 73:26", "Revelation 21:4", "Matthew 19:26", "Psalm 147:3",
        "Isaiah 9:6", "Luke 6:31", "Psalm 150:6", "Romans 10:9", "Proverbs 17:17", "Acts 1:8", "Psalm 143:8", "John 1:5",
    ]

    /// The reference for a day (deterministic: day of year plus the year, so the sequence shifts each year).
    public static func reference(for date: Date, calendar: Calendar = .current) -> String {
        let doy = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
        let year = calendar.component(.year, from: date)
        return references[(doy + year * 97) % references.count]
    }

    public static func fetch(reference: String) async throws -> Verse {
        let q = reference.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? reference
        let url = URL(string: "https://bible-api.com/\(q)?translation=web")!
        var req = URLRequest(url: url); req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw URLError(.cannotParseResponse) }
        let verses = (obj["verses"] as? [[String: Any]]) ?? []
        let text = verses.compactMap { $0["text"] as? String }.joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw URLError(.cannotParseResponse) }
        return Verse(reference: (obj["reference"] as? String) ?? reference, text: text, translation: "World English Bible")
    }
}
