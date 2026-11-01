import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import UltraBarKit

/// `kitcheck e2e [ip]` — drive the full UltraBarKit protocol path against a
/// CoreBar (by default the mock on 127.0.0.1) and verify each step, including
/// what the mock's web viewer (:8081) recorded. Exits non-zero on any failure.
enum E2E {
    static func run(ip: String) async -> Int {
        var failures = 0
        func check(_ cond: Bool, _ name: String, _ detail: String = "") {
            print("\(cond ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
            if !cond { failures += 1 }
        }
        func fetchState() async -> [String: Any] {
            guard let url = URL(string: "http://\(ip):8081/state"),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return obj
        }

        print("== E2E against \(ip) ==")

        // 1. Unicast discovery probe (Add-by-IP path)
        let bar = await Discovery.probe(ip: ip, timeout: 3)
        check(bar != nil, "probe(ip:) replies", bar.map { "\($0.name) sn=\($0.serialNo) tcp=\($0.tcpPort)" } ?? "no reply")
        guard let bar else { return 1 }
        check(bar.tcpPort == Int(Proto.controlPort), "advertised tcpPort == 7431")

        // 2. Pair (REQ_AUTH_TOKEN) → token + presented cert (TOFU)
        let client = CoreBarClient(host: ip)
        var token = ""
        var cert: String?
        do {
            try await client.connect()
            cert = await client.presentedCertSHA256
            token = try await client.pair(clientName: "kitcheck", approvalWindow: 10)
            await client.close()
        } catch { check(false, "pair", "\(error)") }
        check(!token.isEmpty, "pair returns token", token)
        check((cert ?? "").count == 64, "presented cert SHA-256 captured", String(cert?.prefix(16) ?? ""))

        // 3. Token check with the pinned cert
        let session = CoreBarSession(ip: ip, token: token, certPin: cert)
        let tc = await session.checkToken()
        check(tc.accepted && !tc.mismatch, "checkToken with correct pin accepted")

        // 3b. Wrong pin must be rejected BEFORE auth (security)
        let bad = CoreBarSession(ip: ip, token: token, certPin: String(repeating: "00", count: 32))
        let badCheck = await bad.checkToken()
        check(!badCheck.accepted && badCheck.mismatch, "wrong cert pin → mismatch, not authenticated")

        // 4. Module listing (live bus scan path, since mock gateway config is null)
        var modules: [AttachedModule] = []
        do { modules = try await session.listModules() } catch { check(false, "listModules", "\(error)") }
        let types = Set(modules.map(\.type))
        check(modules.count == 4, "listModules finds 4 modules", "\(modules.count): \(types.sorted())")
        check(types.isSuperset(of: ["VIVO_CUBE", "SENSE_CUBE", "KNOB_KEY", "DOT_KEY"]), "all four product types mapped")
        let vivo = modules.first { $0.isVivoCube }
        let sense = modules.first { $0.type == "SENSE_CUBE" }
        let dot = modules.first { $0.type == "DOT_KEY" }
        check(dot?.online == false, "asleep DotKey reported offline (mesh)")

        // 5. Provision with prior endpoints (merge path) → config written
        do {
            let prior = try JSONSerialization.data(withJSONObject: [["serialNumber": "FFFFFFFFFFFF0099", "name": "Remembered Key", "productId": 268435457, "interfaceType": "mesh"]])
            let p = try await session.provision(scanSeconds: 5, priorEndpoints: prior)
            check(p.modules.count == 5, "provision merges remembered + fresh", "\(p.modules.count) · \(p.diagnostic.prefix(90))")
            let cached = CoreBarSession.modulesFromEndpoints(p.endpointsJSON)
            check(cached.count == 5, "endpointsJSON round-trips via modulesFromEndpoints")
            let st = await fetchState()
            // mock stores whatever SET_GATEWAY_CONFIG sent; nothing else to assert beyond the log
            let logs = (st["log"] as? [[String: Any]])?.compactMap { $0["text"] as? String } ?? []
            check(logs.contains { $0.contains("SET_GATEWAY_CONFIG stored") }, "mock recorded SET_GATEWAY_CONFIG (30300)")
        } catch { check(false, "provision", "\(error)") }

        // 6. SenseCube readings (deviceId 11/12/10, ÷10 scaling)
        if let sense {
            let r = await session.readSenseCube(serial: sense.serial)
            check(r.temperatureC == 23.5, "SenseCube temperature 23.5 °C", String(describing: r.temperatureC))
            check(r.humidity == 54.0, "SenseCube humidity 54 %RH", String(describing: r.humidity))
            check(r.lux == 473, "SenseCube light 473 lux", String(describing: r.lux))
        } else { check(false, "SenseCube present") }

        // 7. VivoCube image: RGBA → RGB565 tgz → POST /upload → viewer decodes 240×240
        if let vivo {
            let w = 240, h = 240
            var rgba = [UInt8](repeating: 0, count: w * h * 4)
            for y in 0..<h {
                for x in 0..<w {
                    let i: Int = (y * w + x) * 4
                    let r: Int = x * 255 / (w - 1)
                    let g: Int = y * 255 / (h - 1)
                    rgba[i] = UInt8(r)
                    rgba[i + 1] = UInt8(g)
                    rgba[i + 2] = 128
                    rgba[i + 3] = 255
                }
            }
            let bin = DeviceImage.encode(width: w, height: h, rgba: rgba)
            let tgz = DeployPackager.buildTgz(layers: [.init(layerId: 1, widgetId: 101, defaultBin: bin, pressedBin: bin)], defaultLayer: 1)
            do {
                let ok = try await session.upload(serial: vivo.serial, tgz: tgz)
                check(ok, "upload tgz accepted ({state:200})", "\(tgz.count) B")
            } catch { check(false, "upload tgz", "\(error)") }
            let st = await fetchState()
            let m = (st["modules"] as? [[String: Any]])?.first { ($0["serialNo"] as? String) == vivo.serial }
            let img = m?["image"] as? [String: Any]
            check(img != nil, "viewer decoded an image for the VivoCube")
            check((img?["width"] as? Int) == 240 && (img?["height"] as? Int) == 240, "decoded size 240×240", "\(img?["width"] ?? "?")×\(img?["height"] ?? "?")")
            check((img?["widgetId"] as? Int) == 101, "widgetId 101 preserved through tar")
            // Pixel check: fetch the PNG and verify orientation (top-left ≈ (0,0,128), bottom-right ≈ (255,255,128)).
            if let u = img?["url"] as? String, let url = URL(string: "http://\(ip):8081\(u)"),
               let (png, _) = try? await URLSession.shared.data(from: url),
               let src = CGImageSourceCreateWithData(png as CFData, nil),
               let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
               let px = DeviceImage.rgba(from: cg, width: 240, height: 240) {
                let tl = (px[0], px[1]); let br = (px[(239*240+239)*4], px[(239*240+239)*4+1])
                check(tl.0 < 16 && tl.1 < 16 && br.0 > 230 && br.1 > 230, "image orientation (not flipped/mirrored)", "tl=\(tl) br=\(br)")
            } else { check(false, "fetch decoded PNG from viewer") }
        } else { check(false, "VivoCube present") }

        // 8. CoreBar big screen: PNG → zip → /upload/zip → PREVIEW_SCREENSAVER
        do {
            let png = makePNG(width: 1424, height: 280)
            check(png.count > 100, "rendered 1424×280 PNG", "\(png.count) B")
            let zip = ZipWriter.archive([.init(name: "preview.png", data: png)])
            let (ok, text) = try await session.uploadScreenZip(zip, subDir: "deckhand", isFull: true)
            check(ok, "upload/zip accepted", text.prefix(60).description)
            let reply = try await session.previewScreen(path: "deckhand/preview.png")
            check(reply.contains("\"code\":200"), "PREVIEW_SCREENSAVER (30742) code 200", reply.prefix(80).description)
            let st = await fetchState()
            let assets = (st["assets"] as? [[String: Any]])?.compactMap { $0["path"] as? String } ?? []
            check(assets.contains("deckhand/preview.png"), "zip extracted to deckhand/preview.png", assets.joined(separator: ","))
            let prev = st["preview"] as? [String: Any]
            check((prev?["url"] as? String) == "deckhand/preview.png", "viewer shows preview pointing at the asset", "\(prev ?? [:])")
        } catch { check(false, "big screen flow", "\(error)") }

        // 9. Raw request to an unknown act must not hang the client
        do {
            let r = try await session.rawRequest(act: 424242, timeout: 5)
            check(r.contains("424242"), "unknown act gets a correlated reply", r.prefix(60).description)
        } catch { check(false, "rawRequest", "\(error)") }

        print(failures == 0 ? "\nE2E PASSED" : "\n\(failures) E2E CHECK(S) FAILED")
        return failures == 0 ? 0 : 1
    }

    /// Simple gradient PNG via CoreGraphics (what the app's renderer also produces).
    static func makePNG(width: Int, height: Int) -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        ctx.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.5, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.1, alpha: 1)); ctx.fillEllipse(in: CGRect(x: 40, y: 40, width: 200, height: 200))
        guard let img = ctx.makeImage() else { return Data() }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}
