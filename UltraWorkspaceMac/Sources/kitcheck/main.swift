import Foundation
import Compression
import UltraBarKit

setvbuf(stdout, nil, _IONBF, 0) // line-by-line output even when piped/killed

// `kitcheck discover` — run the app's real Discovery from the terminal (which
// already has Local Network permission) to prove the code works against hardware.
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
@MainActor func check(_ cond: Bool, _ name: String) {
    print("\(cond ? "ok  " : "FAIL") \(name)")
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

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
