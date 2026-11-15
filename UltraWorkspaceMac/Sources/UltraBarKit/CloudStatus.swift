import Foundation

/// The services the Cloud Status bar app knows (the bar fetches them itself, `onbar/StatusFeed.kt`; keep the two lists
/// in step), and the cleaning of the user's choice before it goes to the bar as `apps.status.services`.
public enum CloudStatus {
    public struct Service: Equatable, Sendable {
        public let id: String
        public let name: String
        /// The public status page it is read from, for the settings list.
        public let host: String
    }

    public static let known: [Service] = [
        Service(id: "m365", name: "Microsoft 365", host: "status.cloud.microsoft"),
        Service(id: "azure", name: "Azure", host: "azure.status.microsoft"),
        Service(id: "aws", name: "AWS", host: "status.aws.amazon.com"),
        Service(id: "gcp", name: "Google Cloud", host: "status.cloud.google.com"),
        Service(id: "workspace", name: "Google Workspace", host: "google.com/appsstatus"),
        Service(id: "github", name: "GitHub", host: "githubstatus.com"),
        Service(id: "cloudflare", name: "Cloudflare", host: "cloudflarestatus.com"),
        Service(id: "slack", name: "Slack", host: "status.slack.com"),
        Service(id: "zoom", name: "Zoom", host: "zoomstatus.com"),
        Service(id: "atlassian", name: "Atlassian", host: "status.atlassian.com"),
        Service(id: "claude", name: "Claude", host: "status.claude.com"),
        Service(id: "openai", name: "OpenAI", host: "status.openai.com"),
        Service(id: "digitalocean", name: "DigitalOcean", host: "status.digitalocean.com"),
        Service(id: "vercel", name: "Vercel", host: "vercel-status.com"),
        Service(id: "netlify", name: "Netlify", host: "netlifystatus.com"),
        Service(id: "npm", name: "npm", host: "status.npmjs.org"),
    ]

    /// The bar shows at most this many (4 × 3 tiles).
    public static let maxServices = 12

    public static let defaults = ["m365", "azure", "aws", "gcp", "workspace", "github", "cloudflare", "slack", "zoom", "atlassian", "claude", "openai"]

    /// Known ids only, once each, at most twelve; nil or nothing left gives the defaults.
    public static func sanitize(_ ids: [String]?) -> [String] {
        guard let ids else { return defaults }
        let valid = Set(known.map(\.id))
        var seen = Set<String>(), out: [String] = []
        for raw in ids {
            let id = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard valid.contains(id), seen.insert(id).inserted else { continue }
            out.append(id)
            if out.count == maxServices { break }
        }
        return out.isEmpty ? defaults : out
    }

    /// `ids` with `id` switched on or off, kept in the order of `known` so the bar's order does not depend on the
    /// order of clicks; switching on beyond the maximum, or the last one off, changes nothing.
    public static func toggled(_ ids: [String], _ id: String, on: Bool) -> [String] {
        var set = Set(sanitize(ids))
        if on { guard set.count < maxServices else { return sanitize(ids) }; set.insert(id) }
        else { guard set.count > 1 else { return sanitize(ids) }; set.remove(id) }
        return known.map(\.id).filter { set.contains($0) }
    }
}
