import Foundation
import AppKit
import UltraBarKit

/// The Climate bar app's data: the house's heating from tado (one zone, read and set) and the Netatmo weather station's
/// readings, both on this Mac so no token reaches the bar; the app asks for `/climate/data.json` and taps POST
/// `/climate/heat/<°C>/<minutes|next>` and `/climate/schedule`.
///
/// tado (its own app's API, not an official one; tado allows about 100 calls a day without Auto-Assist):
///  - Sign-in: the device-code flow at login.tado.com (the user approves in the browser; Deckhand never sees the password).
///    The rotating refresh token, the home and the zone are kept in the Keychain, so a restart costs no calls.
///  - State: `GET /homes/{home}/zones/{zone}/state`, every 30 minutes while the app is on the bar, a minute after a
///    known change (the schedule's next block, a timer ending) but never sooner than 10 minutes after the last read,
///    hourly when fewer than 20 calls are left today and not at all below 6 (kept for taps).
///  - Taps: `PUT …/overlay` (heating on at a temperature, for a time or until the next schedule change; its answer
///    updates the state without another call) and `DELETE …/overlay` (back to the schedule, then one read).
///
/// Netatmo (the official Connect API, scope `read_station`, with the user's own app at dev.netatmo.com):
///  - `GET /api/getstationsdata` every 10 minutes (the station uploads every 10), `GET /api/getmeasure` for the indoor and
///    outdoor temperature of the last 24 hours every 30 minutes.
///
/// Nothing runs while the app is not on the bar and nobody asked in the last ten minutes. Kept in memory only.
@MainActor
final class ClimateFeed: ObservableObject {
    // tado
    @Published private(set) var tadoConnected = false
    @Published private(set) var tadoConnecting = false
    /// While signing in: the code tado shows and the page to approve it on.
    @Published private(set) var tadoUserCode: String?
    @Published private(set) var tadoLink: URL?
    @Published private(set) var tadoError: String?
    @Published private(set) var homeName: String?
    /// Calls left today, as tado's last answer said (nil when tado sent no RateLimit header).
    @Published private(set) var callsLeft: Int?
    // Netatmo
    @Published var netatmoClientID: String = Store.shared.loadSecret(name: "netatmo-client-id") ?? "" {
        didSet { Store.shared.saveSecret(netatmoClientID.trimmingCharacters(in: .whitespacesAndNewlines), name: "netatmo-client-id", debounce: true) }
    }
    @Published var netatmoClientSecret: String = Store.shared.loadSecret(name: "netatmo-client-secret") ?? "" {
        didSet { Store.shared.saveSecret(netatmoClientSecret.trimmingCharacters(in: .whitespacesAndNewlines), name: "netatmo-client-secret", debounce: true) }
    }
    @Published private(set) var netatmoConnected = false
    @Published private(set) var netatmoConnecting = false
    @Published private(set) var netatmoError: String?
    @Published private(set) var stationName: String?
    @Published private(set) var updatedAt: Date?

    var netatmoHasClient: Bool { !netatmoClientID.trimmingCharacters(in: .whitespaces).isEmpty && !netatmoClientSecret.trimmingCharacters(in: .whitespaces).isEmpty }

    private struct TadoTokens: Codable { var access: String; var refresh: String; var expiresAt: Int; var home: Int?; var zone: Int?; var homeName: String? }
    private struct NetatmoTokens: Codable { var access: String; var refresh: String; var expiresAt: Int }

    private var tado: TadoTokens? { didSet { tadoConnected = tado != nil; homeName = tado?.homeName } }
    private var netatmo: NetatmoTokens? { didSet { netatmoConnected = netatmo != nil } }

    private var heating: Climate.Heating?
    private var heatingAt: Date?
    private var tadoDue = Date.distantPast
    private var tadoRetryAt = Date.distantPast
    private var callsReset: Date?
    /// What a tap asked for until tado answered ("21°", "schedule"), and a tap's failure.
    private var pending: String?
    private var actionError: String?
    private var modules: [Climate.Module] = []
    private var chart: [String: [Double]] = [:]
    private var chartFrom: Date?
    private var stationsDue = Date.distantPast
    private var chartDue = Date.distantPast
    private var forced = false
    private var loop: Task<Void, Never>?
    private var tadoConnectTask: Task<Void, Never>?
    private var netatmoConnectTask: Task<Void, Never>?
    private var callback: OAuthCallback?
    private let wake = WakeSignal()

    /// tado's public client id for its own web app's device flow (the one every tado integration uses).
    nonisolated static let tadoClient = "1bb50063-6b0c-4d11-bd99-387f4a91cc46"
    nonisolated static let tadoAPI = "https://my.tado.com/api/v2"

    init() {
        tado = Self.load(TadoTokens.self, "tado-tokens")
        netatmo = Self.load(NetatmoTokens.self, "netatmo-tokens")
        tadoConnected = tado != nil; homeName = tado?.homeName; netatmoConnected = netatmo != nil
    }

    private nonisolated static func load<T: Decodable>(_ t: T.Type, _ name: String) -> T? {
        guard let s = Store.shared.loadSecret(name: name), !s.isEmpty else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(s.utf8))
    }
    private func save<T: Encodable>(_ v: T?, _ name: String) {
        let json = v.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        Store.shared.saveSecret(json, name: name)
    }
    private func setTado(_ t: TadoTokens?) { tado = t; save(t, "tado-tokens") }
    private func setNetatmo(_ t: NetatmoTokens?) { netatmo = t; save(t, "netatmo-tokens") }

    // MARK: the poll

    func start(wanted: @escaping @MainActor () -> Bool) {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.forced = false
                let active = wanted()
                let now = Date()
                if active {
                    if self.netatmo != nil, now >= self.stationsDue { await self.refreshStations() }
                    if self.netatmo != nil, now >= self.chartDue { await self.refreshChart() }
                    if self.tado != nil, now >= self.tadoDue, now >= self.tadoRetryAt { await self.refreshTado() }
                }
                var next: [Date] = []
                if active {
                    if self.netatmo != nil { next += [self.stationsDue, self.chartDue] }
                    if self.tado != nil { next.append(max(self.tadoDue, self.tadoRetryAt)) }
                }
                let wait = active ? min(600, max(15, (next.min() ?? .distantFuture).timeIntervalSinceNow)) : 600
                await self.wake.wait(wait) { self.forced || wanted() != active }
            }
        }
    }
    func stop() { loop?.cancel(); loop = nil }
    func poke() { wake.signal() }
    func refreshNow() {
        stationsDue = .distantPast; chartDue = .distantPast
        if let h = heatingAt, Date().timeIntervalSince(h) > 60 { tadoDue = .distantPast }
        netatmoError = nil; forced = true; wake.signal()
    }

    // MARK: tado

    private struct TadoError: Error { let message: String }

    private func refreshTado() async {
        do {
            let (home, zone) = try await tadoHomeZone()
            let j = try await tadoJSON("GET", "/homes/\(home)/zones/\(zone)/state") as? [String: Any] ?? [:]
            guard let h = Climate.heating(j) else { throw TadoError(message: "tado's answer had no heating state.") }
            heating = h; heatingAt = Date(); tadoError = nil; updatedAt = Date()
            scheduleTadoRead()
        } catch let e as TadoError {
            tadoError = e.message
            tadoDue = Date().addingTimeInterval(1800)
        } catch {
            tadoError = "tado: \(error.localizedDescription)"
            tadoDue = Date().addingTimeInterval(600)
        }
    }

    /// The next state read: 30 minutes, or a minute after a known change, never sooner than 10 minutes; hourly when the
    /// day's calls run low, none at all when only the few kept for taps are left.
    private func scheduleTadoRead() {
        let now = Date()
        var next = now.addingTimeInterval(1800)
        let change = [heating?.manual == true && heating?.untilSchedule == false ? heating?.manualEnds : nil, heating?.nextAt].compactMap { $0 }.filter { $0 > now }.min()
        if let c = change { next = min(next, max(now.addingTimeInterval(600), c.addingTimeInterval(60))) }
        if let left = callsLeft {
            if left < 6 { next = max(next, callsReset ?? now.addingTimeInterval(3 * 3600)) }
            else if left < 20 { next = max(next, now.addingTimeInterval(3600)) }
        }
        tadoDue = next
    }

    private func tadoHomeZone() async throws -> (Int, Int) {
        if let t = tado, let h = t.home, let z = t.zone { return (h, z) }
        let me = try await tadoJSON("GET", "/me") as? [String: Any] ?? [:]
        guard let home = (me["homes"] as? [[String: Any]])?.first, let hid = (home["id"] as? NSNumber)?.intValue else {
            throw TadoError(message: "Your tado account has no home.")
        }
        let zones = try await tadoJSON("GET", "/homes/\(hid)/zones") as? [[String: Any]] ?? []
        guard let zone = Climate.heatingZone(zones) else { throw TadoError(message: "Your tado home has no heating zone.") }
        if var t = tado { t.home = hid; t.zone = zone.id; t.homeName = home["name"] as? String; setTado(t) }
        return (hid, zone.id)
    }

    private func tadoJSON(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Any? {
        let token = try await tadoAccess()
        var req = URLRequest(url: URL(string: Self.tadoAPI + path)!, timeoutInterval: 20)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw TadoError(message: "tado answered without a status.") }
        if let r = Climate.rateLimit(http.value(forHTTPHeaderField: "RateLimit")) {
            callsLeft = r.remaining
            callsReset = r.resetIn.map { Date().addingTimeInterval(Double($0)) }
        }
        switch http.statusCode {
        case 200...299: return data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data)
        case 401:
            if var t = tado { t.expiresAt = 0; setTado(t) }
            throw TadoError(message: "tado refused the sign-in. Deckhand tries again later.")
        case 429:
            callsLeft = 0
            tadoRetryAt = callsReset ?? Date().addingTimeInterval(3 * 3600)
            throw TadoError(message: "tado's daily limit is used up. Deckhand waits until it resets.")
        default:
            throw TadoError(message: "tado answered \(http.statusCode). Deckhand tries again later.")
        }
    }

    private func tadoAccess() async throws -> String {
        guard let t = tado else { throw TadoError(message: "Connect tado under Apps → Climate.") }
        if t.expiresAt - Int(Date().timeIntervalSince1970) > 30 { return t.access }
        let (data, http) = try await post("https://login.tado.com/oauth2/token",
                                          ["client_id": Self.tadoClient, "grant_type": "refresh_token", "refresh_token": t.refresh])
        if http.statusCode == 400 || http.statusCode == 401 {
            setTado(nil); heating = nil
            WireLog.shared.event("tado: refresh refused (\(http.statusCode)); disconnected")
            throw TadoError(message: "tado's sign-in has expired. Connect again under Apps → Climate.")
        }
        guard http.statusCode == 200, let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = j["access_token"] as? String else { throw TadoError(message: "tado's sign-in answered \(http.statusCode).") }
        var n = t
        n.access = access
        n.expiresAt = Int(Date().timeIntervalSince1970) + ((j["expires_in"] as? NSNumber)?.intValue ?? 600)
        if let r = j["refresh_token"] as? String { n.refresh = r }
        setTado(n)
        return access
    }

    /// A tap on the bar: heating on at `celsius` for `minutes` (nil: until the next schedule change). The overlay tado
    /// returns is the new state, so this costs one call.
    func heat(celsius: Double, minutes: Int?) async {
        guard tado != nil else { return }
        pending = Self.degrees(celsius); actionError = nil
        defer { pending = nil }
        do {
            let (home, zone) = try await tadoHomeZone()
            let o = try await tadoJSON("PUT", "/homes/\(home)/zones/\(zone)/overlay", body: Climate.overlayBody(celsius: celsius, minutes: minutes)) as? [String: Any] ?? [:]
            var h = heating ?? Climate.Heating(on: true, target: celsius, inside: nil, humidity: nil, power: nil, manual: true, manualEnds: nil,
                                               untilSchedule: false, nextAt: nil, nextOn: nil, nextTarget: nil, online: true, openWindow: false, away: false)
            let term = (o["termination"] as? [String: Any]) ?? [:]
            h.on = true; h.target = celsius; h.manual = true
            h.untilSchedule = minutes == nil
            h.manualEnds = (term["projectedExpiry"] as? String).flatMap(Climate.date) ?? minutes.map { Date().addingTimeInterval(Double($0 * 60)) }
            heating = h; tadoError = nil
            WireLog.shared.event("tado: heating set to \(celsius) °C from the bar")
            scheduleTadoRead()
        } catch let e as TadoError { actionError = e.message } catch { actionError = "tado: \(error.localizedDescription)" }
    }

    /// A tap on the bar: end the manual setting, back to the schedule; then one read for the schedule's setting.
    func backToSchedule() async {
        guard tado != nil else { return }
        pending = "schedule"; actionError = nil
        defer { pending = nil }
        do {
            let (home, zone) = try await tadoHomeZone()
            _ = try await tadoJSON("DELETE", "/homes/\(home)/zones/\(zone)/overlay")
            heating?.manual = false; heating?.manualEnds = nil; heating?.untilSchedule = false
            WireLog.shared.event("tado: back to the schedule from the bar")
            tadoDue = Date().addingTimeInterval(3); forced = true; wake.signal()
        } catch let e as TadoError { actionError = e.message } catch { actionError = "tado: \(error.localizedDescription)" }
    }

    /// The device-code sign-in: shows tado's code, opens tado's page and waits (up to tado's limit, five minutes) for the
    /// user to approve.
    func connectTado() {
        guard !tadoConnecting else { return }
        tadoConnectTask?.cancel()
        tadoError = nil; tadoConnecting = true
        tadoConnectTask = Task { [weak self] in
            guard let self else { return }
            defer { self.tadoConnecting = false; self.tadoUserCode = nil; self.tadoLink = nil }
            do {
                let (data, http) = try await self.post("https://login.tado.com/oauth2/device_authorize", ["client_id": Self.tadoClient, "scope": "offline_access"])
                guard http.statusCode == 200, let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let device = j["device_code"] as? String, let link = (j["verification_uri_complete"] as? String).flatMap(URL.init(string:)),
                      link.scheme == "https", link.host?.hasSuffix("tado.com") == true else {
                    self.tadoError = "tado did not start the sign-in (\(http.statusCode))."; return
                }
                self.tadoUserCode = j["user_code"] as? String
                self.tadoLink = link
                NSWorkspace.shared.open(link)
                var interval = max(5, (j["interval"] as? NSNumber)?.doubleValue ?? 5)
                let end = Date().addingTimeInterval(min(900, (j["expires_in"] as? NSNumber)?.doubleValue ?? 300))
                while Date() < end {
                    try await Task.sleep(for: .seconds(interval))
                    let (d, h) = try await self.post("https://login.tado.com/oauth2/token",
                                                     ["client_id": Self.tadoClient, "device_code": device, "grant_type": "urn:ietf:params:oauth:grant-type:device_code"])
                    let a = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
                    if h.statusCode == 200, let access = a["access_token"] as? String, let refresh = a["refresh_token"] as? String {
                        self.setTado(TadoTokens(access: access, refresh: refresh,
                                                expiresAt: Int(Date().timeIntervalSince1970) + ((a["expires_in"] as? NSNumber)?.intValue ?? 600)))
                        self.heating = nil; self.tadoDue = .distantPast; self.tadoRetryAt = .distantPast
                        WireLog.shared.event("tado: connected")
                        _ = try? await self.tadoHomeZone()
                        self.forced = true; self.wake.signal()
                        return
                    }
                    switch a["error"] as? String {
                    case "authorization_pending": continue
                    case "slow_down": interval += 5
                    case "access_denied": self.tadoError = "You did not allow Deckhand to use your tado account."; return
                    case "expired_token": self.tadoError = "The tado code expired before it was approved. Press Connect again."; return
                    default: self.tadoError = "tado refused the sign-in (\(h.statusCode))."; return
                    }
                }
                self.tadoError = "The tado code expired before it was approved. Press Connect again."
            } catch is CancellationError {
            } catch { self.tadoError = "Connecting failed: \(error.localizedDescription)" }
        }
    }
    func cancelTadoConnect() { tadoConnectTask?.cancel(); tadoConnectTask = nil; tadoConnecting = false }
    /// Forgets the sign-in here (tado has no revoke; it lapses after 30 days unused).
    func disconnectTado() { setTado(nil); heating = nil; heatingAt = nil; callsLeft = nil; tadoError = nil; WireLog.shared.event("tado: disconnected") }

    // MARK: Netatmo

    private func refreshStations() async {
        do {
            let j = try await netatmoJSON("/api/getstationsdata")
            modules = Climate.modules(j)
            let devices = ((j["body"] as? [String: Any])?["devices"] as? [[String: Any]]) ?? []
            stationName = (devices.first?["station_name"] as? String ?? devices.first?["home_name"] as? String).map(Climate.roomName)
            netatmoError = modules.isEmpty ? "Your Netatmo account has no weather station." : nil
            updatedAt = Date()
            // The station uploads every 10 minutes: read again 30 s after its next upload.
            let last = modules.compactMap(\.time).max() ?? Date()
            let next = last.addingTimeInterval(630)
            stationsDue = next > Date().addingTimeInterval(60) ? min(next, Date().addingTimeInterval(900)) : Date().addingTimeInterval(300)
        } catch {
            netatmoError = (error as? TadoError)?.message ?? "Netatmo: \(error.localizedDescription)"
            stationsDue = Date().addingTimeInterval(600)
        }
    }

    private func refreshChart() async {
        chartDue = Date().addingTimeInterval(1800)
        let from = Date().addingTimeInterval(-24 * 3600)
        var out: [String: [Double]] = [:]
        for m in modules where m.kind == .indoor || m.kind == .outdoor {
            if out[m.kind.rawValue] != nil { continue }
            var q = "device_id=\(m.station)&scale=30min&type=temperature&optimize=false&real_time=true&date_begin=\(Int(from.timeIntervalSince1970))"
            if m.kind != .indoor { q += "&module_id=\(m.id)" }
            guard let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let j = try? await netatmoJSON("/api/getmeasure?" + enc) else { continue }
            let values = Climate.measure(j).map(\.1)
            if values.count > 1 { out[m.kind.rawValue] = values }
        }
        if !out.isEmpty { chart = out; chartFrom = from }
    }

    private func netatmoJSON(_ path: String) async throws -> [String: Any] {
        let token = try await netatmoAccess()
        var req = URLRequest(url: URL(string: "https://api.netatmo.com" + path)!, timeoutInterval: 20)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        case 401, 403:
            if var t = netatmo { t.expiresAt = 0; setNetatmo(t) }
            throw TadoError(message: "Netatmo refused the access. Deckhand tries again in a few minutes.")
        case 429: throw TadoError(message: "Netatmo asked Deckhand to slow down.")
        default: throw TadoError(message: "Netatmo answered \(code).")
        }
    }

    private func netatmoAccess() async throws -> String {
        guard let t = netatmo else { throw TadoError(message: "Connect Netatmo under Apps → Climate.") }
        if t.expiresAt - Int(Date().timeIntervalSince1970) > 120 { return t.access }
        let (data, http) = try await post("https://api.netatmo.com/oauth2/token", ["grant_type": "refresh_token", "refresh_token": t.refresh,
                                                                                    "client_id": trimmed(netatmoClientID), "client_secret": trimmed(netatmoClientSecret)])
        if http.statusCode == 400 || http.statusCode == 401 {
            setNetatmo(nil); modules = []; chart = [:]
            WireLog.shared.event("netatmo: refresh refused (\(http.statusCode)); disconnected")
            throw TadoError(message: "Netatmo's access has expired. Connect again under Apps → Climate.")
        }
        guard http.statusCode == 200, let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = j["access_token"] as? String else { throw TadoError(message: "Netatmo's sign-in answered \(http.statusCode).") }
        var n = t
        n.access = access
        n.expiresAt = Int(Date().timeIntervalSince1970) + ((j["expires_in"] as? NSNumber)?.intValue ?? 10800)
        if let r = j["refresh_token"] as? String { n.refresh = r }
        setNetatmo(n)
        return access
    }

    /// Opens Netatmo's authorize page and waits (up to ten minutes) for the browser to come back to the loopback callback.
    func connectNetatmo() {
        guard netatmoHasClient, !netatmoConnecting else { return }
        netatmoConnectTask?.cancel()
        netatmoError = nil; netatmoConnecting = true
        netatmoConnectTask = Task { [weak self] in
            guard let self else { return }
            defer { self.netatmoConnecting = false; self.callback?.stop(); self.callback = nil }
            let state = OAuthCallback.randomState()
            let cb = OAuthCallback(state: state, spec: .netatmo)
            self.callback = cb
            guard let port = await cb.start() else { self.netatmoError = "Could not open the callback on this Mac."; return }
            let redirect = "http://localhost:\(port)/netatmo/callback"
            var c = URLComponents(string: "https://api.netatmo.com/oauth2/authorize")!
            c.queryItems = [.init(name: "client_id", value: self.trimmed(self.netatmoClientID)), .init(name: "redirect_uri", value: redirect),
                            .init(name: "scope", value: "read_station"), .init(name: "state", value: state)]
            NSWorkspace.shared.open(c.url!)
            let result = await cb.wait(timeout: 600)
            if Task.isCancelled { return }
            switch result {
            case .none: self.netatmoError = "No answer from Netatmo within ten minutes. Press Connect again."
            case .some(.failure(let msg)): self.netatmoError = msg
            case .some(.success(let code, _)):
                do {
                    let (data, http) = try await self.post("https://api.netatmo.com/oauth2/token", [
                        "grant_type": "authorization_code", "code": code, "redirect_uri": redirect, "scope": "read_station",
                        "client_id": self.trimmed(self.netatmoClientID), "client_secret": self.trimmed(self.netatmoClientSecret)])
                    guard http.statusCode == 200, let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          let access = j["access_token"] as? String, let refresh = j["refresh_token"] as? String else {
                        self.netatmoError = "Netatmo refused the connection (\(http.statusCode)). Check the Client ID and secret, and leave the app's Redirect URI empty."
                        return
                    }
                    self.setNetatmo(NetatmoTokens(access: access, refresh: refresh,
                                                  expiresAt: Int(Date().timeIntervalSince1970) + ((j["expires_in"] as? NSNumber)?.intValue ?? 10800)))
                    self.stationsDue = .distantPast; self.chartDue = .distantPast
                    WireLog.shared.event("netatmo: connected")
                    self.forced = true; self.wake.signal()
                } catch { self.netatmoError = "Connecting failed: \(error.localizedDescription)" }
            }
        }
    }
    func cancelNetatmoConnect() { netatmoConnectTask?.cancel(); netatmoConnectTask = nil; callback?.stop(); callback = nil; netatmoConnecting = false }

    /// The fallback when the browser sign-in does not work: a refresh token from the token generator on the app's page
    /// at dev.netatmo.com (scope read_station). The first read trades it for an access token.
    func useNetatmoRefreshToken(_ token: String) {
        let t = trimmed(token)
        guard !t.isEmpty else { return }
        setNetatmo(NetatmoTokens(access: "", refresh: t, expiresAt: 0))
        netatmoError = nil; stationsDue = .distantPast; chartDue = .distantPast; forced = true; wake.signal()
    }
    func disconnectNetatmo() { setNetatmo(nil); modules = []; chart = [:]; stationName = nil; netatmoError = nil; WireLog.shared.event("netatmo: disconnected") }

    // MARK: helpers

    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func post(_ url: String, _ form: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: URL(string: url)!, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(StravaFeed.form(form).utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw TadoError(message: "No answer.") }
        return (data, http)
    }

    nonisolated static func degrees(_ c: Double) -> String { c == c.rounded() ? "\(Int(c))°" : String(format: "%.1f°", c) }

    // MARK: what the bar gets

    func snapshot() -> [String: Any] {
        var out: [String: Any] = ["at": Int(Date().timeIntervalSince1970)]
        var t: [String: Any] = ["connected": tado != nil]
        if let n = homeName { t["home"] = n }
        if let h = heating {
            func ts(_ d: Date?) -> Any { d.map { Int($0.timeIntervalSince1970) as Any } ?? NSNull() }
            func opt<T>(_ v: T?) -> Any { v.map { $0 as Any } ?? NSNull() }
            t["heating"] = ["on": h.on, "target": opt(h.target), "inside": opt(h.inside), "humidity": opt(h.humidity), "power": opt(h.power),
                            "manual": h.manual, "ends": ts(h.manualEnds), "untilSchedule": h.untilSchedule, "nextAt": ts(h.nextAt),
                            "nextOn": opt(h.nextOn), "nextTarget": opt(h.nextTarget), "online": h.online, "openWindow": h.openWindow, "away": h.away]
            t["readAt"] = ts(heatingAt)
        }
        if let p = pending { t["pending"] = p }
        if let e = actionError ?? tadoError { t["error"] = e }
        if let c = callsLeft { t["callsLeft"] = c }
        out["tado"] = t
        var n: [String: Any] = ["connected": netatmo != nil, "hasClient": netatmoHasClient]
        if let s = stationName { n["station"] = s }
        n["modules"] = modules.map { m -> [String: Any] in
            var d: [String: Any] = ["name": m.name, "kind": m.kind.rawValue, "reachable": m.reachable]
            if let v = m.temperature { d["t"] = v }
            if let v = m.humidity { d["h"] = v }
            if let v = m.co2 { d["co2"] = v; d["co2Level"] = Climate.co2Level(v) }
            if let v = m.pressure { d["p"] = v }
            if let v = m.min { d["min"] = v }
            if let v = m.max { d["max"] = v }
            if let v = m.trend { d["trend"] = v }
            if let v = m.rain1h { d["rain1h"] = v }
            if let v = m.rain24h { d["rain24h"] = v }
            if let v = m.wind { d["wind"] = v }
            if let v = m.gust { d["gust"] = v }
            if let v = m.battery { d["battery"] = v }
            if let v = m.time { d["time"] = Int(v.timeIntervalSince1970) }
            return d
        }
        if !chart.isEmpty { n["chart"] = chart.merging(["from": [chartFrom?.timeIntervalSince1970 ?? 0]]) { a, _ in a } }
        if let e = netatmoError { n["error"] = e }
        out["netatmo"] = n
        return out
    }

    /// Deckhand Home's line: a manual heating setting with its end, else the indoor and outdoor temperature.
    func homeLine() -> (line: String, tone: String)? {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        if let h = heating, h.manual, h.on, let t = h.target {
            let until = h.untilSchedule ? " until the schedule" : h.manualEnds.map { " until \(f.string(from: $0))" } ?? ""
            return ("Heating to \(Self.degrees(t))\(until)", "live")
        }
        let inside = modules.first { $0.kind == .indoor }?.temperature ?? heating?.inside
        let outside = modules.first { $0.kind == .outdoor }?.temperature
        guard inside != nil || outside != nil else { return nil }
        let parts = [inside.map { String(format: "%.1f° inside", $0) }, outside.map { String(format: "%.1f° outside", $0) }].compactMap { $0 }
        return (parts.joined(separator: " · "), heating?.on == true && (heating?.power ?? 0) > 0 ? "live" : "")
    }
}
