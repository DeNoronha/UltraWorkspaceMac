import Foundation
import AppKit
import EventKit
import UltraBarKit

/// A person on the Teams app's speed dial: a name for the bar, the work e-mail address Teams knows them by, and the
/// user's own account to call them from (empty: whichever account Teams is on).
struct TeamsContact: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var email: String
    var account: String = ""

    init(name: String, email: String, account: String = "") { self.name = name; self.email = email; self.account = account }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        account = try c.decodeIfPresent(String.self, forKey: .account) ?? ""
    }
}

/// The Teams bar app's data: the next meetings from this Mac's calendars (Apple Calendar, so the Exchange or Microsoft
/// 365 accounts added there, any tenant, no sign-in of Deckhand's own) with their join links, and the speed-dial
/// contacts. A tap on the bar sends back only a meeting's key or a contact's number; Deckhand looks up the link or the
/// address itself and opens it in Teams (or Zoom, or Meet) on this Mac, where the headset and camera are. The bar never
/// gets a link or an e-mail address. Calendar read every minute while the app is on the bar; kept in memory only.
@MainActor
final class TeamsFeed: ObservableObject {
    @Published private(set) var updatedAt: Date?
    @Published private(set) var lastOpened: String?

    struct Meeting: Sendable {
        var key: String
        var title: String
        var start: Date
        var end: Date
        var link: Meetings.Link?
        var place: String?
        var calendar: String
        var color: String
    }

    private var calendars: () -> [String] = { [] }
    private var allMeetings: () -> Bool = { true }
    private var contacts: () -> [TeamsContact] = { [] }
    private var meetings: [Meeting] = []
    /// Domain → Entra tenant id, looked up once per domain from Microsoft's public OpenID configuration.
    @Published private(set) var tenants: [String: String] = [:]
    private var looking: Set<String> = []
    private var loop: Task<Void, Never>?
    private let wake = WakeSignal()

    func start(calendars: @escaping @MainActor () -> [String], allMeetings: @escaping @MainActor () -> Bool,
               contacts: @escaping @MainActor () -> [TeamsContact], wanted: @escaping @MainActor () -> Bool) {
        self.calendars = calendars; self.allMeetings = allMeetings; self.contacts = contacts
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let active = wanted()
                if active { await self.refresh() }
                await self.wake.wait(active ? 60 : 600) { wanted() != active }
            }
        }
    }
    func stop() { loop?.cancel(); loop = nil }
    func poke() { wake.signal() }

    private func refresh() async {
        let ids = calendars(), all = allMeetings()
        meetings = await Task.detached(priority: .utility) { Self.query(calendarIDs: ids, includeOffline: all) }.value
        updatedAt = Date()
        resolveTenants()
    }

    /// The tenants of the accounts the contacts are called from. Only the domain is sent, to Microsoft's public sign-in
    /// configuration; nothing about the contacts. A domain that is not an Entra tenant is remembered as such ("").
    func resolveTenants() {
        let domains = Set(contacts().compactMap { Meetings.domain(ofEmail: $0.account) }).subtracting(tenants.keys).subtracting(looking)
        for domain in domains {
            looking.insert(domain)
            Task { [weak self] in
                var tid = ""
                if let url = URL(string: "https://login.microsoftonline.com/\(domain)/v2.0/.well-known/openid-configuration") {
                    var req = URLRequest(url: url, timeoutInterval: 15)
                    req.setValue("Deckhand (+https://openbarx.com/)", forHTTPHeaderField: "User-Agent")
                    guard let (data, resp) = try? await URLSession.shared.data(for: req) else {
                        await MainActor.run { _ = self?.looking.remove(domain) }; return     // offline: try again later
                    }
                    if (resp as? HTTPURLResponse)?.statusCode == 200 { tid = Meetings.tenantID(fromOpenIDConfiguration: data) ?? "" }
                }
                await MainActor.run { guard let self else { return }; self.looking.remove(domain); self.tenants[domain] = tid }
            }
        }
    }

    /// Timed events that have not ended, from four hours ago (so a meeting that is on now is there) to 36 hours ahead.
    /// Left out: all-day events, cancelled ones, ones the user declined, events without a join link that are free time or
    /// have nobody else invited, and the second copy of an invitation that is in two calendars.
    nonisolated static func query(calendarIDs: [String], includeOffline: Bool) -> [Meeting] {
        guard CalendarSource.authStatus() == .authorized else { return [] }
        let store = EKEventStore(), now = Date()
        let chosen = calendarIDs.isEmpty ? nil : store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        if let chosen, chosen.isEmpty { return [] }
        let events = store.events(matching: store.predicateForEvents(withStart: now.addingTimeInterval(-4 * 3600), end: now.addingTimeInterval(36 * 3600), calendars: chosen))
        var out: [Meeting] = []
        for ev in events.sorted(by: { $0.startDate < $1.startDate }) {
            guard !ev.isAllDay, let start = ev.startDate, let end = ev.endDate, end > now, ev.status != .canceled else { continue }
            let title = ev.title ?? "Untitled"
            if title.lowercased().hasPrefix("canceled:") || title.lowercased().hasPrefix("cancelled:") || title.lowercased().hasPrefix("geannuleerd:") { continue }
            if ev.attendees?.first(where: { $0.isCurrentUser })?.participantStatus == .declined { continue }
            let link = Meetings.joinLink(in: [ev.url?.absoluteString, ev.location, ev.notes])
            // Without a join link only real meetings: other people invited, not free time, shorter than six hours (a shared
            // trip or holiday is not one).
            if link == nil && (ev.availability == .free || !includeOffline || !ev.hasAttendees || end.timeIntervalSince(start) >= 6 * 3600) { continue }
            // The same invitation in two calendars (two accounts) once.
            if out.contains(where: { $0.title == title && $0.start == start }) { continue }
            out.append(Meeting(key: Meetings.key(id: ev.calendarItemExternalIdentifier ?? ev.eventIdentifier ?? title, start: start), title: title,
                               start: start, end: end, link: link, place: Meetings.place(ev.location), calendar: ev.calendar?.title ?? "",
                               color: hex(ev.calendar?.color)))
            if out.count >= 12 { break }
        }
        return out
    }

    nonisolated private static func hex(_ c: NSColor?) -> String {
        guard let c = c?.usingColorSpace(.sRGB) else { return "#60a5fa" }
        return String(format: "#%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    // MARK: taps from the bar

    private var teamsInstalled: Bool { URL(string: "msteams:").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) } != nil }

    /// Opens a meeting the bar was shown, by its key. False when there is no such meeting or it has no join link.
    func join(_ key: String) -> Bool {
        guard let m = meetings.first(where: { $0.key == key }), let link = m.link else { return false }
        NSWorkspace.shared.open(Meetings.appURL(link, teamsInstalled: teamsInstalled))
        lastOpened = "Joined \(m.title) from the bar."
        return true
    }

    /// Calls, video calls or chats with the speed-dial contact at this position.
    func call(_ index: Int, mode: Meetings.CallMode) -> Bool {
        let list = contacts()
        guard list.indices.contains(index) else { return false }
        let tenant = Meetings.domain(ofEmail: list[index].account).flatMap { tenants[$0] }.flatMap { $0.isEmpty ? nil : $0 }
        guard let url = Meetings.callURL(email: list[index].email, mode: mode, teamsInstalled: teamsInstalled, tenantID: tenant) else { return false }
        NSWorkspace.shared.open(url)
        lastOpened = "\(mode == .chat ? "Chat with" : mode == .video ? "Video call to" : "Call to") \(list[index].name) from the bar."
        return true
    }

    // MARK: what the bar gets

    func snapshot() -> [String: Any] {
        var out: [String: Any] = ["at": Int(Date().timeIntervalSince1970), "authorized": CalendarSource.authStatus() == .authorized]
        let now = Date()
        out["meetings"] = meetings.filter { $0.end > now }.prefix(8).map { m -> [String: Any] in
            var d: [String: Any] = ["key": m.key, "title": m.title, "start": Int(m.start.timeIntervalSince1970), "end": Int(m.end.timeIntervalSince1970),
                                    "calendar": m.calendar, "color": m.color]
            if let l = m.link { d["kind"] = l.kind.rawValue }
            if let p = m.place { d["place"] = p }
            return d
        }
        out["contacts"] = contacts().prefix(8).enumerated().map { i, c -> [String: Any] in
            ["i": i, "name": c.name, "initials": Meetings.initials(c.name), "ok": Meetings.isEmail(c.email)]
        }
        return out
    }

    /// Deckhand Home's line: the meeting on now, else the next one today with how long until it starts.
    func homeLine() -> (line: String, tone: String)? {
        let now = Date()
        guard updatedAt != nil, let m = meetings.first(where: { $0.end > now }) else { return nil }
        if m.start <= now { return ("Now: \(m.title)", "live") }
        let mins = Int(m.start.timeIntervalSince(now) / 60)
        guard mins < 12 * 60 else { return nil }
        let when = mins < 60 ? "in \(max(1, mins)) min" : m.start.formatted(date: .omitted, time: .shortened)
        return ("\(m.title) \(when)", mins <= 10 ? "warn" : "")
    }
}
