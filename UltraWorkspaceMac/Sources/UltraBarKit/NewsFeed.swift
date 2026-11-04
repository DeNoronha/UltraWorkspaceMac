import Foundation

/// Headlines from an RSS feed (CNN by default; a few others to pick from). Plain Foundation XMLParser.
public enum NewsFeed {
    public enum Kind: Sendable { case rss, cnnLite }
    public struct Source: Sendable, Identifiable { public var id: String; public var name: String; public var url: String; public var kind: Kind = .rss }
    /// CNN's RSS feeds stopped updating in 2023/2024 (checked 2026-11-04), so CNN comes from lite.cnn.com,
    /// CNN's own text-only front page: an ordered list of the current headlines, each with a dated URL.
    public static let sources: [Source] = [
        Source(id: "cnn", name: "CNN", url: "https://lite.cnn.com/", kind: .cnnLite),
        Source(id: "bbc", name: "BBC World", url: "https://feeds.bbci.co.uk/news/world/rss.xml"),
        Source(id: "nyt", name: "New York Times", url: "https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml"),
        Source(id: "guardian", name: "The Guardian", url: "https://www.theguardian.com/world/rss"),
        Source(id: "nos", name: "NOS", url: "https://feeds.nos.nl/nosnieuwsalgemeen"),
        Source(id: "nu", name: "NU.nl", url: "https://www.nu.nl/rss/Algemeen"),
    ]
    public static func source(_ id: String) -> Source { sources.first { $0.id == id } ?? sources[0] }

    public struct Item: Sendable {
        public var title: String; public var link: String
        /// Exact publication time (RSS), or nil.
        public var date: Date?
        public var summary: String
        /// Publication day only (CNN lite), when no exact time is known.
        public var day: Date? = nil
    }

    public static func fetch(_ source: Source, limit: Int = 12) async throws -> [Item] {
        guard let url = URL(string: source.url) else { return [] }
        var req = URLRequest(url: url); req.timeoutInterval = 15
        req.setValue("Deckhand/1.3 (+https://denoronha.github.io/UltraWorkspaceMac/)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        switch source.kind {
        case .rss: return Array(parse(data).prefix(limit))
        case .cnnLite: return Array(parseCNNLite(String(decoding: data, as: UTF8.self)).prefix(limit))
        }
    }

    /// `<li class="card--lite"><a href="/2026/11/04/section/slug">Headline</a></li>`, in CNN's order.
    /// The date in the path is the publication day; items older than two days are left out.
    public static func parseCNNLite(_ html: String, now: Date = Date()) -> [Item] {
        guard let re = try? NSRegularExpression(pattern: #"<li class="card--lite">\s*<a href="([^"]+)">\s*([^<]+?)\s*</a>"#) else { return [] }
        let ns = html as NSString
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = TimeZone(identifier: "America/New_York"); df.dateFormat = "yyyy/MM/dd"
        var out: [Item] = []
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let path = ns.substring(with: m.range(at: 1)), title = unescape(ns.substring(with: m.range(at: 2)))
            var date: Date? = nil
            if let dm = path.range(of: #"^/(\d{4}/\d{2}/\d{2})/"#, options: .regularExpression) {
                date = df.date(from: String(path[dm]).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                if let d = date, now.timeIntervalSince(d) > 2 * 86400 { continue }
            }
            out.append(Item(title: title, link: path.hasPrefix("http") ? path : "https://lite.cnn.com" + path, date: nil, summary: "", day: date))
        }
        return out
    }

    static func unescape(_ s: String) -> String {
        var t = s
        for (a, b) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] { t = t.replacingOccurrences(of: a, with: b) }
        return t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parse an RSS 2.0 (or Atom) document into items, in document order.
    public static func parse(_ data: Data) -> [Item] {
        let p = Parser()
        let x = XMLParser(data: data); x.delegate = p; x.parse()
        return p.items
    }

    private final class Parser: NSObject, XMLParserDelegate {
        var items: [Item] = []
        private var inItem = false
        private var field: String?
        private var cur: [String: String] = [:]
        private let rfc822: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"; return f }()
        private let rfc822b: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"; return f }()
        private let iso = ISO8601DateFormatter()

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "item" || name == "entry" { inItem = true; cur = [:]; return }
            guard inItem else { return }
            if name == "link", let href = attributes["href"], cur["link"] == nil { cur["link"] = href } // Atom
            field = name
        }
        func parser(_ parser: XMLParser, foundCharacters s: String) { append(s) }
        func parser(_ parser: XMLParser, foundCDATA d: Data) { append(String(decoding: d, as: UTF8.self)) }
        private func append(_ s: String) { guard inItem, let f = field else { return }; cur[f, default: ""] += s }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "item" || name == "entry" {
                inItem = false
                let title = clean(cur["title"] ?? "")
                guard !title.isEmpty else { return }
                let dateText = (cur["pubDate"] ?? cur["published"] ?? cur["updated"] ?? cur["dc:date"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let date = rfc822.date(from: dateText) ?? rfc822b.date(from: dateText) ?? iso.date(from: dateText)
                items.append(Item(title: title, link: (cur["link"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines), date: date, summary: clean(cur["description"] ?? cur["summary"] ?? "")))
                return
            }
            field = nil
        }
        private func clean(_ s: String) -> String {
            var t = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            for (a, b) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] { t = t.replacingOccurrences(of: a, with: b) }
            return t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
