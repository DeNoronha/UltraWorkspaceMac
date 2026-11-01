import Foundation

/// High-level operations against one paired CoreBar, identified by IP + token.
/// Each call opens a fresh TLS connection (matching the reference client), so
/// operations are independent and safe to run sequentially.
public struct CoreBarSession: Sendable {
    public let ip: String
    public let token: String
    public let certPin: String?
    public let port: UInt16

    public init(ip: String, token: String, certPin: String?, port: UInt16 = Proto.controlPort) {
        self.ip = ip
        self.token = token
        self.certPin = certPin
        self.port = port
    }

    private func authedClient() async throws -> CoreBarClient {
        let client = CoreBarClient(host: ip, pinnedCertSHA256: certPin, port: port)
        try await client.connect()
        guard try await client.authenticate(token: token) else {
            await client.close()
            throw UltraBarError.authRejected
        }
        return client
    }

    /// Verify the stored token still authenticates. Returns the presented cert
    /// hash so the caller can pin it on first use.
    public func checkToken(timeout: TimeInterval = 8) async -> (accepted: Bool, presentedCert: String?, mismatch: Bool) {
        let client = CoreBarClient(host: ip, pinnedCertSHA256: certPin, port: port)
        do {
            try await client.connect()
            let ok = try await client.authenticate(token: token)
            let cert = await client.presentedCertSHA256
            await client.close()
            return (ok, cert, false)
        } catch UltraBarError.certPinMismatch {
            let cert = await client.presentedCertSHA256
            await client.close()
            return (false, cert, true)
        } catch {
            let cert = await client.presentedCertSHA256
            await client.close()
            return (false, cert, false)
        }
    }

    /// List the physical modules attached to the CoreBar. Tries the gateway
    /// config first (GET_COREBAR_CONFIG / 30740 — returns null on tested
    /// firmware, kept for firmwares that do answer), then a live bus scan
    /// (30100 → pushed 30102), then GET_DEVICE (1300) for logical devices.
    public func listModules() async throws -> [AttachedModule] {
        let client = try await authedClient()
        defer { Task { await client.close() } }
        let emptyObj = try JSONSerialization.data(withJSONObject: [String: Any]())
        // GET_COREBAR_CONFIG expects a ReadWriteRequest naming what to read.
        let gwReq = try JSONSerialization.data(withJSONObject: ["type": "GATEWAY_CONFIG"])

        var modules: [AttachedModule] = []
        if let line = try await client.request(act: Proto.actGetCoreBarConfig, dataJSON: gwReq, timeout: 15),
           let reply = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
           let data = reply["data"] as? [String: Any] {
            for key in ["canGateway", "meshGateway"] {
                if let gw = data[key] as? [String: Any], let eps = gw["endpoints"] as? [[String: Any]] {
                    modules.append(contentsOf: eps.map { Self.endpoint($0) })
                }
            }
            if let eps = data["endpoints"] as? [[String: Any]] {
                modules.append(contentsOf: eps.map { Self.endpoint($0) })
            }
        }
        if !modules.isEmpty { return modules }

        // Live bus scan: the gateway config is empty until a PC app writes it,
        // so trigger a QuantumLink discovery on both buses (CAN = magnetic,
        // mesh = wireless) and collect the pushed endpoints (act 30102, one per
        // found module).
        let canData = try JSONSerialization.data(withJSONObject: "can", options: [.fragmentsAllowed])
        let meshData = try JSONSerialization.data(withJSONObject: "mesh", options: [.fragmentsAllowed])
        try await client.fire(act: Proto.actModuleStartDiscovery, dataJSON: canData)
        try await client.fire(act: Proto.actModuleStartDiscovery, dataJSON: meshData)
        let found = await client.collect(act: Proto.actModuleDiscoveryReplay, duration: 16)
        var bySerial: [String: AttachedModule] = [:]
        for line in found {
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               let d = obj["data"] as? [String: Any] {
                let m = Self.endpoint(d)
                if !m.serial.isEmpty { bySerial[m.serial] = m }
            }
        }
        if !bySerial.isEmpty { return Array(bySerial.values) }

        // Fallback: GET_DEVICE (logical/integration devices).
        if let line = try await client.request(act: Proto.actGetDevice, dataJSON: emptyObj, timeout: 15),
           let reply = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
           let arr = reply["data"] as? [[String: Any]] {
            return arr.map { d in
                let serial = (d["serialNo"] as? String) ?? (d["id"] as? String) ?? ""
                return AttachedModule(deviceId: (d["id"] as? String) ?? serial,
                                      name: (d["name"] as? String) ?? "",
                                      type: (d["deviceType"] as? String) ?? "UNKNOWN",
                                      online: (d["online"] as? Bool) ?? true, serial: serial)
            }
        }
        return []
    }

    /// Provision the CoreBar: scan the buses and write the discovered modules
    /// into the gateway config (SET_GATEWAY_CONFIG / 30300) so they become
    /// controllable. Returns the merged module list, the endpoints blob to cache,
    /// and a diagnostic line. This changes device configuration (full replace).
    public func provision(scanSeconds: TimeInterval = 16, priorEndpoints: Data? = nil) async throws -> (modules: [AttachedModule], endpointsJSON: Data, diagnostic: String) {
        let client = try await authedClient()
        defer { Task { await client.close() } }
        let canData = try JSONSerialization.data(withJSONObject: "can", options: [.fragmentsAllowed])
        let meshData = try JSONSerialization.data(withJSONObject: "mesh", options: [.fragmentsAllowed])
        // Re-trigger discovery several times across the window: a module that is
        // asleep (often the DotKey) may only answer a later round.
        var found: [Data] = []
        let rounds = max(1, Int(scanSeconds / 5))
        for _ in 0..<rounds {
            try await client.fire(act: Proto.actModuleStartDiscovery, dataJSON: canData)
            try await client.fire(act: Proto.actModuleStartDiscovery, dataJSON: meshData)
            found += await client.collect(act: Proto.actModuleDiscoveryReplay, duration: 5)
        }

        // Start from the previously-written endpoints so a module that is asleep
        // during this scan (common for the DotKey) is not dropped from the config.
        // A freshly discovered endpoint overrides its remembered copy.
        var bySerial: [String: [String: Any]] = [:]
        if let priorEndpoints,
           let arr = try? JSONSerialization.jsonObject(with: priorEndpoints) as? [[String: Any]] {
            for d in arr {
                let s = Self.serialOf(d); if !s.isEmpty { bySerial[s] = d }
            }
        }
        let remembered = bySerial.count
        var freshCount = 0
        for line in found {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let d = obj["data"] as? [String: Any] else { continue }
            let serial = Self.serialOf(d)
            guard !serial.isEmpty else { continue }
            bySerial[serial] = d
            freshCount += 1
        }
        guard !bySerial.isEmpty else {
            return ([], Data("[]".utf8), "no modules found (are they awake? tap the CoreBar screen)")
        }

        // SET_GATEWAY_CONFIG (30300) takes the CoreBarConfiguration as the body
        // directly (SET_COREBAR_CONFIG/30741 wraps it in a ReadWriteRequest and
        // the device throws ClassCastException).
        let all = Array(bySerial.values)
        let canEps = all.filter { ($0["interfaceType"] as? String) != "mesh" }
        let meshEps = all.filter { ($0["interfaceType"] as? String) == "mesh" }
        let config: [String: Any] = [
            "canGateway": ["endpoints": canEps],
            "meshGateway": ["endpoints": meshEps],
        ]
        let reqData = try JSONSerialization.data(withJSONObject: config)
        var replyStr = "<no reply>"
        if let line = try await client.request(act: Proto.actSetGatewayConfig, dataJSON: reqData, timeout: 15) {
            replyStr = String(data: line, encoding: .utf8) ?? "<non-utf8>"
        }
        let endpointsJSON = (try? JSONSerialization.data(withJSONObject: all)) ?? Data("[]".utf8)
        let modules = all.map { Self.endpoint($0) }
        return (modules, endpointsJSON, "wrote \(modules.count) modules (\(freshCount) awake now, \(remembered) remembered) · setReply=\(replyStr.prefix(140))")
    }

    private static func serialOf(_ d: [String: Any]) -> String {
        (d["serialNumber"] as? String) ?? (d["serialNo"] as? String) ?? (d["uid"] as? String) ?? ""
    }

    /// Decode a cached endpoints blob (as produced by `provision`) into modules,
    /// so the app can show the last-known modules instantly, without a bus scan.
    public static func modulesFromEndpoints(_ data: Data) -> [AttachedModule] {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.map { endpoint($0) }
    }

    private static func endpoint(_ e: [String: Any]) -> AttachedModule {
        let serial = (e["serialNumber"] as? String) ?? (e["serialNo"] as? String) ?? (e["uid"] as? String) ?? ""
        return AttachedModule(
            deviceId: (e["uid"] as? String) ?? serial,
            name: (e["name"] as? String) ?? "",
            type: productType(e["productId"]),
            online: (e["online"] as? Bool) ?? true,
            serial: serial
        )
    }

    /// Map a QLinkProductId (int or name) to our normalized type string.
    private static func productType(_ v: Any?) -> String {
        if let s = v as? String, !s.isEmpty { return s.uppercased() }
        let n: Int? = (v as? Int) ?? (v as? NSNumber)?.intValue
        switch n {
        case 268435456: return "EXT_SCREEN"
        case 268435457: return "DOT_KEY"
        case 268435458: return "KNOB_KEY"
        case 268435459: return "VIVO_CUBE"
        case 268435460: return "SENSE_CUBE"
        case 268435461: return "PC_BOOT"
        case -1: return "GATEWAY"
        default: return "UNKNOWN"
        }
    }

    /// Diagnostic: send an act with empty `{}` data and return the raw reply line
    /// (as text). Used to inspect what a given firmware actually returns.
    public func rawRequest(act: Int, data: [String: Any] = [:], timeout: TimeInterval = 15) async throws -> String {
        let client = try await authedClient()
        defer { Task { await client.close() } }
        let json = try JSONSerialization.data(withJSONObject: data)
        guard let line = try await client.request(act: act, dataJSON: json, timeout: timeout) else {
            return "<no reply to act \(act)>"
        }
        return String(data: line, encoding: .utf8) ?? "<non-utf8 reply>"
    }

    public func readProperty(serial: String, deviceId: Int = Proto.deviceMain, propertyId: Int, timeout: TimeInterval = 8) async -> Int64? {
        do {
            let client = try await authedClient()
            defer { Task { await client.close() } }
            let data: [String: Any] = [
                "serialNo": serial, "deviceId": deviceId,
                "propertyId": propertyId, "extra": NSNull(),
            ]
            let json = try JSONSerialization.data(withJSONObject: data)
            guard let line = try await client.request(act: Proto.actReadProp, dataJSON: json, timeout: timeout),
                  let reply = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  code(reply) == 200,
                  let d = reply["data"] as? [String: Any],
                  let result = d["result"] else { return nil }
            return int64(result)
        } catch { return nil }
    }

    @discardableResult
    public func writeProperty(serial: String, propertyId: Int, value: Any, timeout: TimeInterval = 8) async -> Int? {
        do {
            let client = try await authedClient()
            defer { Task { await client.close() } }
            let data: [String: Any] = [
                "serialNo": serial, "deviceId": Proto.deviceMain,
                "propertyId": propertyId, "value": value,
            ]
            let json = try JSONSerialization.data(withJSONObject: data)
            guard let line = try await client.request(act: Proto.actWriteProp, dataJSON: json, timeout: timeout),
                  let reply = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
            return code(reply)
        } catch { return nil }
    }

    /// SenseCube ambient readings. Temp/humidity/light are pollable over the
    /// protocol (raw ints in `result`); the app does the scaling. Presence,
    /// audio and vibration are event-only and not exposed here.
    public struct SenseReading: Sendable {
        public var temperatureC: Double?   // °C
        public var humidity: Double?       // %RH
        public var lux: Int?               // illuminance
        public init(temperatureC: Double?, humidity: Double?, lux: Int?) {
            self.temperatureC = temperatureC; self.humidity = humidity; self.lux = lux
        }
    }

    public func readSenseCube(serial: String) async -> SenseReading {
        let t = await readProperty(serial: serial, deviceId: 11, propertyId: 1)
        let h = await readProperty(serial: serial, deviceId: 12, propertyId: 1)
        let l = await readProperty(serial: serial, deviceId: 10, propertyId: 1)
        return SenseReading(temperatureC: t.map { Double($0) / 10.0 },
                            humidity: h.map { Double($0) / 10.0 },
                            lux: l.map { Int($0) })
    }

    public func setScreen(serial: String, on: Bool) async -> Int? {
        await writeProperty(serial: serial, propertyId: Proto.Property.screen, value: on ? 1 : 0)
    }

    public func reboot(serial: String) async {
        _ = await writeProperty(serial: serial, propertyId: Proto.Property.reboot, value: true, timeout: 0.3)
    }

    /// Upload a layer package (tgz) to a module over HTTP. If the module isn't
    /// registered yet ("module not found"), provision the CoreBar once and retry.
    public func upload(serial: String, tgz: Data) async throws -> Bool {
        let (accepted, text) = try await postUpload(serial: serial, tgz: tgz)
        if accepted { return true }
        if text.contains("module not found") {
            WireLog.shared.event("upload: module not registered — provisioning then retrying")
            _ = try? await provision(scanSeconds: 14)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let (ok2, text2) = try await postUpload(serial: serial, tgz: tgz)
            if ok2 { return true }
            throw UltraBarError.uploadRejected(text2)
        }
        throw UltraBarError.uploadRejected(text)
    }

    // MARK: CoreBar big screen (1424×280)
    //
    // The CoreBar's own screen takes ordinary image files (jpg/png), not the
    // RGB565 tgz used by modules. Assets are delivered as a .zip that the device
    // unzips into its external files dir under `subDir`; images can then be
    // referenced by the relative path "<subDir>/<file>". `isFull = true` wipes
    // the subdir first. Route: POST :8080/upload/zip?subDir=<x>&isFull=<bool>.

    @discardableResult
    public func uploadScreenZip(_ zip: Data, subDir: String, isFull: Bool = false) async throws -> (accepted: Bool, text: String) {
        let q = "subDir=\(subDir.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subDir)&isFull=\(isFull)"
        guard let url = URL(string: "http://\(ip):\(Proto.uploadPort)/upload/zip?\(q)") else {
            throw UltraBarError.protocolError("bad upload URL")
        }
        let boundary = "ubw-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"assets.zip\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/zip\r\n\r\n".data(using: .utf8)!)
        body.append(zip)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        WireLog.shared.http("POST \(url.absoluteString) (\(zip.count) B zip)")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let text = String(data: data, encoding: .utf8) ?? ""
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        WireLog.shared.http("← \(status) \(text.prefix(200))")
        let accepted = (200..<300).contains(status)
        return (accepted, text.isEmpty ? "HTTP \(status)" : text)
    }

    /// Non-destructive: show a full-screen image on the CoreBar screen right now
    /// (PREVIEW_SCREENSAVER / act 30742). One-shot; does NOT change saved config
    /// or any profile/page. `path` is an http URL or a relative path the device
    /// resolves under its external files dir (e.g. "wallpaper/preview.jpg").
    @discardableResult
    public func previewScreen(path: String, isVideo: Bool = false) async throws -> String {
        let client = try await authedClient()
        defer { Task { await client.close() } }
        let payload: [String: Any] = ["url": path, "mediaType": isVideo ? "VIDEO" : "IMAGE"]
        let json = try JSONSerialization.data(withJSONObject: payload)
        guard let line = try await client.request(act: Proto.actPreviewScreensaver, dataJSON: json, timeout: 10) else {
            return "<no reply>"
        }
        return String(data: line, encoding: .utf8) ?? "<non-utf8>"
    }

    private func postUpload(serial: String, tgz: Data) async throws -> (accepted: Bool, text: String) {
        let boundary = "ubw-\(UUID().uuidString)"
        guard let url = URL(string: "http://\(ip):\(Proto.uploadPort)/upload?serialNo=\(serial.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? serial)") else {
            throw UltraBarError.protocolError("bad upload URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(serial).tgz\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/gzip\r\n\r\n".data(using: .utf8)!)
        body.append(tgz)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        WireLog.shared.http("POST \(url.absoluteString) (\(tgz.count) B tgz)")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let text = String(data: data, encoding: .utf8) ?? ""
        WireLog.shared.http("← \((resp as? HTTPURLResponse)?.statusCode ?? 0) \(text.prefix(200))")
        let httpOK = (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        let accepted = httpOK && text.contains("\"state\":200") && text.contains("\"msg\":\"ok\"")
        return (accepted, text.isEmpty ? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)" : text)
    }

    // helpers
    private func code(_ obj: [String: Any]) -> Int? {
        if let v = obj["code"] as? Int { return v }
        if let n = obj["code"] as? NSNumber { return n.intValue }
        return nil
    }
    private func int64(_ v: Any) -> Int64? {
        if let i = v as? Int64 { return i }
        if let i = v as? Int { return Int64(i) }
        if let n = v as? NSNumber { return n.int64Value }
        if let s = v as? String, let i = Int64(s) { return i }
        return nil
    }
}
