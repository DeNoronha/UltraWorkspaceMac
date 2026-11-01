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

    /// List the physical modules attached to the CoreBar. Primary source is the
    /// gateway config (GET_COREBAR_CONFIG / act 30740), whose `canGateway` /
    /// `meshGateway` endpoints are the QuantumLink modules. Falls back to
    /// GET_DEVICE (1300) for logical/integration devices.
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
        let found = await client.collect(act: Proto.actModuleDiscoveryReplay, duration: 12)
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
    /// into the gateway config (SET_COREBAR_CONFIG) so they become controllable.
    /// Returns the number of modules written. This changes device configuration.
    public func provision(scanSeconds: TimeInterval = 12) async throws -> Int {
        let client = try await authedClient()
        defer { Task { await client.close() } }
        let canData = try JSONSerialization.data(withJSONObject: "can", options: [.fragmentsAllowed])
        let meshData = try JSONSerialization.data(withJSONObject: "mesh", options: [.fragmentsAllowed])
        try await client.fire(act: Proto.actModuleStartDiscovery, dataJSON: canData)
        try await client.fire(act: Proto.actModuleStartDiscovery, dataJSON: meshData)
        let found = await client.collect(act: Proto.actModuleDiscoveryReplay, duration: scanSeconds)

        var canEps: [String: [String: Any]] = [:]
        var meshEps: [String: [String: Any]] = [:]
        for line in found {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let d = obj["data"] as? [String: Any] else { continue }
            let serial = (d["serialNumber"] as? String) ?? (d["serialNo"] as? String) ?? (d["uid"] as? String) ?? ""
            guard !serial.isEmpty else { continue }
            if (d["interfaceType"] as? String) == "mesh" { meshEps[serial] = d } else { canEps[serial] = d }
        }
        let total = canEps.count + meshEps.count
        guard total > 0 else { return 0 }

        let config: [String: Any] = [
            "canGateway": ["endpoints": Array(canEps.values)],
            "meshGateway": ["endpoints": Array(meshEps.values)],
        ]
        let req: [String: Any] = ["type": "GATEWAY_CONFIG", "value": config]
        let reqData = try JSONSerialization.data(withJSONObject: req)
        guard let line = try await client.request(act: Proto.actSetCoreBarConfig, dataJSON: reqData, timeout: 15),
              let reply = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw UltraBarError.protocolError("no reply to SET_COREBAR_CONFIG")
        }
        let code = (reply["code"] as? Int) ?? (reply["code"] as? NSNumber)?.intValue ?? -1
        if code != 200 {
            let msg = (reply["msg"] as? String) ?? "code \(code)"
            throw UltraBarError.protocolError("provisioning rejected: \(msg)")
        }
        return total
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

    public func readProperty(serial: String, propertyId: Int, timeout: TimeInterval = 8) async -> Int64? {
        do {
            let client = try await authedClient()
            defer { Task { await client.close() } }
            let data: [String: Any] = [
                "serialNo": serial, "deviceId": Proto.deviceMain,
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

    public func setScreen(serial: String, on: Bool) async -> Int? {
        await writeProperty(serial: serial, propertyId: Proto.Property.screen, value: on ? 1 : 0)
    }

    public func reboot(serial: String) async {
        _ = await writeProperty(serial: serial, propertyId: Proto.Property.reboot, value: true, timeout: 0.3)
    }

    /// Upload a layer package (tgz) to a module over HTTP.
    public func upload(serial: String, tgz: Data) async throws -> Bool {
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

        let (data, resp) = try await URLSession.shared.data(for: req)
        let text = String(data: data, encoding: .utf8) ?? ""
        let httpOK = (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        let accepted = httpOK && text.contains("\"state\":200") && text.contains("\"msg\":\"ok\"")
        if !accepted { throw UltraBarError.uploadRejected(text.isEmpty ? "HTTP \( (resp as? HTTPURLResponse)?.statusCode ?? 0)" : text) }
        return true
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
