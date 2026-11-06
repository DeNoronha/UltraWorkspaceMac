import Foundation
import Compression
import UltraBarKit

/// Same comparison as the app's BarSoftwareStatus: newer when the release's versionCode is above the bar's.
struct BarSoftwareProbe {
    var launcher: (String, Int)?
    var bridge: (String, Int)?
    var release: VendorRelease.Release
    init(launcher: (String, Int)?, bridge: (String, Int)?, release: VendorRelease.Release) { self.launcher = launcher; self.bridge = bridge; self.release = release }
    var launcherNewer: Bool { (release.launcher?.versionCode ?? 0) > (launcher?.1 ?? 0) && launcher != nil }
    var bridgeNewer: Bool { (release.bridge?.versionCode ?? 0) > (bridge?.1 ?? 0) && bridge != nil }
}

setvbuf(stdout, nil, _IONBF, 0) // line-by-line output even when piped/killed

// `kitcheck discover` — run the app's real Discovery from the terminal (which
// already has Local Network permission) to prove the code works against hardware.
if let i = CommandLine.arguments.firstIndex(of: "apk"), CommandLine.arguments.count > i + 1 {
    let info = try ApkInfo.read(apk: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    print("\(info.package) \(info.versionName) (\(info.versionCode))"); exit(0)
}
if CommandLine.arguments.contains("weather") {
    let city = CommandLine.arguments.last ?? "Amsterdam"
    do {
        guard let p = try await OpenMeteo.geocode(city) else { print("no geocode for \(city)"); exit(2) }
        print("geocoded \(city) -> \(p.name), \(p.country)  (\(p.latitude), \(p.longitude))")
        let now = try await OpenMeteo.current(latitude: p.latitude, longitude: p.longitude, metric: true, placeName: p.name)
        print("now: \(Int(now.temperature.rounded()))\(now.unitSuffix)  code=\(now.code) sky=\(now.sky.label) day=\(now.isDay) hum=\(now.humidity ?? -1)% wind=\(now.windSpeed ?? 0)\(now.windSuffix) @ \(now.place)")
    } catch { print("weather error: \(error)"); exit(1) }
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "e2e") {
    let ip = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "127.0.0.1"
    exit(Int32(await E2E.run(ip: ip)))
}

// `kitcheck linkwatch <ip> <serial> [seconds] [noreply]` — open a persistent link
// with the app's stored token and print every push the CoreBar sends; reply
// with plausible values unless "noreply" is given. Diagnoses push cadence.
if let i = CommandLine.arguments.firstIndex(of: "linkwatch"), CommandLine.arguments.count > i + 2 {
    let ip = CommandLine.arguments[i + 1], serial = CommandLine.arguments[i + 2]
    let secs = CommandLine.arguments.count > i + 3 ? (Int(CommandLine.arguments[i + 3]) ?? 30) : 30
    let noReply = CommandLine.arguments.contains("noreply")
    guard let token = Store.shared.loadToken(serial: serial) else { print("no stored token for \(serial)"); exit(2) }
    let link = CoreBarLink(ip: ip, token: token, certPin: Store.shared.certPin(for: serial))
    let t0 = Date()
    @Sendable func stamp() -> String { String(format: "%6.2fs", Date().timeIntervalSince(t0)) }
    await link.start(onState: { st in print("\(stamp()) link \(st)") }) { type, payloadJSON in
        let p = payloadJSON.flatMap { String(data: $0, encoding: .utf8) } ?? "-"
        print("\(stamp()) PUSH \(type) payload=\(p)\(noReply ? "  (not replying)" : "")")
        if noReply { return nil }
        switch type {
        case "CPU", "MEMORY", "STORAGE": return CoreBarLink.json(42)
        case "NETWORK": return CoreBarLink.json(["totalReceived": 1_000_000, "totalSent": 500_000])
        case "GET_VOLUME": return CoreBarLink.json(50)
        case "SET_VOLUME", "SET_BRIGHTNESS": return payloadJSON
        case "GET_BRIGHTNESS": return CoreBarLink.json(50)
        default: return Data()
        }
    }
    try? await Task.sleep(nanoseconds: UInt64(secs) * 1_000_000_000)
    print("\(stamp()) done — pushes handled: \(await link.pushesHandled)")
    await link.stop()
    exit(0)
}

// `kitcheck switchpage <ip> <serial> <pageId>` — TRIGGER_PROFILE_CHANGE with the stored token.
if let i = CommandLine.arguments.firstIndex(of: "switchpage"), CommandLine.arguments.count > i + 3 {
    let ip = CommandLine.arguments[i + 1], serial = CommandLine.arguments[i + 2], page = CommandLine.arguments[i + 3]
    guard let token = Store.shared.loadToken(serial: serial) else { print("no stored token"); exit(2) }
    let s = CoreBarSession(ip: ip, token: token, certPin: Store.shared.certPin(for: serial))
    do { print(try await s.switchPage(id: page)) } catch { print("switch failed: \(error)"); exit(1) }
    exit(0)
}

// `kitcheck cubewifi <ip> <serial> <moduleSerial> <ssid> [password]` — write the cube's Wi-Fi (property 7).
if let i = CommandLine.arguments.firstIndex(of: "cubewifi"), CommandLine.arguments.count > i + 4 {
    let ip = CommandLine.arguments[i + 1], serial = CommandLine.arguments[i + 2], mod = CommandLine.arguments[i + 3]
    let ssid = CommandLine.arguments[i + 4], pw = CommandLine.arguments.count > i + 5 ? CommandLine.arguments[i + 5] : ""
    guard let token = Store.shared.loadToken(serial: serial) else { print("no stored token"); exit(2) }
    let s = CoreBarSession(ip: ip, token: token, certPin: Store.shared.certPin(for: serial))
    let code = await s.writeModuleWiFi(serial: mod, CoreBarSession.ModuleWiFi(ssid: ssid, password: pw))
    print("write wifi \(ssid): code \(code.map(String.init) ?? "nil")")
    exit(code == 200 ? 0 : 1)
}

// `kitcheck readprop <ip> <serial> <deviceId> <propertyId>` — raw MODULE_PROPERTY_READ reply.
if let i = CommandLine.arguments.firstIndex(of: "readprop"), CommandLine.arguments.count > i + 4 {
    let ip = CommandLine.arguments[i + 1], serial = CommandLine.arguments[i + 2]
    let dev = Int(CommandLine.arguments[i + 3]) ?? 256, prop = Int(CommandLine.arguments[i + 4]) ?? 7
    guard let token = Store.shared.loadToken(serial: serial) else { print("no stored token"); exit(2) }
    let s = CoreBarSession(ip: ip, token: token, certPin: Store.shared.certPin(for: serial))
    let modSerial = CommandLine.arguments.count > i + 5 ? CommandLine.arguments[i + 5] : serial
    do { print(try await s.rawRequest(act: Proto.actReadProp, data: ["serialNo": modSerial, "deviceId": dev, "propertyId": prop, "extra": NSNull()], timeout: 8)) }
    catch { print("read failed: \(error)") }
    exit(0)
}

// `kitcheck raw <ip> <serial> <act> [json-object]` — any act with a JSON object as data (default {}), prints the reply.
if let i = CommandLine.arguments.firstIndex(of: "raw"), CommandLine.arguments.count > i + 3, let act = Int(CommandLine.arguments[i + 3]) {
    let ip = CommandLine.arguments[i + 1], serial = CommandLine.arguments[i + 2]
    var payload: [String: Any] = [:]
    if CommandLine.arguments.count > i + 4, let d = CommandLine.arguments[i + 4].data(using: .utf8),
       let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { payload = j }
    guard let token = Store.shared.loadToken(serial: serial) else { print("no stored token"); exit(2) }
    let s = CoreBarSession(ip: ip, token: token, certPin: Store.shared.certPin(for: serial))
    do { print(try await s.rawRequest(act: act, data: payload, timeout: 10)) } catch { print("request failed: \(error)") }
    exit(0)
}

// `kitcheck writeprop <ip> <serial> <moduleSerial> <propertyId> <int|true|false>` — MODULE_PROPERTY_WRITE, prints the reply code.
if let i = CommandLine.arguments.firstIndex(of: "writeprop"), CommandLine.arguments.count > i + 5 {
    let ip = CommandLine.arguments[i + 1], serial = CommandLine.arguments[i + 2], mod = CommandLine.arguments[i + 3]
    let prop = Int(CommandLine.arguments[i + 4]) ?? 0, raw = CommandLine.arguments[i + 5]
    let value: Any = raw == "true" ? true : raw == "false" ? false : (Int(raw).map { $0 as Any } ?? raw)
    guard let token = Store.shared.loadToken(serial: serial) else { print("no stored token"); exit(2) }
    let s = CoreBarSession(ip: ip, token: token, certPin: Store.shared.certPin(for: serial))
    let code = await s.writeProperty(serial: mod, propertyId: prop, value: value, timeout: 8)
    print("write property \(prop) = \(raw): code \(code.map(String.init) ?? "nil")")
    exit(code == 200 ? 0 : 1)
}

// `kitcheck upload1 <ip> <serial> <moduleSerial> <file.tgz>` — ONE /upload POST, raw reply, no retries.
if let i = CommandLine.arguments.firstIndex(of: "upload1"), CommandLine.arguments.count > i + 4 {
    let ip = CommandLine.arguments[i + 1], serial = CommandLine.arguments[i + 2], mod = CommandLine.arguments[i + 3]
    guard let tgz = FileManager.default.contents(atPath: CommandLine.arguments[i + 4]) else { print("cannot read tgz"); exit(2) }
    guard let token = Store.shared.loadToken(serial: serial) else { print("no stored token"); exit(2) }
    let s = CoreBarSession(ip: ip, token: token, certPin: Store.shared.certPin(for: serial))
    let t0 = Date()
    let r = await s.uploadOnce(serial: mod, tgz: tgz)
    print("upload \(tgz.count) B → \(r.accepted ? "accepted" : "rejected") after \(String(format: "%.1f", Date().timeIntervalSince(t0))) s: \(r.text)")
    exit(r.accepted ? 0 : 1)
}

// `kitcheck page <ip> <serial> <page-id>` — select a page on the bar (TRIGGER_PROFILE_CHANGE 1103).
if let i = CommandLine.arguments.firstIndex(of: "page"), CommandLine.arguments.count > i + 3 {
    let ip = CommandLine.arguments[i + 1], serial = CommandLine.arguments[i + 2], id = CommandLine.arguments[i + 3]
    guard let token = Store.shared.loadToken(serial: serial) else { print("no stored token"); exit(2) }
    let s = CoreBarSession(ip: ip, token: token, certPin: Store.shared.certPin(for: serial))
    do { print(try await s.switchPage(id: id)) } catch { print("request failed: \(error)"); exit(1) }
    exit(0)
}

// `kitcheck raw <ip> <serial> <act> <json-file>` — send one request with the file's JSON as `data`, print the reply.
if let i = CommandLine.arguments.firstIndex(of: "raw"), CommandLine.arguments.count > i + 4 {
    let ip = CommandLine.arguments[i + 1], serial = CommandLine.arguments[i + 2], act = Int(CommandLine.arguments[i + 3]) ?? 0
    guard let d = FileManager.default.contents(atPath: CommandLine.arguments[i + 4]),
          let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { print("cannot read JSON object"); exit(2) }
    guard let token = Store.shared.loadToken(serial: serial) else { print("no stored token"); exit(2) }
    let s = CoreBarSession(ip: ip, token: token, certPin: Store.shared.certPin(for: serial))
    do { print(try await s.rawRequest(act: act, data: obj, timeout: 15)) } catch { print("request failed: \(error)"); exit(1) }
    exit(0)
}

// modules <ip> <serial> — the app's Find modules from the command line: 16 s scan, then the gateway
// config is rewritten with every module ever seen on this bar (so a sleeping DotKey is kept).
if let i = CommandLine.arguments.firstIndex(of: "modules"), CommandLine.arguments.count > i + 2 {
    let ip = CommandLine.arguments[i + 1], serial = CommandLine.arguments[i + 2]
    guard let token = Store.shared.loadToken(serial: serial) else { print("no stored token"); exit(2) }
    let s = CoreBarSession(ip: ip, token: token, certPin: Store.shared.certPin(for: serial))
    var priorList: [[String: Any]] = []
    if let d = Store.shared.loadEndpoints(serial: serial), let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] { priorList = arr }
    let have = Set(priorList.compactMap { ($0["serialNumber"] as? String) ?? ($0["serialNo"] as? String) })
    priorList += Store.shared.knownModules(corebar: serial).values.filter { !have.contains((($0["serialNumber"] as? String) ?? ($0["serialNo"] as? String) ?? "")) }
    do {
        let (mods, endpointsJSON, diag) = try await s.provision(priorEndpoints: try? JSONSerialization.data(withJSONObject: priorList))
        Store.shared.saveEndpoints(endpointsJSON, serial: serial)
        if let arr = try? JSONSerialization.jsonObject(with: endpointsJSON) as? [[String: Any]] { Store.shared.rememberModules(arr, corebar: serial) }
        print(diag); for m in mods { print("  \(m.type) \(m.serial) online=\(m.online)") }
    } catch { print("provision failed: \(error)"); exit(1) }
    exit(0)
}

// apps <ip> <serial> — the bar's installed apps (GET_APP_LIST 1000 "ALL") with the page-card / web-UI flags.
if let i = CommandLine.arguments.firstIndex(of: "apps"), CommandLine.arguments.count > i + 2 {
    let ip = CommandLine.arguments[i + 1], serial = CommandLine.arguments[i + 2]
    guard let token = Store.shared.loadToken(serial: serial) else { print("no stored token"); exit(2) }
    let s = CoreBarSession(ip: ip, token: token, certPin: Store.shared.certPin(for: serial))
    do {
        for a in try await s.listApps() {
            print("\(a.appName) | \(a.packageName) | \(a.versionName) | system=\(a.systemApp) card=\(a.allowProfile) screensaver=\(a.isScreensaver) port=\(a.port.map(String.init) ?? "-") token=\(a.sessionToken == nil ? "-" : "yes") icon=\(a.iconUrl ?? "-")")
        }
    } catch { print("request failed: \(error)"); exit(1) }
    exit(0)
}

// app <ip> <serial> status|install|uninstall <packageName> — the bar's app store (APP_MANAGER 30600).
// install: the bar fetches the APK itself from the vendor cloud (apps/100/<package>/fetchLastVerV2) and
// installs it; this prints the first progress push, then polls the status every 5 s for up to a minute.
if let i = CommandLine.arguments.firstIndex(of: "app"), CommandLine.arguments.count > i + 4 {
    let ip = CommandLine.arguments[i + 1], serial = CommandLine.arguments[i + 2]
    let verb = CommandLine.arguments[i + 3], pkg = CommandLine.arguments[i + 4]
    guard let type = ["status": 0, "install": 1, "uninstall": 2][verb] else { print("verb must be status|install|uninstall"); exit(2) }
    guard let token = Store.shared.loadToken(serial: serial) else { print("no stored token"); exit(2) }
    let s = CoreBarSession(ip: ip, token: token, certPin: Store.shared.certPin(for: serial))
    func status() async throws -> String { try await s.rawRequest(act: 30600, data: ["type": 0, "packageName": pkg], timeout: 15) }
    do {
        if type == 0 { print(try await status()); exit(0) }
        var data: [String: Any] = ["type": type, "packageName": pkg]
        if type == 1 { data["appType"] = 100 }
        print(try await s.rawRequest(act: 30600, data: data, timeout: 15))
        for _ in 0..<12 {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            let r = try await status(); print(r)
            if r.contains(type == 1 ? "\"INSTALLED\"" : "\"NOT_INSTALLED\"") || r.contains("\"FAIL\"") { break }
        }
    } catch { print("request failed: \(error)"); exit(1) }
    exit(0)
}

if CommandLine.arguments.contains("discover") {
    print("scanning UDP \(Proto.discoveryPort) for 8s…")
    let bars = await Discovery.listen(timeout: 8)
    print("discovered \(bars.count):")
    for b in bars { print("  \(b.name)  ip=\(b.ip)  sn=\(b.serialNo)  ver=\(b.version)  tcp=\(b.tcpPort)") }
    exit(bars.isEmpty ? 2 : 0)
}

var failures = 0
@MainActor func check(_ cond: Bool, _ name: String, _ detail: String = "") {
    print("\(cond ? "ok  " : "FAIL") \(name + (detail.isEmpty ? "" : "  — " + detail))")
    if !cond { failures += 1 }
}

// Cube Wi-Fi state mapping (vendor strings; hardware-confirmed 2026-11-03: packages apply only at 1)
check(CoreBarSession.CubeWiFiState.isConnected(1) && !CoreBarSession.CubeWiFiState.isConnected(3), "cube wifi: 1 = connected, 3 = connecting")
check(CoreBarSession.CubeWiFiState.label(3) == "still connecting" && CoreBarSession.CubeWiFiState.label(nil) == "not read yet", "cube wifi labels")

// Sun & moon (SkyMath): Sassenheim, 2026-11-04. Reference: sunrise 07:41, sunset 17:07 CET (timeanddate),
// new moon 2026-11-09, full moon 2026-11-24.
do {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
    let noon = cal.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 12))!
    let s = SkyMath.sunDay(at: noon, lat: 52.2258, lon: 4.5131, calendar: cal)
    func hm(_ d: Date?) -> String { guard let d else { return "—" }; let f = DateFormatter(); f.timeZone = cal.timeZone; f.dateFormat = "HH:mm"; return f.string(from: d) }
    func minutes(_ d: Date?) -> Int { guard let d else { return -9999 }; let c = cal.dateComponents([.hour, .minute], from: d); return c.hour! * 60 + c.minute! }
    check(abs(minutes(s.sunrise) - (7 * 60 + 41)) <= 6, "sunrise Sassenheim 2026-11-04 ≈ 07:41", hm(s.sunrise))
    check(abs(minutes(s.sunset) - (17 * 60 + 7)) <= 6, "sunset Sassenheim 2026-11-04 ≈ 17:07", hm(s.sunset))
    check(s.now.elevation > 15 && s.now.elevation < 25, "sun elevation at noon in November ≈ 20°", "\(s.now.elevation)")
    check(s.dayLength > 9 * 3600 && s.dayLength < 10 * 3600, "day length ≈ 9.4 h", "\(Int(s.dayLength / 60)) min")
    let m = SkyMath.moonInfo(at: noon, lat: 52.2258, lon: 4.5131, calendar: cal)
    let newMoon = cal.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 12))!, fullMoon = cal.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 12))!
    check(abs(m.nextNew.timeIntervalSince(newMoon)) < 36 * 3600, "next new moon ≈ 2026-11-09", "\(m.nextNew)")
    check(abs(m.nextFull.timeIntervalSince(fullMoon)) < 36 * 3600, "next full moon ≈ 2026-11-24", "\(m.nextFull)")
    check(!m.waxing && m.illumination < 0.4, "2026-11-04: waning crescent", "\(m.name) \(m.illumination)")
    check(m.rise != nil || m.set != nil, "moon rise/set found", "rise \(hm(m.rise)) set \(hm(m.set))")
}

// RSS parsing (CDATA titles, RFC 822 dates) and the verse of the day
do {
    let rss = """
    <?xml version="1.0"?><rss version="2.0"><channel><title>Feed</title>
    <item><title><![CDATA[First & foremost]]></title><link>https://x/1</link><pubDate>Wed, 04 Nov 2026 10:00:00 GMT</pubDate><description><![CDATA[<p>Body &amp; more</p>]]></description></item>
    <item><title>Second</title><link>https://x/2</link><pubDate>Wed, 04 Nov 2026 09:00:00 +0100</pubDate></item>
    </channel></rss>
    """
    let items = NewsFeed.parse(Data(rss.utf8))
    check(items.count == 2 && items[0].title == "First & foremost" && items[0].summary == "Body & more", "rss: CDATA title and stripped description", items.map(\.title).joined(separator: "|"))
    check(items[0].date != nil && items[1].date != nil && items[0].date! > items[1].date!, "rss: RFC 822 dates parsed", "\(String(describing: items[0].date))")
    let lite = #"<ul><li class="card--lite"><a href="/2026/11/04/us/story-a">Story &amp; A</a></li><li class="card--lite"><a href="/2026/10/01/us/old">Old</a></li></ul>"#
    var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
    let liteNow = utc.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 12))!
    let cnn = NewsFeed.parseCNNLite(lite, now: liteNow)
    check(cnn.count == 1 && cnn[0].title == "Story & A" && cnn[0].link == "https://lite.cnn.com/2026/11/04/us/story-a" && cnn[0].day != nil, "cnn lite: headline, link and day; stale items dropped", cnn.map(\.title).joined(separator: "|"))
    let r1 = DailyVerse.reference(for: Date()), r2 = DailyVerse.reference(for: Date())
    check(r1 == r2 && DailyVerse.references.contains(r1), "verse of the day is deterministic", r1)
    check(Set(DailyVerse.references).count == DailyVerse.references.count, "verse list has no duplicates")
    check(Flights.compass(0) == "N" && Flights.compass(44) == "NE" && Flights.compass(359) == "N" && Flights.compass(225) == "SW", "compass points")
}

// /upload reply classification: only hotspot-no-IP and module-not-found are retried by `upload`.
do {
    typealias R = CoreBarSession.UploadReply
    check(R(accepted: true, text: #"{"state":200,"msg":"ok"}"#) == .accepted, "upload reply: state 200 → accepted")
    check(R(accepted: false, text: #"{"state":-1,"msg":"hotspotIp ip address is empty"}"#) == .hotspotNoIp, "upload reply: hotspotIp → hotspotNoIp (retried)")
    check(R(accepted: false, text: #"{"state":-1,"msg":"module not found"}"#) == .moduleNotFound, "upload reply: module not found → provision once")
    check(R(accepted: false, text: #"{"state":-1,"msg":"reply error:4"}"#) == .cubeOffline(code: 4), "upload reply: reply error:4 → cubeOffline (no retry)")
    check(R(accepted: false, text: #"{"state":-1,"msg":"reply error:2"}"#) == .cubeOffline(code: 2), "upload reply: reply error:2 → cubeOffline (no retry)")
    check(R(accepted: false, text: #"{"state":-1,"msg":"reply error:7"}"#) == .other(#"{"state":-1,"msg":"reply error:7"}"#), "upload reply: other reply error → other")
    check(R(accepted: false, text: "HTTP 503") == .other("HTTP 503"), "upload reply: HTTP failure → other")
    check(R(accepted: false, text: #"{"state":-1}"#) == .launcherExhausted, "upload reply: bare state -1 → launcher out of upload slots (restart it)")
    check(R(accepted: false, text: #"{"state":-1,"msg":"write update command success,update timeout"}"#) == .other(#"{"state":-1,"msg":"write update command success,update timeout"}"#), "upload reply: module timeout → other")
}

// CRC32 known vector
check(DeployPackager.crc32(Array("123456789".utf8)) == 0xCBF4_3926, "crc32('123456789') == 0xCBF43926")

// WireLog redaction: token, AUTH data, Wi-Fi config hex (property 7), apiKey
do {
    let auth = WireLog.redact(#"{"act":100,"data":"SECRETTOKEN123","id":"x"}"#)
    check(!auth.contains("SECRETTOKEN123") && auth.contains("<redacted>"), "redact: AUTH frame token (act 100 data)")
    let w = WireLog.redact(#"{"act":30201,"data":{"deviceId":256,"propertyId":7,"serialNo":"0000","value":"0D486F7573650B50617373"},"id":"y"}"#)
    check(!w.contains("0D486F7573650B50617373"), "redact: Wi-Fi config write (property 7 value)")
    let r = WireLog.redact(#"{"act":30200,"code":200,"data":{"deviceId":256,"propertyId":7,"result":"0D486F7573650B50617373","serialNo":"0000"}}"#)
    check(!r.contains("0D486F7573650B50617373"), "redact: Wi-Fi config read (property 7 result)")
    let k = WireLog.redact(#"{"act":1010,"data":{"config":{"apiKey":"ABCDEF","metric":true},"packageName":"com.ultrabar.weather"}}"#)
    check(!k.contains("ABCDEF"), "redact: AccuWeather apiKey (act 1010)")
    let ok = WireLog.redact(#"{"act":30200,"code":200,"data":{"deviceId":256,"propertyId":6,"result":3,"serialNo":"0000"}}"#)
    check(ok.contains("\"result\":3"), "redact: leaves other properties alone")
}

// DeviceImage opaque header
do {
    let w = 4, h = 2
    let rgba = [UInt8](repeating: 0xFF, count: w * h * 4)
    let out = DeviceImage.encode(width: w, height: h, rgba: rgba)
    let word = UInt32(out[0]) | UInt32(out[1]) << 8 | UInt32(out[2]) << 16 | UInt32(out[3]) << 24
    check(Int(word & 0x3FF) == 4, "opaque marker == 4")
    check(Int((word >> 10) & 0x7FF) == w, "width encoded")
    check(Int(word >> 21) == h, "height encoded")
    let payload = UInt32(out[4]) | UInt32(out[5]) << 8 | UInt32(out[6]) << 16 | UInt32(out[7]) << 24
    check(Int(payload) == w * h * 2, "opaque payload size")
    check(out.count == 8 + w * h * 2, "opaque total size")
    check(out[8] == 0xFF && out[9] == 0xFF, "white -> 0xFFFF")
}

// DeviceImage alpha header
do {
    let w = 2, h = 2
    var rgba = [UInt8](repeating: 0xFF, count: w * h * 4)
    rgba[3] = 0x00
    let flat = DeviceImage.encode(width: w, height: h, rgba: rgba)
    check(Int((UInt32(flat[0]) | UInt32(flat[1]) << 8) & 0x3FF) == 4 && flat.count == 8 + w * h * 2, "default encode flattens to opaque (marker 4)")
    let out = DeviceImage.encode(width: w, height: h, rgba: rgba, allowAlpha: true)
    let word = UInt32(out[0]) | UInt32(out[1]) << 8 | UInt32(out[2]) << 16 | UInt32(out[3]) << 24
    check(Int(word & 0x3FF) == 5, "alpha marker == 5 (opt-in)")
    check(out.count == 8 + w * h * 3, "alpha total size")
    check(out[10] == 0x00, "first pixel alpha preserved")
}

// tgz = gzip + ustar, inflates back to a valid tar
do {
    let layer = DeployPackager.Layer(layerId: 1, widgetId: 101, defaultBin: [1, 2, 3], pressedBin: [4, 5, 6])
    let tgz = DeployPackager.buildTgz(layers: [layer], defaultLayer: 1)
    check(tgz[0] == 0x1f && tgz[1] == 0x8b && tgz[2] == 0x08, "gzip magic + deflate method")

    let body = tgz.subdata(in: 10..<(tgz.count - 8))
    var dst = [UInt8](repeating: 0, count: 65536)
    let n = body.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
        dst.withUnsafeMutableBufferPointer { d in
            compression_decode_buffer(d.baseAddress!, d.count,
                                      src.bindMemory(to: UInt8.self).baseAddress!, body.count,
                                      nil, COMPRESSION_ZLIB)
        }
    }
    let tar = Array(dst[0..<n])
    check(n > 0, "deflate body inflates")
    let magic = String(bytes: tar[257..<262], encoding: .ascii)
    check(magic == "ustar", "ustar magic at offset 257")
    let name = String(bytes: tar[0..<15], encoding: .ascii)
    check(name == "com_res101/defa", "first member name")

    // verify stored CRC32 matches the inflated->? no; verify gzip ISIZE trailer
    let isize = UInt32(tgz[tgz.count-4]) | UInt32(tgz[tgz.count-3]) << 8 | UInt32(tgz[tgz.count-2]) << 16 | UInt32(tgz[tgz.count-1]) << 24
    check(Int(isize) == tar.count, "gzip ISIZE == uncompressed length")
}

// Redaction must not depend on key order or spacing (the bar's replies are not key-sorted), and must
// cover the bar apps' web-UI session tokens (APP_LIST) and any "password" key.
do {
    let tail = WireLog.redact(#"{"act":30200,"code":200,"data":{"result":"0D486F7573650B50617373","propertyId":7}}"#)
    check(!tail.contains("0D486F7573650B50617373"), "redact: property 7 result when propertyId is the last key")
    let spaced = WireLog.redact(#"{"act": 100, "data": "SECRETTOKEN123", "id": "x"}"#)
    check(!spaced.contains("SECRETTOKEN123"), "redact: AUTH frame with spaces after colons")
    let p70 = WireLog.redact(#"{"data":{"propertyId":70,"result":"ABCDEF"}}"#)
    check(p70.contains("ABCDEF"), "redact: propertyId 70 is not property 7")
    let st = WireLog.redact(#"{"config":{"port":8090,"sessionToken":"deadbeef"},"password":"hunter2"}"#)
    check(!st.contains("deadbeef") && !st.contains("hunter2"), "redact: sessionToken and password values", st)
}

// Module Wi-Fi wire format: hex([len]ssid[len]password), and malformed input is rejected, not trapped on.
do {
    typealias W = CoreBarSession.ModuleWiFi
    let w = W(ssid: "Huis café", password: "p@ss wörd")
    check(CoreBarSession.decodeWiFi(CoreBarSession.encodeWiFi(w)) == w, "wifi: encode/decode round trip (UTF-8)")
    check(CoreBarSession.decodeWiFi("0D48") == nil, "wifi: length byte past the end → nil")
    check(CoreBarSession.decodeWiFi("0D4") == nil, "wifi: odd hex length → nil")
    check(CoreBarSession.decodeWiFi("ZZ") == nil, "wifi: non-hex → nil")
    check(CoreBarSession.decodeWiFi("") == nil, "wifi: empty → nil")
    check(CoreBarSession.decodeWiFi("0141") == W(ssid: "A", password: ""), "wifi: ssid only (open network)")
    let long = W(ssid: String(repeating: "s", count: 300), password: "")
    check(CoreBarSession.decodeWiFi(CoreBarSession.encodeWiFi(long))?.ssid.count == 255, "wifi: ssid capped at 255 bytes (length is one byte)")
    check(CoreBarSession.layerWidgetValue(layer: 1, widget: 101) == 0x1_0065, "property 9 = (layer << 16) | widget")
}

// Compass never traps: NaN/negative/huge bearings (values come straight from the ADS-B feed).
check(Flights.compass(.nan) == "N" && Flights.compass(-10) == "N" && Flights.compass(-100) == "W" && Flights.compass(1e9).count >= 1, "compass: non-finite and negative bearings")

// Discovery reply parsing: tcpPort may be a number or a string, ip falls back to the sender.
do {
    let a = Discovery.parse(Data(#"{"serialNo":"S1","ver":"1.0.9(9)","ip":"192.168.1.9","name":"ultrabar","tcpPort":7431}"#.utf8), from: "10.0.0.1")
    check(a?.ip == "192.168.1.9" && a?.tcpPort == 7431 && a?.serialNo == "S1", "discovery: full reply")
    let b = Discovery.parse(Data(#"{"serialNo":"S2","tcpPort":"7431"}"#.utf8), from: "10.0.0.2")
    check(b?.ip == "10.0.0.2" && b?.tcpPort == 7431, "discovery: string tcpPort, ip from sender")
    check(Discovery.parse(Data(#"{"serialNo":"S3"}"#.utf8), from: "10.0.0.3") == nil, "discovery: no tcpPort → ignored")
    check(Discovery.parse(Data("not json".utf8), from: "10.0.0.3") == nil, "discovery: garbage → ignored")
    check(Discovery.parse(Data(#"{"serialNo":"S4","tcpPort":0}"#.utf8), from: "10.0.0.4")?.tcpPort == 7431, "discovery: tcpPort 0 → default 7431")
}

// Request parsing used by the LAN servers (security review 2026-11-04).
do {
    check(MonitorServer.hostIsAllowed("GET / HTTP/1.1\r\nHost: 192.168.1.20:7432\r\n"), "host check: IPv4 with port")
    check(MonitorServer.hostIsAllowed("GET / HTTP/1.1\r\nHost: 192.168.1.20\r\n"), "host check: IPv4 without port")
    check(MonitorServer.hostIsAllowed("GET / HTTP/1.1\r\nhost: LOCALHOST:7432\r\n"), "host check: localhost, any case")
    check(MonitorServer.hostIsAllowed("GET / HTTP/1.1\r\nHost: [fe80::1%en0]:7432\r\n"), "host check: IPv6 literal with zone and port")
    check(MonitorServer.hostIsAllowed("GET / HTTP/1.0\r\n"), "host check: no Host header (HTTP/1.0) is allowed")
    check(!MonitorServer.hostIsAllowed("GET / HTTP/1.1\r\nHost: deckhand.attacker.example:7432\r\n"), "host check: a DNS name is refused")
    check(!MonitorServer.hostIsAllowed("GET / HTTP/1.1\r\nHost: 192.168.1.20.attacker.example\r\n"), "host check: an address-looking name is refused")
    check(!MonitorServer.hostIsAllowed("GET / HTTP/1.1\r\nHost: \r\n"), "host check: an empty Host is refused")
    check(MonitorServer.header("x-deckhand", in: "POST /a HTTP/1.1\r\nX-Deckhand:  action \r\n") == "action", "header: name is case-insensitive, value trimmed")
    check(MonitorServer.header("host", in: "GET /host: x HTTP/1.1\r\nHost: 1.2.3.4\r\n") == "1.2.3.4", "header: the request line is not a header")
    check(MonitorServer.hasActionMarker("POST /a HTTP/1.1\r\nX-Deckhand: Action\r\n"), "action marker: header present")
    check(!MonitorServer.hasActionMarker("POST /a HTTP/1.1\r\nReferer: http://x/x-deckhand: action\r\n"), "action marker: the string inside another header does not count")
    check(MonitorServer.peerMayAct("127.0.0.1", peers: ["10.0.0.5"]) && MonitorServer.peerMayAct("::1", peers: []), "action peers: loopback always may")
    check(MonitorServer.peerMayAct("10.0.0.5", peers: ["10.0.0.5"]) && MonitorServer.peerMayAct("::ffff:10.0.0.5", peers: ["10.0.0.5"]), "action peers: the listed bar may (also IPv4-mapped)")
    check(!MonitorServer.peerMayAct("10.0.0.6", peers: ["10.0.0.5"]) && !MonitorServer.peerMayAct(nil, peers: nil), "action peers: another host may not; unknown peer may not")
    check(MonitorServer.peerMayAct("10.0.0.6", peers: nil), "action peers: nil = any peer (default)")
    check(MonitorServer.peerMayRead("10.0.0.6", peers: ["10.0.0.5"], pagesOnly: false), "pages only for the bar: off → any peer may read")
    check(MonitorServer.peerMayRead("10.0.0.5", peers: ["10.0.0.5"], pagesOnly: true) && MonitorServer.peerMayRead("127.0.0.1", peers: [], pagesOnly: true), "pages only for the bar: on → the bar and loopback may read")
    check(!MonitorServer.peerMayRead("10.0.0.6", peers: ["10.0.0.5"], pagesOnly: true) && !MonitorServer.peerMayRead("10.0.0.6", peers: [], pagesOnly: true), "pages only for the bar: on → another host may not, nor anyone when no bar is selected")
    // Discovery replies are unauthenticated LAN data.
    let spoof = Discovery.parse(Data(#"{"serialNo":"S9","tcpPort":7431,"ip":"evil.example"}"#.utf8), from: "10.0.0.9")
    check(spoof?.ip == "10.0.0.9", "discovery: an ip that is not an IPv4 literal → sender address", spoof?.ip ?? "nil")
    check(Discovery.parse(Data(#"{"serialNo":"S9","tcpPort":70000}"#.utf8), from: "10.0.0.9") == nil, "discovery: tcpPort out of range → ignored")
    check(Discovery.parse(Data(#"{"tcpPort":7431}"#.utf8), from: "10.0.0.9") == nil, "discovery: no serial → ignored")
    let ctl = Discovery.parse(Data("{\"serialNo\":\"S9\",\"tcpPort\":7431,\"name\":\"bar\\r\\nfake\"}".utf8), from: "10.0.0.9")
    check(ctl?.name == "barfake", "discovery: control characters stripped from strings", ctl?.name ?? "nil")
    let long = Discovery.parse(Data(("{\"serialNo\":\"" + String(repeating: "A", count: 500) + "\",\"tcpPort\":7431}").utf8), from: "10.0.0.9")
    check(long?.serialNo.count == 64, "discovery: serial capped at 64 characters", "\(long?.serialNo.count ?? -1)")
}

// MonitorServer on a loopback ephemeral port: routing, percent-decoding, 405, bare-LF request lines,
// and a client that never finishes its request is dropped after `requestTimeout`.
do {
    MonitorServer.requestTimeout = 1
    MonitorServer.shared.setRoute { path in
        if path == "/a b" { return .text("hit") }
        if path == "/j" { return .json(["ok": true]) }
        if path == "/h" { return .html("<p>hi</p>") }
        return nil
    }
    MonitorServer.shared.setActionRoute { path in path == "/act" ? .json(["did": true]) : nil }
    func get(_ path: String, method: String = "GET") async -> (Int, String) {
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(MonitorServer.shared.port)\(path)")!); r.httpMethod = method; r.timeoutInterval = 5
        guard let (d, resp) = try? await URLSession.shared.data(for: r) else { return (-1, "") }
        return ((resp as? HTTPURLResponse)?.statusCode ?? -1, String(decoding: d, as: UTF8.self))
    }
    /// Raw HTTP over a blocking socket: `send` bytes, then read until the server closes (or `timeout`).
    func raw(_ send: String, timeout: Int) -> (closed: Bool, text: String) {
        let fd = socket(AF_INET, SOCK_STREAM, 0); defer { close(fd) }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_port = MonitorServer.shared.port.bigEndian; inet_pton(AF_INET, "127.0.0.1", &a.sin_addr)
        let rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard rc == 0 else { return (false, "connect failed") }
        _ = send.withCString { write(fd, $0, strlen($0)) }
        var out = Data(); var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n > 0 { out.append(contentsOf: buf[0..<n]); continue }
            return (n == 0, String(decoding: out, as: UTF8.self))
        }
    }
    do {
        try MonitorServer.shared.start(port: 0)
        check(MonitorServer.shared.isRunning && MonitorServer.shared.port != 0, "monitor server: started on an ephemeral port", "\(MonitorServer.shared.port)")
        let hit = await get("/a%20b?x=1")
        check(hit.0 == 200 && hit.1 == "hit", "monitor server: route gets the percent-decoded path without the query", "\(hit)")
        let miss = await get("/nope")
        check(miss.0 == 404, "monitor server: unknown path → 404", "\(miss.0)")
        let ico = await get("/favicon.ico")
        check(ico.0 == 204 && ico.1.isEmpty, "monitor server: /favicon.ico → 204 without a body (browsers on the Mac ask for it)", "\(ico.0)")
        let post = await get("/a%20b", method: "POST")
        check(post.0 == 403, "monitor server: POST without the X-Deckhand header → 403", "\(post.0)")
        let put = await get("/a%20b", method: "PUT")
        check(put.0 == 405, "monitor server: PUT → 405", "\(put.0)")
        let head = await get("/j", method: "HEAD")
        check(head.0 == 200 && head.1.isEmpty, "monitor server: HEAD has no body", "\(head)")
        let lf = raw("GET /j\nHost: 127.0.0.1\r\n\r\n", timeout: 5)
        check(lf.closed && lf.text.hasPrefix("HTTP/1.1 200") && lf.text.hasSuffix("{\"ok\":true}"), "monitor server: bare-LF request line still parsed", lf.text.prefix(40).replacingOccurrences(of: "\r\n", with: " | "))
        let t0 = Date()
        let slow = raw("GET /j HTTP/1.1\r\nHost: 127.0.0.1\r\n", timeout: 5) // head never completed
        let dt = Date().timeIntervalSince(t0)
        check(slow.closed && slow.text.isEmpty && dt < 4, "monitor server: incomplete request dropped after requestTimeout (1 s)", String(format: "closed after %.1f s", dt))
        // Security review 2026-11-04: Host must be an address (DNS rebinding), the action marker is a real header,
        // actions are accepted from the paired bar or this Mac only, and every response carries the hardening headers.
        let rebind = raw("GET /j HTTP/1.1\r\nHost: evil.example:7432\r\n\r\n", timeout: 5)
        check(rebind.text.hasPrefix("HTTP/1.1 421"), "monitor server: a DNS name in Host → 421 (rebinding)", rebind.text.prefix(30).description)
        let v6 = raw("GET /j HTTP/1.1\r\nHost: [::1]:7432\r\n\r\n", timeout: 5)
        check(v6.text.hasPrefix("HTTP/1.1 200"), "monitor server: an IPv6 literal in Host is fine", v6.text.prefix(30).description)
        let html = raw("GET /h HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", timeout: 5)
        check(html.text.contains("Content-Security-Policy: default-src 'none'") && html.text.contains("X-Content-Type-Options: nosniff") && html.text.contains("X-Frame-Options: DENY"),
              "monitor server: HTML carries CSP, nosniff and no-frame headers", html.text.prefix(300).replacingOccurrences(of: "\r\n", with: " | "))
        let json = raw("GET /j HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", timeout: 5)
        check(!json.text.contains("Content-Security-Policy") && json.text.contains("nosniff"), "monitor server: JSON gets nosniff but no CSP")
        MonitorServer.shared.setActionPeers(["10.9.9.9"])   // not this Mac; loopback is always allowed
        let act = raw("POST /act HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Deckhand: action\r\nContent-Length: 0\r\n\r\n", timeout: 5)
        check(act.text.hasPrefix("HTTP/1.1 200") && act.text.hasSuffix("{\"did\":true}"), "monitor server: POST with X-Deckhand: action from loopback runs the action", act.text.prefix(30).description)
        let forged = raw("POST /act HTTP/1.1\r\nHost: 127.0.0.1\r\nReferer: http://a/?x-deckhand: action\r\nContent-Length: 0\r\n\r\n", timeout: 5)
        check(forged.text.hasPrefix("HTTP/1.1 403"), "monitor server: the marker inside another header does not count", forged.text.prefix(30).description)
        let wrong = raw("POST /act HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Deckhand: nope\r\nContent-Length: 0\r\n\r\n", timeout: 5)
        check(wrong.text.hasPrefix("HTTP/1.1 403"), "monitor server: X-Deckhand with another value → 403", wrong.text.prefix(30).description)
        // "Pages only for the bar" (2026-11-04): GET is answered to the action peers and loopback only.
        MonitorServer.shared.setPagesOnlyForPeers(true)
        check(MonitorServer.shared.isPagesOnlyForPeers, "monitor server: pages-only flag set")
        let own = await get("/j")
        check(own.0 == 200, "monitor server: pages only for the bar → loopback still reads", "\(own.0)")
        // From this Mac's LAN address the peer is not loopback: 403 unless that address is the bar's.
        if let lan = LocalIP.address(reaching: "192.168.255.254"), !lan.hasPrefix("127.") {
            func lanGet(_ path: String) async -> Int {
                var r = URLRequest(url: URL(string: "http://\(lan):\(MonitorServer.shared.port)\(path)")!); r.timeoutInterval = 5
                guard let (_, resp) = try? await URLSession.shared.data(for: r) else { return -1 }
                return (resp as? HTTPURLResponse)?.statusCode ?? -1
            }
            let other = await lanGet("/j")
            check(other == 403, "monitor server: pages only for the bar → another address gets 403", "\(other) via \(lan)")
            MonitorServer.shared.setActionPeers([lan])
            let bar = await lanGet("/j")
            check(bar == 200, "monitor server: pages only for the bar → the bar's address reads", "\(bar) via \(lan)")
            MonitorServer.shared.setPagesOnlyForPeers(false)
            MonitorServer.shared.setActionPeers(["10.9.9.9"])
            let open = await lanGet("/j")
            check(open == 200, "monitor server: pages-only off → any address reads again", "\(open) via \(lan)")
        } else {
            print("  (skipped the LAN-address checks for pages-only: no LAN address on this Mac)")
        }
        MonitorServer.shared.setPagesOnlyForPeers(false)
        MonitorServer.shared.setActionPeers(nil)
        MonitorServer.shared.stop()
        check(!MonitorServer.shared.isRunning, "monitor server: stopped")
    } catch { check(false, "monitor server: start", "\(error)") }
    MonitorServer.requestTimeout = 15
}


// ============================================================================================
// Library review round, 4 November 2026 (left-as-recommendations items): pairing reject, gzip
// on incompressible input, private file writes in Store, Linear 400 vs 401, 64-bit counters.
// ============================================================================================

// A rejected pairing (act 101, code -1) must end the wait at once; the mock's token reply and the
// bare "request shown" acknowledgement must keep working.
do {
    func frame(_ s: String) -> CoreBarClient.PairReply { CoreBarClient.classifyPairReply(Data(s.utf8)) }
    check(frame(#"{"act":101,"id":"x","code":-1,"msg":"user reject"}"#) == .rejected(code: -1, message: "user reject"), "pair: code -1 (Reject tapped) is a rejection")
    check(frame(#"{"act":"101","code":"-1"}"#) == .rejected(code: -1, message: nil), "pair: numeric strings still parse")
    check(frame(#"{"act":101,"id":"x","code":500,"msg":"device error"}"#) == .rejected(code: 500, message: "device error"), "pair: a device error code is a rejection")
    check(frame(#"{"act":101,"id":"x","code":200,"data":{"token":"tok-1"},"msg":"ok"}"#) == .token("tok-1"), "pair: mock-style token reply")
    check(frame(#"{"act":101,"token":"tok-2"}"#) == .token("tok-2"), "pair: top-level token")
    check(frame(#"{"act":101,"id":"x"}"#) == .pending, "pair: ack without code or token keeps waiting")
    check(frame(#"{"act":101,"id":"x","code":200,"data":null}"#) == .pending, "pair: code 200 without a token keeps waiting")
    check(frame(#"{"act":20,"id":"1"}"#) == .unrelated, "pair: a heartbeat is unrelated")
    check(frame("not json") == .unrelated, "pair: garbage is unrelated")
    let msg = UltraBarError.pairingRejected(code: -1, message: "user reject").errorDescription ?? ""
    check(msg.contains("refused") && msg.contains("-1"), "pair: rejection error text names the refusal", msg)
}

// gzip of 20 MB of random bytes (incompressible) must still inflate back to the input, and the ISIZE
// and CRC trailers must match. Before: an empty deflate body above about 13 MB.
do {
    var rng = SystemRandomNumberGenerator()
    var input = [UInt8](repeating: 0, count: 20 * 1024 * 1024)
    input.withUnsafeMutableBytes { raw in
        let words = raw.bindMemory(to: UInt64.self)
        for i in words.indices { words[i] = rng.next() }
    }
    func inflate(_ gz: Data, expect: Int) -> [UInt8] {
        let body = gz.subdata(in: 10..<(gz.count - 8))
        var dst = [UInt8](repeating: 0, count: expect + 1)
        let n = body.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            dst.withUnsafeMutableBufferPointer { d in
                compression_decode_buffer(d.baseAddress!, d.count, src.bindMemory(to: UInt8.self).baseAddress!, body.count, nil, COMPRESSION_ZLIB)
            }
        }
        return Array(dst[0..<n])
    }
    let gz = DeployPackager.gzip(input)
    check(gz.count > 18, "gzip: 20 MB random bytes produce a body", "\(gz.count) B")
    let back = inflate(gz, expect: input.count)
    check(back == input, "gzip: 20 MB random bytes inflate back to the input", "\(back.count) B back")
    let isize = UInt32(gz[gz.count-4]) | UInt32(gz[gz.count-3]) << 8 | UInt32(gz[gz.count-2]) << 16 | UInt32(gz[gz.count-1]) << 24
    check(Int(isize) == input.count, "gzip: ISIZE trailer for 20 MB")
    let crc = UInt32(gz[gz.count-8]) | UInt32(gz[gz.count-7]) << 8 | UInt32(gz[gz.count-6]) << 16 | UInt32(gz[gz.count-5]) << 24
    check(crc == DeployPackager.crc32(input), "gzip: CRC32 trailer for 20 MB")
    // The stored-block fallback on its own, and the empty input.
    let small = Array("stored block fallback".utf8)
    let stored = DeployPackager.storedBlocks(small)
    var fake = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xFF]); fake.append(contentsOf: stored); fake.append(contentsOf: [UInt8](repeating: 0, count: 8))
    check(inflate(fake, expect: small.count) == small, "gzip: stored-block fallback inflates")
    let big = DeployPackager.storedBlocks([UInt8](repeating: 7, count: 70_000))
    check(big.count == 70_000 + 10 && big[0] == 0 && big[5 + 65535] == 1, "gzip: stored blocks split at 65 535 with the final bit on the last")
    check(inflate(DeployPackager.gzip([]), expect: 0).isEmpty && DeployPackager.gzip([]).count == 23, "gzip: empty input is a valid 23-byte gzip")
}

// Store: secrets land in files that are 0600 from the moment they exist (created by open(2) with that
// mode, then renamed into place), and forgetting a bar removes its endpoint caches too.
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kitcheck-store-\(UUID().uuidString.prefix(8))", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = Store(directory: dir)
    func mode(_ url: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int) ?? -1 }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    let serial = "KC-STORE-1"
    store.upsert(serial: serial, name: "check", ip: "10.0.0.9", certSHA256: "AB")
    store.setHotspot(serial: serial, ssid: "cube", password: "hunter2")
    let corebars = dir.appendingPathComponent("corebars.json")
    check(exists(corebars) && mode(corebars) == 0o600, "store: corebars.json is 0600", String(mode(corebars), radix: 8))
    store.saveToken("tok", serial: serial)
    let token = dir.appendingPathComponent("tokens/KCSTORE1.token")
    check(mode(token) == 0o600 && store.loadToken(serial: serial) == "tok", "store: token file is 0600 and reads back", String(mode(token), radix: 8))
    check(mode(dir.appendingPathComponent("tokens")) == 0o700, "store: tokens directory is 0700")
    store.saveSecret("key-1", name: "linear")
    let secret = dir.appendingPathComponent("tokens/secretlinear.token")
    check(mode(secret) == 0o600 && store.loadSecret(name: "linear") == "key-1", "store: secret file is 0600 and reads back")
    store.saveToken("tok-2", serial: serial)   // overwrite keeps the mode and the new content
    check(mode(token) == 0o600 && store.loadToken(serial: serial) == "tok-2", "store: overwriting a token keeps 0600")
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("tokens").path))?.filter { $0.hasSuffix(".tmp") } ?? []
    check(leftovers.isEmpty, "store: no temporary files left behind", leftovers.joined(separator: ","))
    store.saveEndpoints(Data("[]".utf8), serial: serial)
    store.rememberModules([["serialNumber": "M1", "ip": "10.0.0.2"]], corebar: serial)
    let ep = dir.appendingPathComponent("endpoints/KCSTORE1.json"), known = dir.appendingPathComponent("endpoints/KCSTORE1.known.json")
    check(exists(ep) && exists(known), "store: endpoint caches written")
    store.remove(serial: serial)
    check(!exists(token) && !exists(ep) && !exists(known) && store.pairedCoreBars.isEmpty, "store: remove(serial:) deletes the token and both endpoint caches")
    store.saveSecret("", name: "linear")
    check(!exists(secret), "store: an empty secret deletes the file")
    // Write into a directory that does not exist: must fail quietly, not crash.
    check(!Store.writePrivate(Data("x".utf8), to: dir.appendingPathComponent("missing/dir/file")), "store: writePrivate reports failure instead of crashing")
}

// Linear: HTTP 400 is the query, 401 is the key.
do {
    check(LinearTasks.httpErrorMessage(401).contains("API key"), "linear: 401 blames the key")
    check(LinearTasks.httpErrorMessage(400) == "Linear rejected the request (HTTP 400).", "linear: 400 blames the request", LinearTasks.httpErrorMessage(400))
}

// Network counters come from the interface MIB (64-bit, what netstat -ib prints): monotonic across two
// samples and non-zero. (NET_RT_IFLIST2 and getifaddrs both gave the low 32 bits on this Mac.)
do {
    let ns = NetworkStats()
    let a = ns.totals()
    _ = ns.sample()
    let b = ns.totals()
    check(b.received >= a.received && b.sent >= a.sent, "network: totals never go backwards between samples", "\(a) -> \(b)")
    check(a.received > 0 || a.sent > 0, "network: counters are non-zero on a machine with traffic", "\(a)")
    check(NetworkStats.isCounted("en0") && !NetworkStats.isCounted("lo0") && !NetworkStats.isCounted("utun3") && !NetworkStats.isCounted("awdl0"), "network: interface filter")
}

// Vendor releases on GitHub: the launcher and bridge APKs are picked by file name, the version split into name + code.
do {
    let sample = """
    {"tag_name":"v1.0.1.0","published_at":"2026-10-21T02:44:03Z","assets":[
      {"name":"bridge.1.0.4.4.apk","size":22006908,"browser_download_url":"https://github.com/Qinkunex/UltraWorkspace/releases/download/v1.0.1.0/bridge.1.0.4.4.apk"},
      {"name":"LineOS.V1.0.9.9.apk","size":72371659,"browser_download_url":"https://github.com/Qinkunex/UltraWorkspace/releases/download/v1.0.1.0/LineOS.V1.0.9.9.apk"},
      {"name":"Sence.Cube_V2_ota.bin","size":38884,"browser_download_url":"https://github.com/Qinkunex/UltraWorkspace/releases/download/v1.0.1.0/Sence.Cube_V2_ota.bin"},
      {"name":"evil.apk","size":1,"browser_download_url":"http://example.com/LineOS.V9.9.9.9.apk"},
      {"name":"UltraWorkSpace-V1.0.1.0-MacOS-Installer.dmg","size":1,"browser_download_url":"https://github.com/x/y.dmg"}]}
    """
    let r = try VendorRelease.parse(Data(sample.utf8))
    check(r.tag == "v1.0.1.0" && r.published != nil, "vendor release: tag and date", r.tag)
    check(r.launcher?.name == "LineOS.V1.0.9.9.apk" && r.launcher?.versionName == "1.0.9" && r.launcher?.versionCode == 9, "vendor release: launcher asset 1.0.9 (9)", "\(String(describing: r.launcher))")
    check(r.bridge?.name == "bridge.1.0.4.4.apk" && r.bridge?.versionName == "1.0.4" && r.bridge?.versionCode == 4 && r.bridge?.size == 22006908, "vendor release: bridge asset 1.0.4 (4)", "\(String(describing: r.bridge))")
    check(r.senseCubeFirmware?.name == "Sence.Cube_V2_ota.bin", "vendor release: SenseCube firmware noticed", "")
    check(r.launcher?.url.host == "github.com", "vendor release: a non-https / non-GitHub asset never wins the launcher slot", "\(r.launcher?.url.absoluteString ?? "")")
    check(VendorRelease.split("1.0.9").code == 0 && VendorRelease.split("1.0.9").name == "1.0.9", "vendor release: three-part version has no code", "")
    let st = BarSoftwareProbe(launcher: ("1.0.3", 3), bridge: ("1.0.4", 4), release: r)
    check(st.launcherNewer && !st.bridgeNewer, "vendor release: 1.0.3(3) → launcher update, bridge 1.0.4(4) → none", "")
} catch { check(false, "vendor release: parse", "\(error)") }

// APK manifests: package and version read from the binary XML of a Deckhand bar app when a build is present.
do {
    let apk = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist/bar-apps/DeckhandMonitor.apk")
    if FileManager.default.fileExists(atPath: apk.path) {
        let info = try ApkInfo.read(apk: apk)
        check(info.package == "nl.denoronha.deckhand.monitor" && info.versionCode == 11 && info.versionName == "2.0", "apk: DeckhandMonitor.apk manifest = nl.denoronha.deckhand.monitor 2.0 (11)", "\(info)")
    } else { print("skip  apk: no dist/bar-apps/DeckhandMonitor.apk here") }
    do { _ = try ApkInfo.parseManifest(Data("<xml/>".utf8)); check(false, "apk: text XML rejected", "") }
    catch { check(true, "apk: text XML rejected", "") }
} catch { check(false, "apk: read", "\(error)") }

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
