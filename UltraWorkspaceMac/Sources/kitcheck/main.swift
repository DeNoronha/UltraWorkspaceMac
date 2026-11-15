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
if let i = CommandLine.arguments.firstIndex(of: "claude-session"), CommandLine.arguments.count > i + 1 {
    // kitcheck claude-session <cwd>…: the newest Claude Code session per directory, as the Claude bar app sees it.
    for cwd in CommandLine.arguments[(i + 1)...] {
        let t0 = Date()
        if let s = ClaudeUsage.latestSession(cwd: cwd) {
            print("\(cwd): \(s.state.rawValue) \(s.project) | \(s.title) | \(Int(Date().timeIntervalSince(s.lastAt))) s ago (\(String(format: "%.2f", Date().timeIntervalSince(t0))) s)")
        } else { print("\(cwd): none") }
    }
    exit(0)
}

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
    check(R(accepted: false, text: #"{"msg":"module offline","state":-1}"#) == .moduleOffline, "upload reply: module offline → check the bus, maybe restart the launcher")
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

// WireLog (security review 2026-11-15): wider denylist, coordinates to one decimal, SSID mask, report masking,
// retention (7 days, dated lines only), the 2 MB cap keeps the newest part, off by default, Clear.
do {
    for name in ["access_token", "refresh_token", "accessToken", "psk", "pwd", "secret", "client_secret", "Authorization", "key"] {
        let r = WireLog.redact("{\"\(name)\":\"VALUE123\"}")
        check(!r.contains("VALUE123"), "redact: \"\(name)\" value", r)
    }
    check(!WireLog.redact("GET /x?sessionToken=abc123&y=1").contains("abc123"), "redact: sessionToken= in a URL")
    check(!WireLog.redact("X-Deckhand-Key: 00ff00ff").contains("00ff00ff"), "redact: X-Deckhand-Key header")
    let c = WireLog.redact("weather GET forecast lat=52.3676 lon=4.9041")
    check(c == "weather GET forecast lat=52.3 lon=4.9", "redact: coordinates rounded to one decimal", c)
    let pair = WireLog.redact("weather: IP geolocation → Amsterdam (52.3676,4.9041)")
    check(pair.hasSuffix("(52.3,4.9)"), "redact: coordinate pair rounded", pair)
    check(WireLog.redact(#"{"lat":52.37612,"lon":4.9}"#) == #"{"lat":52.3,"lon":4.9}"#, "redact: JSON coordinates rounded")
    check(WireLog.maskSSID("HomeNetwork") == "Ho…(11)" && WireLog.maskSSID("ab") == "…(2)", "maskSSID: two characters and the length")
    let rep = WireLog.forReport("CoreBar ultrabar ABCD12345678 @ 192.168.50.207\nlocation: using Mac location → Haarlem\nlat=52.3 lon=4.6 {\"ssid\":\"Home\"}", serials: ["ABCD12345678"])
    check(!rep.contains("ABCD12345678") && rep.contains("…5678"), "report: serial reduced to its last four", rep)
    check(!rep.contains("50.207") && rep.contains("192.168.x.x"), "report: IP addresses masked")
    check(!rep.contains("Haarlem") && !rep.contains("52.3") && !rep.contains("\"Home\""), "report: place, coordinates and SSID dropped", rep)

    let now = Date()
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    let old = f.string(from: now.addingTimeInterval(-8 * 86_400)), recent = f.string(from: now.addingTimeInterval(-86_400))
    let pruned = String(decoding: WireLog.pruned(Data("\(old) -- old\n12:00:00.000 -- undated\n\(recent) -- new\n".utf8), now: now), as: UTF8.self)
    check(pruned == "\(recent) -- new\n", "log retention: lines older than 7 days and undated lines dropped", pruned)
    var big = Data()
    for i in 0..<30_000 { big.append(Data("\(recent) -- line \(i) padding padding padding padding\n".utf8)) }
    let capped = WireLog.capped(big)
    let cappedText = String(decoding: capped, as: UTF8.self)
    check(big.count > WireLog.maxBytes && capped.count <= WireLog.keepBytes && capped.count > WireLog.keepBytes - 200, "log cap: over 2 MB keeps about the newest 1 MB", "\(big.count) → \(capped.count)")
    check(cappedText.hasSuffix("line 29999 padding padding padding padding\n") && cappedText.hasPrefix(recent), "log cap: the newest lines are kept, cut at a line start")

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kitcheck-wirelog-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let suite = "kitcheck.wirelog.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { try? FileManager.default.removeItem(at: dir); defaults.removePersistentDomain(forName: suite) }
    let log = WireLog(directory: dir, defaults: defaults)
    log.event("before switching on")
    log.flush()
    check(!log.enabled && log.recent().isEmpty && log.fileSize == 0, "wire log: off by default, nothing kept")
    log.enabled = true
    log.sent(#"{"act":100,"data":"TOKEN-XYZ"}"#)
    log.flush()
    let onDisk = (try? String(contentsOf: log.fileURL, encoding: .utf8)) ?? ""
    let mode = ((try? FileManager.default.attributesOfItem(atPath: log.fileURL.path))?[.posixPermissions] as? Int) ?? -1
    check(log.enabled && onDisk.contains(">> ") && !onDisk.contains("TOKEN-XYZ") && mode == 0o600, "wire log: on → redacted lines in a 0600 file", String(mode, radix: 8))
    check(defaults.bool(forKey: WireLog.enabledKey) && log.enabledSince != nil, "wire log: the switch and its date are remembered")
    // Rotation on a real file keeps the newest part (the old write-only handle emptied the file).
    for i in 0..<25_000 { log.event("rotation line \(i) padding padding padding padding padding") }
    log.flush()
    let rotated = (try? String(contentsOf: log.fileURL, encoding: .utf8)) ?? ""
    check(log.fileSize <= WireLog.maxBytes && log.fileSize > WireLog.keepBytes / 2 && rotated.contains("rotation line 24999") && rotated.contains("log rotated"), "wire log: rotation keeps the newest lines", "\(log.fileSize) B")
    log.clear()
    check(log.recent().isEmpty && log.fileSize == 0, "wire log: Clear empties the ring and the file")
    log.event("after clear"); log.enabled = false; log.event("while off"); log.flush()
    check(log.recent().isEmpty && !((try? String(contentsOf: log.fileURL, encoding: .utf8)) ?? "").contains("while off"), "wire log: off → nothing written")
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

// Discovery reply parsing: tcpPort may be a number or a string, ip falls back to the sender.
do {
    let a = Discovery.parse(Data(#"{"serialNo":"SN0001","ver":"1.0.9(9)","ip":"192.168.1.9","name":"ultrabar","tcpPort":7431}"#.utf8), from: "10.0.0.1")
    check(a?.ip == "192.168.1.9" && a?.tcpPort == 7431 && a?.serialNo == "SN0001", "discovery: full reply")
    let b = Discovery.parse(Data(#"{"serialNo":"SN0002","tcpPort":"7431"}"#.utf8), from: "10.0.0.2")
    check(b?.ip == "10.0.0.2" && b?.tcpPort == 7431, "discovery: string tcpPort, ip from sender")
    check(Discovery.parse(Data(#"{"serialNo":"SN0003"}"#.utf8), from: "10.0.0.3") == nil, "discovery: no tcpPort → ignored")
    check(Discovery.parse(Data("not json".utf8), from: "10.0.0.3") == nil, "discovery: garbage → ignored")
    check(Discovery.parse(Data(#"{"serialNo":"SN0004","tcpPort":0}"#.utf8), from: "10.0.0.4")?.tcpPort == 7431, "discovery: tcpPort 0 → default 7431")
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
    check(MonitorServer.peerIsAllowed("127.0.0.1", peers: ["10.0.0.5"]) && MonitorServer.peerIsAllowed("::1", peers: []), "allowed peers: loopback always is")
    check(MonitorServer.peerIsAllowed("10.0.0.5", peers: ["10.0.0.5"]) && MonitorServer.peerIsAllowed("::ffff:10.0.0.5", peers: ["10.0.0.5"]), "allowed peers: the listed bar is (also IPv4-mapped)")
    check(!MonitorServer.peerIsAllowed("10.0.0.6", peers: ["10.0.0.5"]) && !MonitorServer.peerIsAllowed(nil, peers: ["10.0.0.5"]), "allowed peers: another host is not; an unknown peer is not")
    check(!MonitorServer.peerIsAllowed("10.0.0.6", peers: []), "allowed peers: nobody but loopback when no bar is selected")
    // M3: the per-bar key (constant-time compare), loopback without it for development.
    let k = String(repeating: "0f", count: 32)
    check(MonitorServer.requestIsAllowed(peer: "127.0.0.1", head: "GET / HTTP/1.1\r\n", peers: [], key: nil), "data key: loopback needs none")
    check(MonitorServer.requestIsAllowed(peer: "10.0.0.5", head: "GET / HTTP/1.1\r\nX-Deckhand-Key: \(k)\r\n", peers: ["10.0.0.5"], key: k), "data key: the bar with the key is answered")
    check(!MonitorServer.requestIsAllowed(peer: "10.0.0.5", head: "GET / HTTP/1.1\r\n", peers: ["10.0.0.5"], key: k), "data key: the bar without the key is not")
    check(!MonitorServer.requestIsAllowed(peer: "10.0.0.5", head: "GET / HTTP/1.1\r\nx-deckhand-key: \(k.dropLast())0\r\n", peers: ["10.0.0.5"], key: k), "data key: a wrong key is not")
    check(!MonitorServer.requestIsAllowed(peer: "10.0.0.5", head: "GET / HTTP/1.1\r\nX-Deckhand-Key: x\r\n", peers: ["10.0.0.5"], key: nil), "data key: no key set → no peer is answered")
    check(!MonitorServer.requestIsAllowed(peer: "10.0.0.6", head: "GET / HTTP/1.1\r\nX-Deckhand-Key: \(k)\r\n", peers: ["10.0.0.5"], key: k), "data key: the key from another address is not enough")
    // M2: the beacon's signature, the same HMAC the bar apps check (MacLink.verify in the APKs).
    let p = MonitorBeacon.payload(base: "http://192.168.1.2:7432", key: k, now: Date(timeIntervalSince1970: 1_700_000_000))
    check(p["ts"] as? Int == 1_700_000_000 && (p["sig"] as? String)?.count == 64 && p["v"] as? Int == 3, "beacon: v3 with ts and sig")
    // Reference value from `printf 'deckhand-beacon|http://192.168.1.2:7432|1700000000' | openssl dgst -sha256 -mac HMAC -macopt hexkey:0f0f…`.
    check(MonitorBeacon.signature(base: "http://192.168.1.2:7432", ts: 1_700_000_000, keyHex: k) == "905199ce96cdce34f64e5f19d57dc9559929bb5687607e30b480b83cf0efb732", "beacon: HMAC-SHA256 matches openssl")
    check(MonitorBeacon.payload(base: "http://192.168.1.2:7432", key: nil)["sig"] == nil && MonitorBeacon.signature(base: "x", ts: 1, keyHex: "zz") == nil, "beacon: unsigned without a key; a bad key signs nothing")
    // Discovery replies are unauthenticated LAN data.
    let spoof = Discovery.parse(Data(#"{"serialNo":"SN0009","tcpPort":7431,"ip":"evil.example"}"#.utf8), from: "10.0.0.9")
    check(spoof?.ip == "10.0.0.9", "discovery: an ip that is not an IPv4 literal → sender address", spoof?.ip ?? "nil")
    check(Discovery.parse(Data(#"{"serialNo":"SN0009","tcpPort":70000}"#.utf8), from: "10.0.0.9") == nil, "discovery: tcpPort out of range → ignored")
    check(Discovery.parse(Data(#"{"tcpPort":7431}"#.utf8), from: "10.0.0.9") == nil, "discovery: no serial → ignored")
    let ctl = Discovery.parse(Data("{\"serialNo\":\"SN0009\",\"tcpPort\":7431,\"name\":\"bar\\r\\nfake\"}".utf8), from: "10.0.0.9")
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
        let json = raw("GET /j HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", timeout: 5)
        check(json.text.contains("X-Content-Type-Options: nosniff") && json.text.contains("X-Frame-Options: DENY"), "monitor server: responses carry nosniff and no-frame headers")
        MonitorServer.shared.setAllowedPeers(["10.9.9.9"])   // not this Mac; loopback is always allowed
        let act = raw("POST /act HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Deckhand: action\r\nContent-Length: 0\r\n\r\n", timeout: 5)
        check(act.text.hasPrefix("HTTP/1.1 200") && act.text.hasSuffix("{\"did\":true}"), "monitor server: POST with X-Deckhand: action from loopback runs the action", act.text.prefix(30).description)
        let forged = raw("POST /act HTTP/1.1\r\nHost: 127.0.0.1\r\nReferer: http://a/?x-deckhand: action\r\nContent-Length: 0\r\n\r\n", timeout: 5)
        check(forged.text.hasPrefix("HTTP/1.1 403"), "monitor server: the marker inside another header does not count", forged.text.prefix(30).description)
        let wrong = raw("POST /act HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Deckhand: nope\r\nContent-Length: 0\r\n\r\n", timeout: 5)
        check(wrong.text.hasPrefix("HTTP/1.1 403"), "monitor server: X-Deckhand with another value → 403", wrong.text.prefix(30).description)
        let own = await get("/j")
        check(own.0 == 200, "monitor server: loopback reads whatever the allowed peers", "\(own.0)")
        // From this Mac's LAN address the peer is not loopback: 403 unless that address is the bar's.
        if let lan = LocalIP.address(reaching: "192.168.255.254"), !lan.hasPrefix("127.") {
            func lanGet(_ path: String, key: String? = nil) async -> Int {
                var r = URLRequest(url: URL(string: "http://\(lan):\(MonitorServer.shared.port)\(path)")!); r.timeoutInterval = 5
                if let key { r.setValue(key, forHTTPHeaderField: "X-Deckhand-Key") }
                guard let (_, resp) = try? await URLSession.shared.data(for: r) else { return -1 }
                return (resp as? HTTPURLResponse)?.statusCode ?? -1
            }
            let other = await lanGet("/j")
            check(other == 403, "monitor server: another address gets 403", "\(other) via \(lan)")
            MonitorServer.shared.setAllowedPeers([lan])
            let noKey = await lanGet("/j")
            check(noKey == 403, "monitor server: the bar's address without the key gets 403 (M3)", "\(noKey) via \(lan)")
            let barKey = String(repeating: "ab", count: 32)
            MonitorServer.shared.setPeerKey(barKey)
            let wrongKey = await lanGet("/j", key: String(repeating: "cd", count: 32))
            check(wrongKey == 403, "monitor server: a wrong key gets 403", "\(wrongKey)")
            let bar = await lanGet("/j", key: barKey)
            check(bar == 200, "monitor server: the bar's address with the key reads", "\(bar) via \(lan)")
            MonitorServer.shared.setPeerKey(nil)
        } else {
            print("  (skipped the LAN-address checks: no LAN address on this Mac)")
        }
        MonitorServer.shared.setAllowedPeers([])
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

// Store + secret store: file fallback (dev builds, kitcheck) is 0600 in a 0700 folder with hex file names, so a
// serial can never name an API key (L1); forgetting a bar removes its token, key, Wi-Fi passwords and caches.
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kitcheck-store-\(UUID().uuidString.prefix(8))", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = Store(directory: dir)
    func mode(_ url: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int) ?? -1 }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    let files = store.secrets as! FileSecretStore
    let serial = "KCSTORE1"
    store.upsert(serial: serial, name: "check", ip: "10.0.0.9", certSHA256: "AB")
    store.setHotspot(serial: serial, ssid: "cube", password: "hunter2")
    let corebars = dir.appendingPathComponent("corebars.json")
    let corebarsText = (try? String(contentsOf: corebars, encoding: .utf8)) ?? ""
    check(exists(corebars) && mode(corebars) == 0o600, "store: corebars.json is 0600", String(mode(corebars), radix: 8))
    check(!corebarsText.contains("hunter2") && store.hotspot(serial: serial)?.password == "hunter2", "store: hotspot password in the secret store, not corebars.json")
    store.rememberNetwork(serial: serial, ssid: "Home", password: "wifi-pw")
    check(store.savedNetworks(serial: serial).first?.password == "wifi-pw" && !((try? String(contentsOf: corebars, encoding: .utf8)) ?? "").contains("wifi-pw"), "store: saved Wi-Fi passwords in the secret store")
    store.saveToken("tok", serial: serial)
    let token = files.url(.barToken(serial: serial))
    check(mode(token) == 0o600 && store.loadToken(serial: serial) == "tok", "store: token file is 0600 and reads back", String(mode(token), radix: 8))
    check(mode(files.directory) == 0o700, "store: secrets directory is 0700")
    store.saveSecret("key-1", name: "linear")
    check(store.loadSecret(name: "linear") == "key-1" && files.get(.api("linear")) == "key-1", "store: API key reads back")
    // L1: a "bar" whose serial imitates a secret name gets its own account.
    store.saveToken("evil", serial: "secret-linear")
    check(store.loadSecret(name: "linear") == "key-1", "store: a bar serial cannot overwrite an API key (L1)")
    store.deleteToken(serial: "secret-linear")
    check(store.loadSecret(name: "linear") == "key-1", "store: forgetting that bar leaves the API key alone (L1)")
    check(SecretAccount.isValidSerial("ABCD1234") && !SecretAccount.isValidSerial("secret-linear") && !SecretAccount.isValidSerial("abc") && !SecretAccount.isValidSerial(String(repeating: "a", count: 65)), "serial rule ^[A-Za-z0-9]{4,64}$")
    check(Discovery.parse(Data(#"{"serialNo":"secret-zeekr","tcpPort":7431}"#.utf8), from: "10.0.0.5") == nil, "discovery: a serial outside ^[A-Za-z0-9]{4,64}$ is ignored (L1)")
    store.saveToken("tok-2", serial: serial)
    check(mode(token) == 0o600 && store.loadToken(serial: serial) == "tok-2", "store: overwriting a token keeps 0600")
    let key = store.barKey(serial: serial)
    check(key.count == 64 && key.allSatisfy(\.isHexDigit) && store.barKey(serial: serial) == key, "store: per-bar data key is 32 random bytes, stable")
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: files.directory.path))?.filter { $0.hasSuffix(".tmp") } ?? []
    check(leftovers.isEmpty, "store: no temporary files left behind", leftovers.joined(separator: ","))
    store.saveSecret("debounced", name: "aisstream", debounce: true)
    check(store.loadSecret(name: "aisstream") == "debounced" && files.get(.api("aisstream")) == nil, "store: a debounced secret reads back at once, written later")
    store.flushPendingSecrets()
    check(files.get(.api("aisstream")) == "debounced", "store: flush writes the debounced secret")
    store.saveEndpoints(Data("[]".utf8), serial: serial)
    store.rememberModules([["serialNumber": "M1", "ip": "10.0.0.2"]], corebar: serial)
    let ep = dir.appendingPathComponent("endpoints/KCSTORE1.json"), known = dir.appendingPathComponent("endpoints/KCSTORE1.known.json")
    check(exists(ep) && exists(known), "store: endpoint caches written")
    store.remove(serial: serial)
    check(!exists(token) && !exists(ep) && !exists(known) && store.pairedCoreBars.isEmpty, "store: remove(serial:) deletes the token and both endpoint caches")
    check(files.get(.barKey(serial: serial)) == nil && files.get(.hotspot(serial: serial)) == nil && files.get(.wifi(serial: serial, ssid: "Home")) == nil, "store: remove(serial:) deletes the data key, hotspot and Wi-Fi passwords")
    store.saveSecret("", name: "linear")
    check(files.get(.api("linear")) == nil, "store: an empty secret deletes it")
    // Write into a directory that does not exist: must fail quietly, not crash.
    check(!Store.writePrivate(Data("x".utf8), to: dir.appendingPathComponent("missing/dir/file")), "store: writePrivate reports failure instead of crashing")
}

// Secret migration (never against the real files): a temporary folder laid out like 0.4's, into a file store, a
// store that fails, and (when the login Keychain is reachable) a Keychain store under a throw-away service name.
do {
    final class FailingStore: SecretStore, @unchecked Sendable {
        var kind: String { "failing" }
        var items: [String: String] = [:]
        func get(_ a: SecretAccount) -> String? { items[a.account] }
        func set(_ v: String?, for a: SecretAccount) -> OSStatus {
            if a.account == "api:linear" { return -25308 }   // errSecInteractionNotAllowed
            items[a.account] = v; return 0
        }
    }
    func legacyFolder() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kitcheck-migrate-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let tokens = dir.appendingPathComponent("tokens", isDirectory: true)
        try? FileManager.default.createDirectory(at: tokens, withIntermediateDirectories: true)
        for (f, v) in [("ABCD1234.token", "bar-tok"), ("secretlinear.token", "lin_api_x\n"), ("secretstravatokens.token", #"{"access":"a"}"#),
                       ("secretschipholkey.token", "sk"), ("secretwhiskystats.token", "ws")] {
            Store.writePrivate(Data(v.utf8), to: tokens.appendingPathComponent(f))
        }
        Store.writePrivate(Data(#"{"accuWeatherKey":"accu-1","clock24h":true}"#.utf8), to: dir.appendingPathComponent("settings.json"))
        Store.writePrivate(Data(#"{"coreBars":[{"serialNo":"ABCD1234","name":"bar","lastIp":"10.0.0.2","hotspotSSID":"hs","hotspotPassword":"hs-pw","savedNetworks":{"Home":"home-pw"}}]}"#.utf8),
                           to: dir.appendingPathComponent("corebars.json"))
        return dir
    }
    func text(_ u: URL) -> String { (try? String(contentsOf: u, encoding: .utf8)) ?? "" }

    let suite = "kitcheck.migrate.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    // 1. All succeed: values in the store, old files gone, JSON fields stripped, flag set; Store reads them.
    let dir = legacyFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let target = FileSecretStore(directory: dir)
    let store = Store(directory: dir, secrets: target, migrate: defaults)
    let r = store.migrationReport
    check(r?.ok == true && r?.moved.count == 8, "migrate: every legacy secret moved", "\(r?.moved.count ?? -1) moved, \(r?.failed.count ?? -1) failed")
    check(store.loadToken(serial: "ABCD1234") == "bar-tok" && store.loadSecret(name: "linear") == "lin_api_x" && store.loadSecret(name: "strava-tokens") == #"{"access":"a"}"#
          && store.loadSecret(name: "schiphol-key") == "sk" && target.get(.api("accuweather")) == "accu-1", "migrate: values read back through the Store")
    check(store.hotspot(serial: "ABCD1234")?.password == "hs-pw" && store.savedNetworks(serial: "ABCD1234").first?.password == "home-pw", "migrate: hotspot and saved Wi-Fi passwords moved")
    check(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("tokens").path), "migrate: tokens/ folder deleted")
    check(!text(dir.appendingPathComponent("settings.json")).contains("accu-1") && text(dir.appendingPathComponent("settings.json")).contains("clock24h"), "migrate: accuWeatherKey stripped from settings.json, the rest kept")
    let cb = text(dir.appendingPathComponent("corebars.json"))
    check(!cb.contains("hs-pw") && !cb.contains("home-pw") && cb.contains("savedSSIDs") && cb.contains("10.0.0.2"), "migrate: passwords stripped from corebars.json, SSIDs and metadata kept")
    check(defaults.bool(forKey: Store.migrationFlag("files")), "migrate: flag set after full success")
    check(Store(directory: dir, secrets: target, migrate: defaults).migrationReport?.skipped == true, "migrate: runs once (flag)")

    // 2. One item fails: its old copy stays, the others move, no flag.
    let dir2 = legacyFolder()
    defer { try? FileManager.default.removeItem(at: dir2) }
    let failing = FailingStore()
    let r2 = Store(directory: dir2, secrets: failing, migrate: defaults).migrationReport
    check(r2?.ok == false && r2?.failed.map(\.account) == ["api:linear"] && r2?.failed.first?.status == -25308, "migrate: a failed write is reported by account and OSStatus")
    check(FileManager.default.fileExists(atPath: dir2.appendingPathComponent("tokens/secretlinear.token").path)
          && !FileManager.default.fileExists(atPath: dir2.appendingPathComponent("tokens/ABCD1234.token").path), "migrate: the failed item's file is kept, the moved ones deleted")
    check(!defaults.bool(forKey: Store.migrationFlag("failing")), "migrate: no flag while an item failed")

    // 3. The real Keychain under a throw-away service (only items this run created; deleted at the end).
    let kc = KeychainSecretStore(service: "com.denoronha.ultraworkspacemac.kitcheck.\(UUID().uuidString)")
    let probe = kc.set("probe", for: .api("probe"))
    if probe == 0 {
        let dir3 = legacyFolder()
        defer { try? FileManager.default.removeItem(at: dir3) }
        let kStore = Store(directory: dir3, secrets: kc, migrate: defaults)
        check(kStore.migrationReport?.ok == true && kc.get(.barToken(serial: "ABCD1234")) == "bar-tok" && kc.get(.wifi(serial: "ABCD1234", ssid: "Home")) == "home-pw", "keychain: migration into a test service reads back")
        check(kc.set("v2", for: .api("probe")) == 0 && kc.get(.api("probe")) == "v2", "keychain: update in place")
        for a in [SecretAccount.api("probe"), .barToken(serial: "ABCD1234"), .api("linear"), .oauth("strava"), .api("schiphol-secret"), .api("whiskystats"),
                  .api("accuweather"), .hotspot(serial: "ABCD1234"), .wifi(serial: "ABCD1234", ssid: "Home")] { kc.set(nil, for: a) }
        check(kc.read(.barToken(serial: "ABCD1234")).status == errSecItemNotFound, "keychain: delete")
    } else { print("skip  keychain: not reachable here (OSStatus \(probe))") }
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
      {"name":"bridge.1.0.4.4.apk","size":22006908,"digest":"sha256:9F86D081884C7D659A2FEAA0C55AD015A3BF4F1B2B0B822CD15D6C15B0F00A08","browser_download_url":"https://github.com/Qinkunex/UltraWorkspace/releases/download/v1.0.1.0/bridge.1.0.4.4.apk"},
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
    // L2: GitHub's digest is parsed (lowercased) and a file must hash to exactly it; no digest, no match.
    check(r.bridge?.sha256 == "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08" && r.launcher?.sha256 == nil, "vendor release: asset digest parsed")
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kitcheck-digest-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try Data("test".utf8).write(to: tmp)   // sha256("test") = 9f86d081…
    check(VendorRelease.matches(tmp, r.bridge!), "vendor release: a file with the listed SHA-256 matches")
    try Data("tesT".utf8).write(to: tmp)
    check(!VendorRelease.matches(tmp, r.bridge!) && !VendorRelease.matches(tmp, r.launcher!), "vendor release: another file, or an asset without a digest, never matches")
} catch { check(false, "vendor release: parse", "\(error)") }

// APK manifests: package and version read from the binary XML of a Deckhand bar app when a build is present.
do {
    let apk = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist/bar-apps/DeckhandMonitor.apk")
    if FileManager.default.fileExists(atPath: apk.path) {
        let info = try ApkInfo.read(apk: apk)
        check(info.package == "nl.denoronha.deckhand.monitor" && info.versionCode == 16 && info.versionName == "2.5", "apk: DeckhandMonitor.apk manifest = nl.denoronha.deckhand.monitor 2.4 (15)", "\(info)")
    } else { print("skip  apk: no dist/bar-apps/DeckhandMonitor.apk here") }
    do { _ = try ApkInfo.parseManifest(Data("<xml/>".utf8)); check(false, "apk: text XML rejected", "") }
    catch { check(true, "apk: text XML rejected", "") }
    // L3: a string pool whose count and offsets point far outside the file must not crash or loop for ever.
    var evil: [UInt8] = [0x03, 0x00, 0x08, 0x00, 0, 0, 0, 0]                        // XML header
    evil += [0x01, 0x00, 0x1c, 0x00, 0x40, 0, 0, 0]                                   // string pool chunk, 64 bytes
    evil += [0xff, 0xff, 0xff, 0x7f, 0, 0, 0, 0, 0x00, 0x01, 0, 0, 0xf0, 0xff, 0xff, 0x0f, 0, 0, 0, 0]   // n = 2^31-1, UTF-8, start far out
    evil += [UInt8](repeating: 0xff, count: 64 - 28)
    let t0 = Date()
    do { _ = try ApkInfo.parseManifest(Data(evil)); check(false, "apk: hostile string pool rejected", "") }
    catch { check(Date().timeIntervalSince(t0) < 1, "apk: hostile string pool rejected quickly, no crash", "\(error)") }
} catch { check(false, "apk: read", "\(error)") }

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
