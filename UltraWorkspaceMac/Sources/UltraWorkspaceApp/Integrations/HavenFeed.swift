import Foundation
import UltraBarKit

/// A place the Haven bar app watches: a sea port or an inland terminal. `area` is where a ship counts as there
/// (alongside when it lies still), `approach` the water around it where a moving ship counts as arriving.
/// Boxes are `[latMin, latMax, lonMin, lonMax]`.
struct HavenPlace: Codable, Equatable, Sendable {
    var id: String
    var name: String
    /// "port" (sea port: only ships of `minLength` m and longer) or "terminal" (inland: barges).
    var kind: String = "terminal"
    var area: [Double]
    var approach: [Double]?
    /// Words in a ship's AIS destination that mean "going here" (upper case, e.g. "HENGELO", "NLRTM").
    var match: [String] = []
    var minLength: Int?

    func inArea(_ lat: Double, _ lon: Double) -> Bool { Self.inside(area, lat, lon) }
    func inApproach(_ lat: Double, _ lon: Double) -> Bool { approach.map { Self.inside($0, lat, lon) } ?? false }
    var center: (lat: Double, lon: Double) { area.count == 4 ? ((area[0] + area[1]) / 2, (area[2] + area[3]) / 2) : (0, 0) }
    var valid: Bool { area.count == 4 && (approach?.count ?? 4) == 4 && !id.isEmpty }
    static func inside(_ b: [Double], _ lat: Double, _ lon: Double) -> Bool {
        b.count == 4 && lat >= b[0] && lat <= b[1] && lon >= b[2] && lon <= b[3]
    }
}

/// Ships near the Haven places, from aisstream.io's AIS websocket (wss://stream.aisstream.io/v0/stream). Deckhand
/// holds the stream so the API key never leaves this Mac; the bar app asks for `/haven/data.json`.
///
/// The places come from `haven.json` in Deckhand's Application Support folder (`{"places":[HavenPlace…]}`), so
/// which terminals someone watches stays on their Mac. Without that file Haven watches the port of Rotterdam.
@MainActor
final class HavenFeed {
    struct Ship {
        var name = ""
        var type: Int?
        var length: Int?
        var destination = ""
        var eta: DateComponents?
        var lat = 0.0, lon = 0.0, sog = 0.0
        var at = Date.distantPast
        /// Any message from the ship (static data comes every 6 minutes, positions every few seconds to minutes).
        var seen = Date()
        /// The position before the last one, to tell whether the ship is closing in on a place.
        var prev: (lat: Double, lon: Double)?
    }

    nonisolated static let defaultPlaces = [
        HavenPlace(id: "rotterdam", name: "Rotterdam", kind: "port", area: [51.84, 52.05, 3.90, 4.60],
                   approach: [51.80, 52.20, 3.30, 3.90], match: ["RTM", "ROTTERDAM"], minLength: 200),
    ]
    nonisolated static var placesURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UltraWorkspaceMac", isDirectory: true).appendingPathComponent("haven.json")
    }
    nonisolated static func loadPlaces() -> (places: [HavenPlace], fromFile: Bool, error: String?) {
        guard let data = try? Data(contentsOf: placesURL) else { return (defaultPlaces, false, nil) }
        struct File: Codable { var places: [HavenPlace] }
        do {
            let p = try JSONDecoder().decode(File.self, from: data).places.filter(\.valid)
            return p.isEmpty ? (defaultPlaces, true, "haven.json lists no valid places") : (Array(p.prefix(6)), true, nil)
        } catch { return (defaultPlaces, true, "haven.json: \(error.localizedDescription)") }
    }
    /// Writes the current places to haven.json when there is no file yet, so there is something to edit.
    nonisolated static func ensurePlacesFile() -> URL {
        let url = placesURL
        if !FileManager.default.fileExists(atPath: url.path) {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            struct File: Codable { var places: [HavenPlace] }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? enc.encode(File(places: defaultPlaces)).write(to: url)
        }
        return url
    }

    private(set) var places: [HavenPlace] = HavenFeed.defaultPlaces
    private(set) var placesError: String?
    private(set) var connected = false
    private(set) var lastError: String?
    private(set) var messages = 0
    private var ships: [Int: Ship] = [:]
    private var socket: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?

    /// Runs while `wanted()` says so (a key is set and the Haven app is on the bar or was asked recently).
    func start(key: @escaping @MainActor () -> String, wanted: @escaping @MainActor () -> Bool) {
        loop?.cancel()
        loop = Task { [weak self] in
            var backoff: UInt64 = 5
            while !Task.isCancelled {
                guard let self else { return }
                let k = key().trimmingCharacters(in: .whitespacesAndNewlines)
                let loaded = Self.loadPlaces()
                self.places = loaded.places; self.placesError = loaded.error
                guard !k.isEmpty, wanted() else {
                    self.connected = false
                    try? await Task.sleep(nanoseconds: 5_000_000_000); continue
                }
                let started = Date()
                await self.run(key: k, places: loaded.places, stillWanted: { key() == k && wanted() && Self.loadPlaces().places == loaded.places })
                self.connected = false
                if Task.isCancelled { return }
                // A connection that lived a while starts over quickly; one that keeps failing backs off to a minute.
                backoff = Date().timeIntervalSince(started) > 120 ? 5 : min(60, backoff * 2)
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
            }
        }
    }

    func stop() { loop?.cancel(); loop = nil; socket?.cancel(with: .goingAway, reason: nil); socket = nil; connected = false }

    /// One connection: subscribe within aisstream's 3 s, then read until it closes, the key or the places change,
    /// or nobody wants Haven any more (checked every 30 s).
    private func run(key: String, places: [HavenPlace], stillWanted: @escaping @MainActor () -> Bool) async {
        let boxes = places.flatMap { p in [p.area] + (p.approach.map { [$0] } ?? []) }.map { b in [[b[0], b[2]], [b[1], b[3]]] }
        let sub: [String: Any] = ["APIKey": key, "BoundingBoxes": boxes,
                                  "FilterMessageTypes": ["PositionReport", "StandardClassBPositionReport", "ShipStaticData"]]
        guard let url = URL(string: "wss://stream.aisstream.io/v0/stream"),
              let body = try? JSONSerialization.data(withJSONObject: sub), let text = String(data: body, encoding: .utf8) else { return }
        let ws = URLSession.shared.webSocketTask(with: url)
        socket = ws
        ws.resume()
        do { try await ws.send(.string(text)) } catch { lastError = error.localizedDescription; return }
        let watchdog = Task { [weak ws] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if !stillWanted() { ws?.cancel(with: .goingAway, reason: nil); return }
            }
        }
        defer { watchdog.cancel(); ws.cancel(with: .goingAway, reason: nil); if socket === ws { socket = nil } }
        while !Task.isCancelled {
            let msg: URLSessionWebSocketTask.Message
            do { msg = try await ws.receive() } catch {
                if ws.closeCode != .goingAway { lastError = Self.closeReason(ws) ?? error.localizedDescription }
                return
            }
            let data: Data
            switch msg { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: continue }
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if let e = obj["error"] as? String { lastError = "aisstream.io: \(e)"; return }
            if !connected { connected = true; lastError = nil; WireLog.shared.event("haven: aisstream connected, \(boxes.count) boxes") }
            messages += 1
            ingest(obj)
        }
    }

    private static func closeReason(_ ws: URLSessionWebSocketTask) -> String? {
        guard let r = ws.closeReason, let s = String(data: r, encoding: .utf8), !s.isEmpty else { return nil }
        return "aisstream.io: \(s)"
    }

    private func ingest(_ m: [String: Any]) {
        guard let meta = m["MetaData"] as? [String: Any], let mmsi = meta["MMSI"] as? Int,
              let type = m["MessageType"] as? String, let body = (m["Message"] as? [String: Any])?[type] as? [String: Any] else { return }
        var s = ships[mmsi] ?? Ship()
        s.seen = Date()
        if let n = (meta["ShipName"] as? String)?.trimmingCharacters(in: .whitespaces), !n.isEmpty { s.name = n }
        if type == "ShipStaticData" {
            if let t = body["Type"] as? Int { s.type = t }
            if let d = body["Dimension"] as? [String: Any] {
                let len = ((d["A"] as? Int) ?? 0) + ((d["B"] as? Int) ?? 0)
                if len > 0 { s.length = len }
            }
            if let dest = body["Destination"] as? String { s.destination = dest.trimmingCharacters(in: .whitespaces).uppercased() }
            if let e = body["Eta"] as? [String: Any], let mo = e["Month"] as? Int, let d = e["Day"] as? Int, mo > 0, d > 0 {
                s.eta = DateComponents(month: mo, day: d, hour: e["Hour"] as? Int, minute: e["Minute"] as? Int)
            }
        } else if let lat = meta["latitude"] as? Double, let lon = meta["longitude"] as? Double {
            if s.at != .distantPast, abs(s.lat - lat) + abs(s.lon - lon) > 0.0002 { s.prev = (s.lat, s.lon) }
            s.lat = lat; s.lon = lon; s.sog = (body["Sog"] as? Double) ?? 0; s.at = Date()
        }
        ships[mmsi] = s
        if messages % 500 == 0 { ships = ships.filter { Date().timeIntervalSince($0.value.seen) < 5400 } }
    }

    // MARK: what the bar gets

    nonisolated static func km(_ a: (lat: Double, lon: Double), _ b: (lat: Double, lon: Double)) -> Double {
        let r = 6371.0, dLat = (b.lat - a.lat) * .pi / 180, dLon = (b.lon - a.lon) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.lat * .pi / 180) * cos(b.lat * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    /// Whether a ship is the kind the place is about: long ships for a port, barges (cargo, tanker or not yet
    /// known) for a terminal — no tugs, pilots, pleasure craft or service boats.
    private static func relevant(_ s: Ship, for p: HavenPlace) -> Bool {
        if p.kind == "port" { return (s.length ?? 0) >= (p.minLength ?? 200) }
        if let t = s.type, !(70...89).contains(t), t != 0 { return false }
        if let l = s.length, l < 40 { return false }
        return true
    }

    private func etaText(_ s: Ship, dist: Double, port: Bool, clock24h: Bool) -> String? {
        if port, let e = s.eta, let mo = e.month, let d = e.day, let h = e.hour, let mi = e.minute, h < 24, mi < 60 {
            let cal = Calendar.current, now = Date()
            var c = DateComponents(year: cal.component(.year, from: now), month: mo, day: d, hour: h, minute: mi)
            c.timeZone = TimeZone(identifier: "UTC")
            guard var date = cal.date(from: c) else { return nil }
            if date < now.addingTimeInterval(-180 * 86400) { c.year! += 1; date = cal.date(from: c) ?? date }
            if date < now.addingTimeInterval(-6 * 3600) { return nil }   // an ETA that has long passed is not kept up to date
            let f = DateFormatter(); f.dateFormat = cal.isDateInToday(date) ? (clock24h ? "HH:mm" : "h:mm a") : (clock24h ? "EEE HH:mm" : "EEE h:mm a")
            return f.string(from: date)
        }
        guard s.sog > 0.5 else { return nil }
        // Straight line at the current speed, plus a third for bends, bridges and locks: a rough guess, shown as "~".
        let minutes = Int((dist * 1.33) / (s.sog * 1.852) * 60)
        return minutes < 60 ? "~\(max(1, minutes)) min" : "~\(minutes / 60) h \(String(format: "%02d", minutes % 60))"
    }

    func snapshot(hasKey: Bool, clock24h: Bool) -> [String: Any] {
        let now = Date()
        let list: [[String: Any]] = places.map { p in
            let c = p.center
            var alongside: [(String, [String: Any])] = [], arriving: [(Double, [String: Any])] = []
            for (_, s) in ships where s.at != .distantPast && now.timeIntervalSince(s.at) < 5400 && Self.relevant(s, for: p) {
                let inArea = p.inArea(s.lat, s.lon), inApp = p.inApproach(s.lat, s.lon)
                guard inArea || inApp else { continue }
                let d = Self.km((s.lat, s.lon), c)
                let goingHere = p.match.contains { !$0.isEmpty && s.destination.contains($0.uppercased()) }
                let closing = s.prev.map { Self.km($0, c) > d + 0.05 } ?? false
                let moving = s.sog > 0.5
                var row: [String: Any] = ["n": s.name.isEmpty ? "unnamed" : s.name, "d": (d * 10).rounded() / 10,
                                          "s": (s.sog * 10).rounded() / 10, "ago": Int(now.timeIntervalSince(s.at)), "dest": s.destination]
                if let l = s.length { row["l"] = l }
                if inArea && !moving {
                    row["st"] = "alongside"; alongside.append((s.name, row))
                } else if moving && (goingHere || closing) {
                    row["st"] = "arriving"
                    if let e = etaText(s, dist: d, port: p.kind == "port", clock24h: clock24h) { row["eta"] = e }
                    arriving.append((d, row))
                }
            }
            return ["id": p.id, "name": p.name, "kind": p.kind,
                    "alongside": alongside.sorted { $0.0 < $1.0 }.prefix(16).map(\.1), "nAlongside": alongside.count,
                    "arriving": arriving.sorted { $0.0 < $1.0 }.prefix(16).map(\.1), "nArriving": arriving.count]
        }
        var out: [String: Any] = ["hasKey": hasKey, "connected": connected, "places": list, "at": Int(now.timeIntervalSince1970)]
        if let e = lastError ?? placesError { out["error"] = e }
        return out
    }
}
