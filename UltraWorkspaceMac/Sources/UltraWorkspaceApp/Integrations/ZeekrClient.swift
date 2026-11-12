import Foundation
import Security

/// What Deckhand needs to talk to Zeekr's EU app gateway on the owner's behalf: the four values the Zeekr phone app
/// sends with every request. Ported from Fast Charge Companion (FCC, `frontend/src-tauri/src/zeekr.rs` and
/// `keychain.rs`), which gets them the same way: there is no username/password login a third party can do, because
/// the login's `identifier` is RSA-encrypted by the phone app and `X-VIN` is the VIN encrypted with a key the app
/// derives per device binding. So the values are taken from FCC's Keychain items (with the owner's approval) or
/// pasted from a capture of the phone app (Proxyman: the `Authorization`, `X-VIN` and `X-DEVICE-ID` headers).
struct ZeekrCredentials: Codable, Equatable, Sendable {
    /// The JWT without its "Bearer " prefix.
    var accessToken: String
    /// Only when known (FCC's Settings never stores one); without it the access token cannot be renewed here.
    var refreshToken: String?
    /// The `X-VIN` header as the phone app sends it (Base64 of the AES-encrypted VIN), never the plain VIN.
    var encryptedVin: String
    /// The `X-DEVICE-ID` header (an uppercase UUID).
    var deviceId: String
    /// "fcc" or "pasted": where they came from, so the settings can offer the matching way to renew them.
    var source: String

    /// Cleans pasted values the way FCC does: no whitespace or line breaks inside, no "Bearer " prefix.
    static func clean(_ s: String) -> String {
        var t = s.filter { !$0.isWhitespace || $0 == " " }.trimmingCharacters(in: .whitespaces)
        if t.lowercased().hasPrefix("bearer ") { t = String(t.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        return t
    }
    var complete: Bool { !accessToken.isEmpty && !encryptedVin.isEmpty && !deviceId.isEmpty }

    /// The access token's expiry, read from the JWT's `exp` claim (no network, no signature check: only to know when
    /// to renew and to show "valid until"). Zeekr's access tokens live 7 days, refresh tokens 30.
    var accessExpires: Date? { Self.jwtExpiry(accessToken) }
    static func jwtExpiry(_ jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64), let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let exp = obj["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    // MARK: FCC's Keychain items

    /// FCC keeps its values as generic passwords under this service (`keychain.rs`).
    static let fccService = "com.fcc.zeekr"

    enum ImportError: LocalizedError {
        case notFound, denied, other(OSStatus)
        var errorDescription: String? {
            switch self {
            case .notFound: return "FCC has no Zeekr sign-in in the Keychain (FCC → Settings → Zeekr API first)."
            case .denied: return "Not allowed: macOS asked whether Deckhand may read FCC's Keychain items and the answer was no."
            case .other(let s): return "Keychain error \(s)."
            }
        }
    }

    /// Reads FCC's access token, refresh token, encrypted VIN and device ID from the login Keychain. The items belong
    /// to FCC, so macOS asks the owner once per item whether Deckhand may read them; only call this from a button.
    /// Deckhand copies the values into its own user-only file and does not touch FCC's items again.
    static func importFromFCC() throws -> ZeekrCredentials {
        func read(_ account: String) throws -> String? {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: fccService,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            var out: CFTypeRef?
            let s = SecItemCopyMatching(q as CFDictionary, &out)
            switch s {
            case errSecSuccess: return (out as? Data).flatMap { String(data: $0, encoding: .utf8) }.map(clean).flatMap { $0.isEmpty ? nil : $0 }
            case errSecItemNotFound: return nil
            case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed: throw ImportError.denied
            default: throw ImportError.other(s)
            }
        }
        guard let access = try read("access_token"), let vin = try read("encrypted_vin") else { throw ImportError.notFound }
        // FCC makes up a device ID when none was pasted; the gateway has accepted that so far, so it is used as is.
        guard let device = try read("device_id") else { throw ImportError.notFound }
        return ZeekrCredentials(accessToken: access, refreshToken: try read("refresh_token"), encryptedVin: vin, deviceId: device, source: "fcc")
    }
}

/// Zeekr's EU app gateway (`eu-snc-tsp-api-gw.zeekrlife.com`), read-only: the vehicle status and the token refresh.
/// The headers are FCC's `build_headers` one for one: the phone app's identity (X-APP-ID, X-PROJECT-ID, X-P, user
/// agent), a fresh uppercase UUID nonce and a millisecond timestamp per request, and "signature version 1.0". There is
/// no request signature beyond those: FCC sends none and the gateway accepts that (an HMAC header exists for a few
/// endpoints this app does not use). Remote commands (climate, lock, send-to-car) are deliberately left out.
enum ZeekrClient {
    static let baseURL = "https://eu-snc-tsp-api-gw.zeekrlife.com"
    static let appID = "ZEEKRCNCH001M0001"
    static let projectID = "ZEEKR_EU"
    static let appVersion = "2.9.5"

    enum Failure: LocalizedError, Equatable {
        /// The access token is expired or refused (HTTP 401, codes 100001/100002): renew or sign in again.
        case unauthorized
        /// The refresh token is expired too (100003), or there is none: a new sign-in is needed.
        case signInNeeded
        /// The gateway could not decrypt `X-VIN` (code 079025, seen live 2026-11-12 with a made-up value): the
        /// encrypted VIN or the device ID does not belong to this sign-in. Retrying will not help.
        case badVin
        case forbidden
        case api(code: String, message: String)
        case http(Int)
        case decode
        var errorDescription: String? {
            switch self {
            case .unauthorized: return "Zeekr refused the access token (expired)."
            case .signInNeeded: return "The Zeekr sign-in has expired: connect again in Apps → Zeekr."
            case .badVin: return "Zeekr could not read the encrypted VIN (X-VIN): connect again in Apps → Zeekr."
            case .forbidden: return "Zeekr refused access (403)."
            case .api(let c, let m): return "Zeekr: \(m.isEmpty ? "error" : m) (\(c))"
            case .http(let s): return "Zeekr answered HTTP \(s)."
            case .decode: return "Zeekr sent something Deckhand cannot read."
            }
        }
    }

    /// FCC's header set. `token` is nil for the refresh call.
    static func headers(token: String?, vin: String, device: String) -> [String: String] {
        var h: [String: String] = [
            "X-APP-ID": appID, "X-PROJECT-ID": projectID,
            "X-TIMESTAMP": String(Int64(Date().timeIntervalSince1970 * 1000)),
            "X-VIN": vin, "X-DEVICE-ID": device,
            "X-API-SIGNATURE-NONCE": UUID().uuidString.uppercased(), "X-API-SIGNATURE-VERSION": "1.0",
            "X-PLATFORM": "APP", "X-P": "iOS", "X-APP-OS-VERSION": appVersion,
            "Content-Type": "application/json;charset=UTF-8", "Accept": "*/*", "Accept-Language": "nl-NL",
            "User-Agent": "ZUOverseaSEAApp/\(appVersion) (iPhone; iOS 26.2; Scale/3.00)",
        ]
        if let token { h["Authorization"] = "Bearer " + token }
        return h
    }

    /// A session that keeps nothing on disk (no cookie or URL cache with the car's data in it).
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20; c.timeoutIntervalForResource = 30
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    /// One call, unwrapped from Zeekr's `{code, msg, data, success}` envelope.
    private static func call(_ path: String, method: String = "GET", body: [String: Any]? = nil, headers: [String: String]) async throws -> Any {
        guard let url = URL(string: baseURL + path) else { throw Failure.decode }
        var req = URLRequest(url: url)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw Failure.unauthorized }
        if status == 403 { throw Failure.forbidden }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw status >= 200 && status < 300 ? Failure.decode : Failure.http(status)
        }
        return try unwrap(obj)
    }

    /// The envelope: "000000" is success; the token codes map to `unauthorized` / `signInNeeded`.
    static func unwrap(_ obj: [String: Any]) throws -> Any {
        let code = (obj["code"] as? String) ?? (obj["code"].map { "\($0)" } ?? "")
        let msg = (obj["msg"] as? String) ?? (obj["message"] as? String) ?? ""
        switch code {
        case "000000": break
        case "100001", "100002": throw Failure.unauthorized
        case "100003": throw Failure.signInNeeded
        case "079025": throw Failure.badVin
        default: throw Failure.api(code: code, message: msg)
        }
        guard let d = obj["data"], !(d is NSNull) else { throw Failure.api(code: "NO_DATA", message: "no data") }
        return d
    }

    /// `GET /ms-vehicle-status/api/v1.0/vehicle/status/latest?latest=false&target=new`, as FCC asks it: the status the
    /// gateway last heard from the car (`latest=false` does not wake the car).
    static func status(_ c: ZeekrCredentials) async throws -> [String: Any] {
        let d = try await call("/ms-vehicle-status/api/v1.0/vehicle/status/latest?latest=false&target=new",
                               headers: headers(token: c.accessToken, vin: c.encryptedVin, device: c.deviceId))
        guard let dict = d as? [String: Any] else { throw Failure.decode }
        return dict
    }

    /// `POST /ms-user-auth/v1.0/auth/refresh {"refreshToken"}` → new access and refresh tokens. Documented in FCC's
    /// API reference but never called by FCC itself, so this is untested against the gateway.
    static func refresh(_ c: ZeekrCredentials) async throws -> ZeekrCredentials {
        guard let rt = c.refreshToken, !rt.isEmpty else { throw Failure.signInNeeded }
        let d: Any
        do { d = try await call("/ms-user-auth/v1.0/auth/refresh", method: "POST", body: ["refreshToken": rt],
                                headers: headers(token: nil, vin: c.encryptedVin, device: c.deviceId)) }
        catch Failure.unauthorized { throw Failure.signInNeeded }
        guard let dict = d as? [String: Any], let at = dict["accessToken"] as? String, !at.isEmpty else { throw Failure.decode }
        var next = c
        next.accessToken = ZeekrCredentials.clean(at)
        if let r = dict["refreshToken"] as? String, !r.isEmpty { next.refreshToken = ZeekrCredentials.clean(r) }
        return next
    }
}

/// The parts of a `status/latest` answer the bar shows. Zeekr sends most numbers as strings ("78", "245") and a few
/// as numbers (odometer), so every field is read leniently. Meanings as documented and used by FCC (`useApi.js`).
struct ZeekrStatus: Equatable, Sendable {
    var soc: Double?
    var rangeKm: Int?
    var targetSoc: Int?
    /// `chargeSts`: 1 charging, 2 complete, 3 not charging, 4 paused, 5 error.
    var chargeSts: Int?
    /// `statusOfChargerConnection`: 0 none, 1 AC, 2 DC.
    var connection: Int?
    /// `timeToFullyCharged` in minutes; 2047 means "not known" and is dropped.
    var minutesToFull: Int?
    /// From the DC pile's voltage and current; nil when either is 0 (AC charging reports neither).
    var dcKW: Double?
    var locked: Bool?
    /// Doors, trunk, hood, charge lid, windows and sunroof that are open: "driver", "passenger", "rearLeft",
    /// "rearRight", "trunk", "hood", "chargeLid", "window…", "sunroof".
    var open: [String] = []
    var climateOn = false
    var interiorTemp: Double?
    /// kPa, front left, front right, rear left, rear right.
    var tyresKPa: [Double?] = [nil, nil, nil, nil]
    var tyreWarnings: [Bool] = [false, false, false, false]
    var odometerKm: Int?
    var lat: Double?, lon: Double?
    /// When the car last reported (`updateTime`, ms).
    var updated: Date?

    var charging: Bool { chargeSts == 1 }
    var plugged: Bool { (connection ?? 0) != 0 || [1, 2, 4].contains(chargeSts ?? 0) }
    var dc: Bool { connection == 2 || (dcKW ?? 0) > 0 }

    static func num(_ v: Any?) -> Double? {
        switch v {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }
    static func flag(_ v: Any?) -> Bool {
        switch v {
        case let b as Bool: return b
        case let n as NSNumber: return n.intValue == 1
        case let s as String: return s == "1" || s.lowercased() == "true"
        default: return false
        }
    }

    init() {}
    init(_ d: [String: Any]) {
        let add = d["additionalVehicleStatus"] as? [String: Any] ?? [:]
        let ev = add["electricVehicleStatus"] as? [String: Any] ?? [:]
        let cl = add["climateStatus"] as? [String: Any] ?? [:]
        let sf = add["drivingSafetyStatus"] as? [String: Any] ?? [:]
        let mt = add["maintenanceStatus"] as? [String: Any] ?? [:]
        let pos = (d["basicVehicleStatus"] as? [String: Any])?["position"] as? [String: Any] ?? [:]
        let n = Self.num
        soc = n(ev["chargeLevel"])
        rangeKm = n(ev["distanceToEmptyOnBatteryOnly"]).map { Int($0.rounded()) }
        targetSoc = n(ev["chargeTargetSoc"]).map { Int($0) }.flatMap { $0 > 0 && $0 <= 100 ? $0 : nil }
        chargeSts = n(ev["chargeSts"]).map { Int($0) }
        connection = n(ev["statusOfChargerConnection"]).map { Int($0) }
        if ev["isCharging"] as? Bool == true, chargeSts == nil { chargeSts = 1 }
        minutesToFull = n(ev["timeToFullyCharged"]).map { Int($0) }.flatMap { $0 > 0 && $0 < 2047 ? $0 : nil }
        let u = n(ev["dcChargePileUAct"]) ?? 0, i = n(ev["dcChargePileIAct"]) ?? 0
        dcKW = u != 0 && i != 0 ? abs(u * i) / 1000 : nil
        if let c = sf["centralLockingStatus"] { locked = Self.flag(c) }
        let doors: [(String, String)] = [("doorOpenStatusDriver", "driver"), ("doorOpenStatusPassenger", "passenger"),
                                        ("doorOpenStatusRearLeft", "rearLeft"), ("doorOpenStatusRearRight", "rearRight"),
                                        ("trunkOpenStatus", "trunk"), ("engineHoodOpenStatus", "hood"), ("chargeLidOpenStatus", "chargeLid"),
                                        ("windowStatusDriver", "windowDriver"), ("windowStatusPassenger", "windowPassenger"),
                                        ("windowStatusRearLeft", "windowRearLeft"), ("windowStatusRearRight", "windowRearRight"),
                                        ("sunroofOpenStatus", "sunroof")]
        open = doors.filter { Self.flag(sf[$0.0]) }.map(\.1)
        climateOn = Self.flag(cl["preClimateActive"]) || Self.flag(cl["acOnSts"])
        interiorTemp = n(cl["interiorTemp"])
        tyresKPa = ["tyreStatusDriver", "tyreStatusPassenger", "tyreStatusDriverRear", "tyreStatusPassengerRear"].map { n(mt[$0]).flatMap { $0 > 0 ? $0 : nil } }
        tyreWarnings = ["tyrePressureWarningDriver", "tyrePressureWarningPassenger", "tyrePressureWarningDriverRear", "tyrePressureWarningPassengerRear"].map { Self.flag(mt[$0]) }
        odometerKm = n(mt["odometer"]).map { Int($0) }
        if let la = n(pos["latitude"]), let lo = n(pos["longitude"]), la != 0 || lo != 0, abs(la) <= 90, abs(lo) <= 180 { lat = la; lon = lo }
        updated = (n(d["updateTime"]) ?? n(d["timestamp"])).map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}
