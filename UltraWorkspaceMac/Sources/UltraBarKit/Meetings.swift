import Foundation

/// The pure parts of the Teams bar app: the join link of an online meeting found in a calendar event's URL, location
/// or notes (Teams, Zoom, Google Meet), the Teams desktop app's own links for joining, calling and chatting, and the
/// small things the bar shows (initials, a place without the links in it).
public enum Meetings {
    public enum Kind: String, Sendable { case teams, zoom, meet }

    public struct Link: Equatable, Sendable {
        public var url: URL
        public var kind: Kind
    }

    /// Hosts a join link may be on. Only these are ever opened from a tap on the bar, so an invitation with some other
    /// link in it cannot make the Mac open that.
    static func kind(of url: URL) -> Kind? {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return nil }
        let path = url.path
        if host == "teams.microsoft.com" || host == "teams.live.com" || host == "teams.cloud.microsoft" {
            return path.hasPrefix("/l/meetup-join/") || path.hasPrefix("/meet/") || path.hasPrefix("/l/meet/") ? .teams : nil
        }
        if host == "zoom.us" || host.hasSuffix(".zoom.us") { return path.hasPrefix("/j/") || path.hasPrefix("/my/") ? .zoom : nil }
        if host == "meet.google.com" { return path.count > 3 ? .meet : nil }
        return nil
    }

    /// The first join link in these texts, in order (the event's URL field first, then its location, then its notes).
    /// Outlook writes links in notes as `<https://…>`, and a Teams link may be wrapped by Safe Links
    /// (`…safelinks.protection.outlook.com/?url=<encoded>`); both are understood.
    public static func joinLink(in texts: [String?]) -> Link? {
        for t in texts.compactMap({ $0 }) where !t.isEmpty {
            for raw in candidates(t) {
                guard var url = URL(string: raw) else { continue }
                if let host = url.host?.lowercased(), host.hasSuffix("safelinks.protection.outlook.com"),
                   let inner = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
                   let innerURL = URL(string: inner) { url = innerURL }
                if let k = kind(of: url) { return Link(url: url, kind: k) }
            }
        }
        return nil
    }

    /// Every `https://…` run in a text, ended by white space, a quote or an angle bracket.
    static func candidates(_ text: String) -> [String] {
        var out: [String] = []
        var rest = Substring(text)
        while let r = rest.range(of: "https://", options: .caseInsensitive) {
            let tail = rest[r.lowerBound...]
            let end = tail.firstIndex { $0.isWhitespace || "\"'<>)]".contains($0) } ?? tail.endIndex
            var s = String(tail[..<end])
            while let last = s.last, ".,;".contains(last) { s.removeLast() }
            out.append(s)
            rest = tail[end...]
        }
        return out
    }

    /// The link to open on the Mac: a Teams `https://teams.microsoft.com/l/…` link as `msteams:/l/…` when the Teams app
    /// is installed (it then opens in the app straight away instead of through a browser page), anything else as it is.
    public static func appURL(_ link: Link, teamsInstalled: Bool) -> URL {
        guard teamsInstalled, link.kind == .teams, link.url.host?.lowercased() == "teams.microsoft.com", link.url.path.hasPrefix("/l/"),
              var c = URLComponents(url: link.url, resolvingAgainstBaseURL: false) else { return link.url }
        c.scheme = "msteams"; c.host = nil
        return c.url ?? link.url
    }

    public enum CallMode: String, Sendable, CaseIterable { case audio, video, chat }

    /// A Teams call, video call or chat with one person, by their work e-mail address; nil for something that is not one.
    /// `tenantID` is the organisation to call from when Teams is signed in to more than one: Teams switches to that
    /// account first.
    public static func callURL(email: String, mode: CallMode, teamsInstalled: Bool, tenantID: String? = nil) -> URL? {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEmail(e) else { return nil }
        var c = URLComponents()
        if teamsInstalled { c.scheme = "msteams"; c.path = mode == .chat ? "/l/chat/0/0" : "/l/call/0/0" }
        else { c.scheme = "https"; c.host = "teams.microsoft.com"; c.path = mode == .chat ? "/l/chat/0/0" : "/l/call/0/0" }
        var q = [URLQueryItem(name: "users", value: e)]
        if mode == .video { q.append(URLQueryItem(name: "withVideo", value: "true")) }
        if let t = tenantID, isTenantID(t) { q.append(URLQueryItem(name: "tenantId", value: t.lowercased())) }
        c.queryItems = q
        return c.url
    }

    /// An Entra tenant id: a GUID.
    public static func isTenantID(_ s: String) -> Bool {
        s.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", options: .regularExpression) != nil
    }

    /// The domain of an e-mail address, lower case; nil for something that is not an address.
    public static func domain(ofEmail s: String) -> String? {
        let e = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEmail(e) else { return nil }
        return e.split(separator: "@").last.map { $0.lowercased() }
    }

    /// The tenant id in Microsoft's public OpenID configuration for a domain
    /// (`login.microsoftonline.com/<domain>/v2.0/.well-known/openid-configuration`): the GUID in its `issuer`.
    public static func tenantID(fromOpenIDConfiguration data: Data) -> String? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let issuer = j["issuer"] as? String,
              let u = URL(string: issuer), u.host?.lowercased() == "login.microsoftonline.com" else { return nil }
        return u.pathComponents.first(where: isTenantID).map { $0.lowercased() }
    }

    public static func isEmail(_ s: String) -> Bool {
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix("."),
              s.count <= 254, !s.contains(where: { $0.isWhitespace || "<>\"(),;:\\[]".contains($0) }) else { return false }
        return true
    }

    /// "Anna de Vries" → "AV", "bram" → "B", "Jean-Luc Picard" → "JP".
    public static func initials(_ name: String) -> String {
        let words = name.split { $0.isWhitespace }.map(String.init).filter { w in !["de", "van", "der", "den", "het", "ten", "ter", "von", "da", "di", "le", "la"].contains(w.lowercased()) }
        guard let first = words.first?.first else { return "?" }
        let last = words.count > 1 ? words.last?.first : nil
        return (String(first) + (last.map { String($0) } ?? "")).uppercased()
    }

    /// A meeting's place without the links and the "Microsoft Teams Meeting" boilerplate Outlook puts there; nil when
    /// nothing is left.
    public static func place(_ location: String?) -> String? {
        guard var s = location?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        for c in candidates(s) { s = s.replacingOccurrences(of: c, with: "") }
        for noise in ["Microsoft Teams Meeting", "Microsoft Teams-vergadering", "Microsoft Teams Meeting;", "Zoom Meeting", "Google Meet"] {
            s = s.replacingOccurrences(of: noise, with: "", options: .caseInsensitive)
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ;,<>").union(.whitespacesAndNewlines))
        return s.isEmpty ? nil : s
    }

    /// A short, stable key for an event (the bar sends it back to join): FNV-1a of its identifier and start, 16 hex digits.
    public static func key(id: String, start: Date) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in Array((id + "|" + String(Int(start.timeIntervalSince1970))).utf8) { h ^= UInt64(b); h = h &* 0x100_0000_01b3 }
        return String(format: "%016llx", h)
    }
}
