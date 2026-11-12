import Foundation
import AppKit
import CoreLocation
import UltraBarKit

/// The owner's Zeekr on the bar: Deckhand reads the car's status from Zeekr's gateway (`ZeekrClient`) and the Zeekr
/// bar app asks for `/zeekr/data.json`. Read-only. The sign-in stays on this Mac (a user-only secret file); the bar
/// gets only what it draws, never the tokens, the VIN or the car's coordinates.
///
/// Polling is polite: only while the Zeekr app is on the bar (or was opened in the last ten minutes), every 5
/// minutes, every 2 while charging and every minute while DC fast charging; a page opened after a long gap asks at
/// once. Errors back off to 15 minutes, and a refused sign-in stops the polling until it is renewed.
///
/// Private files live in `~/Library/Application Support/UltraWorkspaceMac/zeekr/`: `settings.json` (the home
/// location), `session.json` (the charge curve Deckhand records while the car charges; Zeekr's API has no history of
/// it) and the car pictures (`car.png`, `car-charging.png`, `car-trunk.png`, chosen by the owner and served to the bar
/// as `/zeekr/car/<variant>.png`; never part of Deckhand or the APK).
@MainActor
final class ZeekrFeed {
    // MARK: files

    nonisolated static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UltraWorkspaceMac", isDirectory: true).appendingPathComponent("zeekr", isDirectory: true)
    }
    nonisolated static func ensureFolder() -> URL {
        let f = folder
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return f
    }
    private nonisolated static func writePrivate(_ data: Data, _ name: String) {
        let url = ensureFolder().appendingPathComponent(name)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// The sign-in, as one JSON secret (`tokens/secret-zeekr.token`, user-only, like the other apps' keys).
    nonisolated static func loadCredentials() -> ZeekrCredentials? {
        guard let s = Store.shared.loadSecret(name: "zeekr"), let c = try? JSONDecoder().decode(ZeekrCredentials.self, from: Data(s.utf8)), c.complete else { return nil }
        return c
    }
    nonisolated static func saveCredentials(_ c: ZeekrCredentials?) {
        let s = c.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        Store.shared.saveSecret(s, name: "zeekr")
    }

    struct Settings: Codable, Equatable { var home: [Double]? }
    nonisolated static func loadSettings() -> Settings {
        (try? Data(contentsOf: folder.appendingPathComponent("settings.json"))).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
    }
    nonisolated static func saveSettings(_ s: Settings) {
        if let d = try? JSONEncoder().encode(s) { writePrivate(d, "settings.json") }
    }

    // MARK: pictures

    /// The owner's own pictures of the car, one per state, with FCC's file for each when imported from it.
    nonisolated static let pictures: [(variant: String, file: String, fcc: String, label: String)] = [
        ("normal", "car.png", "zeekr-7x-normal.png", "Parked"),
        ("charging", "car-charging.png", "zeekr-7x-charge-port.png", "Charging"),
        ("trunk", "car-trunk.png", "zeekr-7x-trunk-open.png", "Trunk open"),
    ]
    nonisolated static func pictureURL(_ variant: String) -> URL? {
        pictures.first { $0.variant == variant }.map { folder.appendingPathComponent($0.file) }
    }
    nonisolated static func hasPicture(_ variant: String) -> Bool { pictureURL(variant).map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    /// Where FCC's pictures are in its checkout, relative to the folder the owner points at (the checkout or the
    /// images folder itself).
    nonisolated static let fccImages = "frontend/public/images/zeekr"
    /// The FCC checkout Deckhand looks for on first use (the author's layout); anywhere else, "Import from FCC…" asks.
    nonisolated static var fccDefault: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("DEV/DNC/fcc") }

    /// Copies FCC's three pictures from `dir` (an FCC checkout or its images folder). Returns how many were copied.
    @discardableResult nonisolated static func importPictures(fromFCC dir: URL) -> Int {
        let fm = FileManager.default
        let images = fm.fileExists(atPath: dir.appendingPathComponent(pictures[0].fcc).path) ? dir : dir.appendingPathComponent(fccImages)
        var n = 0
        for p in pictures {
            let src = images.appendingPathComponent(p.fcc)
            guard fm.fileExists(atPath: src.path), let d = try? Data(contentsOf: src), d.count < 8_000_000 else { continue }
            writePrivate(d, p.file); n += 1
        }
        return n
    }
    /// Uses `src` (any image macOS can read) as the picture for `variant`, stored as PNG.
    nonisolated static func choosePicture(_ variant: String, from src: URL) -> Bool {
        guard let p = pictures.first(where: { $0.variant == variant }), let img = NSImageRep.png(src) else { return false }
        writePrivate(img, p.file); return true
    }
    nonisolated static func removePicture(_ variant: String) { if let u = pictureURL(variant) { try? FileManager.default.removeItem(at: u) } }
    /// First use: when there is no picture yet and FCC sits where its author keeps it, take FCC's pictures. Once.
    nonisolated static func importOnFirstUse() {
        let marker = folder.appendingPathComponent(".fcc-import-tried")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        writePrivate(Data(), ".fcc-import-tried")
        if !hasPicture("normal") { importPictures(fromFCC: fccDefault) }
    }

    private var pictureCache: [String: (key: String, data: Data)] = [:]
    /// The picture's bytes for the route, cached by modification time.
    func picture(_ variant: String) -> Data? {
        guard let url = Self.pictureURL(variant), let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mod = attrs[.modificationDate] as? Date else { return nil }
        let key = "\(mod.timeIntervalSince1970)"
        if let c = pictureCache[variant], c.key == key { return c.data }
        guard let d = try? Data(contentsOf: url) else { return nil }
        pictureCache[variant] = (key, d)
        return d
    }

    // MARK: state

    private(set) var status: ZeekrStatus?
    private(set) var fetchedAt: Date?
    private(set) var lastError: String?
    /// The sign-in was refused and could not be renewed: no more requests until the credentials change.
    private(set) var needsSignIn = false
    private(set) var place: String?
    private(set) var atHome = false
    private var geocoded: (lat: Double, lon: Double, text: String)?
    private var geocoding = false
    private var loop: Task<Void, Never>?
    private var wake = false

    /// A charging session as Deckhand saw it: one point per poll while charging.
    struct Session: Codable, Equatable {
        var start: Date
        var end: Date?
        var dc: Bool
        /// Seconds since `start`, state of charge, kW (0 when the car does not report power, as on AC).
        var points: [[Double]]
    }
    private(set) var session: Session? = (try? Data(contentsOf: ZeekrFeed.folder.appendingPathComponent("session.json")))
        .flatMap { try? JSONDecoder.zeekr.decode(Session.self, from: $0) }

    /// Ask again now (a sign-in was saved, the page was opened after a long gap).
    func poke() { wake = true; needsSignIn = false }

    func start(wanted: @escaping @MainActor () -> Bool, pageOpen: @escaping @MainActor () -> Bool) {
        loop?.cancel()
        loop = Task { [weak self] in
            var next = Date.distantPast, backoff: TimeInterval = 300
            var lastCreds: ZeekrCredentials?
            var lastAttempt = Date.distantPast, importTried = false
            while !Task.isCancelled {
                guard let self else { return }
                let creds = Self.loadCredentials()
                if creds != lastCreds { lastCreds = creds; self.needsSignIn = false; next = .distantPast; if creds == nil { self.status = nil; self.lastError = nil } }
                // Opening the page asks at once, unless the last attempt (success or not) was less than 90 s ago.
                if pageOpen(), Date().timeIntervalSince(lastAttempt) > 90, next > Date().addingTimeInterval(30) { next = .distantPast }
                if !importTried, wanted() { importTried = true; Self.importOnFirstUse() }
                if self.wake { self.wake = false; next = .distantPast }
                guard var c = creds, !self.needsSignIn, wanted(), Date() >= next else {
                    try? await Task.sleep(nanoseconds: 5_000_000_000); continue
                }
                lastAttempt = Date()
                do {
                    // Renew a day before the access token runs out, when there is a refresh token to do it with. Best
                    // effort: while the old token is still valid a failed renewal is tried again on the next poll.
                    if let exp = c.accessExpires, exp.timeIntervalSinceNow < 86400, exp > Date(), c.refreshToken != nil,
                       let renewed = try? await self.renew(c) { c = renewed }
                    let raw: [String: Any]
                    do { raw = try await ZeekrClient.status(c) }
                    catch ZeekrClient.Failure.unauthorized where c.refreshToken != nil {
                        c = try await self.renew(c); raw = try await ZeekrClient.status(c)
                    }
                    self.ingest(ZeekrStatus(raw))
                    self.lastError = nil; backoff = 300
                    let s = self.status
                    next = Date().addingTimeInterval(s?.charging == true ? (s?.dc == true ? 60 : 120) : 300)
                } catch let f as ZeekrClient.Failure {
                    switch f {
                    case .unauthorized, .signInNeeded, .badVin:
                        self.needsSignIn = true
                        self.lastError = f == .badVin ? f.errorDescription : c.refreshToken == nil
                            ? "The Zeekr access token has expired. Connect again in Apps → Zeekr."
                            : (ZeekrClient.Failure.signInNeeded.errorDescription ?? "")
                        WireLog.shared.event("zeekr: sign-in refused, polling paused until it is renewed")
                    default:
                        self.lastError = f.localizedDescription
                    }
                    next = Date().addingTimeInterval(backoff); backoff = min(900, backoff * 1.5)
                } catch {
                    self.lastError = error.localizedDescription
                    next = Date().addingTimeInterval(backoff); backoff = min(900, backoff * 1.5)
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func stop() { loop?.cancel(); loop = nil }

    /// New tokens from the refresh token, saved at once (the old refresh token may stop working).
    private func renew(_ c: ZeekrCredentials) async throws -> ZeekrCredentials {
        let n = try await ZeekrClient.refresh(c)
        Self.saveCredentials(n)
        WireLog.shared.event("zeekr: access token renewed")
        return n
    }

    private func ingest(_ s: ZeekrStatus) {
        status = s; fetchedAt = Date()
        record(s)
        locate(s)
    }

    /// Adds a point to the charging session (a new one when charging starts after a gap of more than 30 minutes),
    /// and closes it when charging stops.
    private func record(_ s: ZeekrStatus) {
        let now = Date()
        if s.charging, let soc = s.soc {
            var cur = session
            if cur == nil || (cur?.end.map { now.timeIntervalSince($0) > 1800 } ?? false) {
                cur = Session(start: now, end: nil, dc: s.dc, points: [])
            }
            cur!.end = nil
            cur!.dc = cur!.dc || s.dc
            cur!.points.append([now.timeIntervalSince(cur!.start).rounded(), soc, ((s.dcKW ?? 0) * 10).rounded() / 10])
            if cur!.points.count > 400 { cur!.points.removeFirst(cur!.points.count - 400) }
            session = cur
            saveSession()
        } else if var cur = session, cur.end == nil {
            cur.end = now
            if let soc = s.soc, (cur.points.last?[1] ?? -1) != soc { cur.points.append([now.timeIntervalSince(cur.start).rounded(), soc, 0]) }
            session = cur
            saveSession()
        }
    }
    private func saveSession() {
        if let s = session, let d = try? JSONEncoder.zeekr.encode(s) { Self.writePrivate(d, "session.json") }
    }

    /// "Home" within 150 m of the home location, else a short address (street, town) from Apple's reverse geocoder,
    /// asked again only when the car has moved more than 150 m. Coordinates never leave this Mac except to Apple.
    private func locate(_ s: ZeekrStatus) {
        guard let lat = s.lat, let lon = s.lon else { return }
        if let h = Self.loadSettings().home, h.count == 2, HavenFeed.km((lat, lon), (h[0], h[1])) <= 0.15 {
            atHome = true; place = "Home"; return
        }
        atHome = false
        if let g = geocoded, HavenFeed.km((lat, lon), (g.lat, g.lon)) <= 0.15 { place = g.text; return }
        guard !geocoding else { return }
        geocoding = true
        Task { [weak self] in
            let text = await Self.shortAddress(lat: lat, lon: lon)
            guard let self else { return }
            self.geocoding = false
            if let text { self.geocoded = (lat, lon, text); if !self.atHome { self.place = text } }
        }
    }
    nonisolated static func shortAddress(lat: Double, lon: Double) async -> String? {
        let marks = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lon))
        guard let p = marks?.first else { return nil }
        let parts = [p.thoroughfare ?? p.name, p.locality].compactMap { $0 }.filter { !$0.isEmpty }
        var seen = Set<String>()
        let text = parts.filter { seen.insert($0).inserted }.joined(separator: ", ")
        return text.isEmpty ? nil : text
    }

    /// Set the home location to where the car is now (nil clears it).
    func setHomeToCar() -> Bool {
        guard let s = status, let lat = s.lat, let lon = s.lon else { return false }
        Self.saveSettings(Settings(home: [lat, lon])); if let st = status { locate(st) }
        return true
    }
    func setHome(_ c: (lat: Double, lon: Double)?) {
        Self.saveSettings(Settings(home: c.map { [$0.lat, $0.lon] }))
        if c == nil { atHome = false; geocoded = nil; place = nil }
        if let st = status { locate(st) }
    }

    // MARK: what the bar gets

    func snapshot(clock24h: Bool) -> [String: Any] {
        let now = Date()
        let creds = Self.loadCredentials()
        var out: [String: Any] = ["hasAuth": creds != nil, "at": Int(now.timeIntervalSince1970)]
        if let e = lastError { out["error"] = e }
        if needsSignIn { out["signIn"] = true }
        let nf = NumberFormatter(); nf.locale = .current; nf.numberStyle = .decimal
        func dec(_ v: Double, _ digits: Int) -> String { nf.minimumFractionDigits = digits; nf.maximumFractionDigits = digits; return nf.string(from: v as NSNumber) ?? "\(v)" }
        let time = DateFormatter(); time.dateFormat = clock24h ? "HH:mm" : "h:mm a"
        if let s = status {
            var car: [String: Any] = ["charging": s.charging, "plugged": s.plugged, "climate": s.climateOn, "open": s.open]
            if let v = s.soc { car["soc"] = Int(v.rounded()) }
            if let v = s.rangeKm { car["range"] = v }
            if let v = s.targetSoc { car["target"] = v }
            car["charge"] = s.charging ? "charging" : s.chargeSts == 2 ? "complete" : s.chargeSts == 4 ? "paused" : s.chargeSts == 5 ? "error" : s.plugged ? "plugged" : "unplugged"
            if s.plugged { car["plug"] = s.dc ? "DC" : "AC" }
            if let k = s.dcKW, s.charging { car["kW"] = k >= 100 ? dec(k, 0) : dec(k, 1) }
            if let m = s.minutesToFull, s.charging {
                car["mins"] = m
                car["fullAt"] = time.string(from: now.addingTimeInterval(TimeInterval(m * 60)))
            }
            if let l = s.locked { car["locked"] = l }
            if let t = s.interiorTemp { car["temp"] = dec(t, t.rounded() == t ? 0 : 1) }
            car["tyres"] = s.tyresKPa.map { $0.map { dec($0 / 100, 1) as Any } ?? NSNull() }
            car["tyreWarn"] = s.tyreWarnings
            if let o = s.odometerKm { nf.minimumFractionDigits = 0; nf.maximumFractionDigits = 0; car["odo"] = nf.string(from: o as NSNumber) ?? "\(o)" }
            if let p = place { car["place"] = p }
            car["home"] = atHome
            if let u = s.updated { car["ago"] = max(0, Int(now.timeIntervalSince(u))) }
            out["car"] = car
            let variant = s.plugged && Self.hasPicture("charging") ? "charging" : s.open.contains("trunk") && Self.hasPicture("trunk") ? "trunk" : "normal"
            if let url = Self.pictureURL(variant), let mod = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date {
                out["pic"] = variant; out["picKey"] = "\(variant)-\(Int(mod.timeIntervalSince1970))"
            }
        }
        if let ses = session, !ses.points.isEmpty {
            let day = DateFormatter(); day.setLocalizedDateFormatFromTemplate("EEE d MMM")
            var d: [String: Any] = ["live": ses.end == nil, "dc": ses.dc, "points": ses.points.map { [($0[0] / 60 * 10).rounded() / 10, $0[1], $0[2]] },
                                    "from": time.string(from: ses.start), "day": day.string(from: ses.start)]
            if let e = ses.end { d["to"] = time.string(from: e) }
            out["session"] = d
        }
        return out
    }
}

extension JSONDecoder { static let zeekr: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }() }
extension JSONEncoder { static let zeekr: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }() }

extension NSImageRep {
    /// Any image file macOS reads, as PNG data (nil when it is not an image).
    nonisolated static func png(_ url: URL) -> Data? {
        guard let rep = NSImageRep(contentsOf: url) else { return nil }
        if let b = rep as? NSBitmapImageRep { return b.representation(using: .png, properties: [:]) }
        let img = NSImage(size: rep.size); img.addRepresentation(rep)
        return img.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?.representation(using: .png, properties: [:])
    }
}
