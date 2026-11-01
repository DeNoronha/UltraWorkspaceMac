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

    /// List all devices/modules the CoreBar knows about (GET_DEVICE / act 1300).
    public func listModules() async throws -> [AttachedModule] {
        let client = try await authedClient()
        defer { Task { await client.close() } }
        let emptyObj = try JSONSerialization.data(withJSONObject: [String: Any]())
        guard let line = try await client.request(act: Proto.actGetDevice, dataJSON: emptyObj, timeout: 15),
              let reply = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let arr = reply["data"] as? [[String: Any]] else { return [] }
        return arr.map { d in
            let attr = d["attr"] as? [String: Any]
            let serial = (attr?["serialNo"] as? String)
                ?? (attr?["sn"] as? String)
                ?? (attr?["serial"] as? String)
                ?? (d["serialNo"] as? String)
                ?? (d["id"] as? String) ?? ""
            return AttachedModule(
                deviceId: (d["id"] as? String) ?? serial,
                name: (d["name"] as? String) ?? "",
                type: (d["deviceType"] as? String) ?? "UNKNOWN",
                online: (d["online"] as? Bool) ?? true,
                serial: serial
            )
        }
    }

    /// Diagnostic: send an act with empty `{}` data and return the raw reply line
    /// (as text). Used to inspect what a given firmware actually returns.
    public func rawRequest(act: Int, timeout: TimeInterval = 15) async throws -> String {
        let client = try await authedClient()
        defer { Task { await client.close() } }
        let empty = try JSONSerialization.data(withJSONObject: [String: Any]())
        guard let line = try await client.request(act: act, dataJSON: empty, timeout: timeout) else {
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
