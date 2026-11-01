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

        // 7b. Multi-layer package + layer switching via property 9 (official rotation model)
        if let vivo {
            func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> [UInt8] {
                var px = [UInt8](repeating: 255, count: 240 * 240 * 4)
                for i in stride(from: 0, to: px.count, by: 4) { px[i] = r; px[i+1] = g; px[i+2] = b }
                return px
            }
            let l1 = DeviceImage.encode(width: 240, height: 240, rgba: solid(200, 30, 30))
            let l2 = DeviceImage.encode(width: 240, height: 240, rgba: solid(30, 200, 30))
            let tgz = DeployPackager.buildTgz(layers: [.init(layerId: 1, widgetId: 101, defaultBin: l1, pressedBin: l1),
                                                       .init(layerId: 2, widgetId: 102, defaultBin: l2, pressedBin: l2)], defaultLayer: 1)
            do { _ = try await session.upload(serial: vivo.serial, tgz: tgz) } catch { check(false, "multi-layer upload", "\(error)") }
            func shownWidget() async -> Int? {
                let st = await fetchState()
                let m = (st["modules"] as? [[String: Any]])?.first { ($0["serialNo"] as? String) == vivo.serial }
                return (m?["image"] as? [String: Any])?["widgetId"] as? Int
            }
            let w1 = await shownWidget()
            check(w1 == 101, "after multi-layer upload the cached layer stays on widget 101", "\(w1 ?? -1)")
            let sw = await session.setLayer(serial: vivo.serial, layer: 2, widget: 102)
            check(sw == 200, "property 9 write (layer 2 / widget 102) acknowledged")
            let w2 = await shownWidget()
            check(w2 == 102, "layer switch shows widget 102 without re-upload", "\(w2 ?? -1)")
            let lw = await session.readLayerWidget(serial: vivo.serial)
            check(lw?.layer == 2 && lw?.widget == 102, "readLayerWidget reflects the cached value", "\(String(describing: lw))")
            _ = await session.setLayer(serial: vivo.serial, layer: 3, widget: 103) // not in package → black
            let w3 = await shownWidget()
            check(w3 == nil, "stale layer/widget not in package → nothing shown (black)", "\(w3 ?? -1)")
            let rec = await session.recoverDisplay(serial: vivo.serial)
            let w4 = await shownWidget()
            check(rec && w4 == 101, "recoverDisplay brings back layer 1 / widget 101", "\(w4 ?? -1)")
        }

        // 7c. CoreBar pages: list → save (superset) → switch; guards against wipes
        do {
            let before = try await session.listPages()
            check(before.contains { $0.id == "default" }, "device lists the standard page 'default'", "\(before.map(\.id))")
            do { _ = try await session.savePages([]); check(false, "empty page list refused client-side") }
            catch { check(true, "empty page list refused client-side") }
            try await session.uploadPageAsset(makePNG(width: 480, height: 480), name: "cover.png")
            let st0 = await fetchState()
            let assets = (st0["assets"] as? [[String: Any]])?.compactMap { $0["path"] as? String } ?? []
            check(assets.contains("deckhand/cover.png"), "page cover uploaded under deckhand/", assets.joined(separator: ","))
            let pages: [[String: Any]] = [
                ["id": "default", "name": "Standard Mode", "isDefault": true, "showName": true, "iconScale": 100, "module": [],
                 "widget": [["id": "sys.component.time", "type": "TIME", "name": "Time", "icon": ""]]],
                ["id": "deckhand.page", "name": "Deckhand", "isDefault": false, "showName": true, "iconScale": 100, "icon": "deckhand/cover.png", "module": [],
                 "widget": [["id": "sys.component.time", "type": "TIME", "name": "Deckhand", "icon": "deckhand/cover.png"]]],
            ]
            let r = try await session.savePages(pages)
            check(r.contains("\"code\":200"), "BATCH_SAVE_PROFILE accepted", r.prefix(60).description)
            let after = try await session.listPages()
            check(Set(after.map(\.id)) == ["default", "deckhand.page"], "both pages listed afterwards", "\(after.map(\.id))")
            _ = try await session.switchPage(id: "deckhand.page")
            let st = await fetchState()
            check((st["activeProfileId"] as? String) == "deckhand.page", "TRIGGER_PROFILE_CHANGE switched the active page")
            do { _ = try await session.switchPage(id: "nope"); check(false, "unknown page id rejected") }
            catch { check(true, "unknown page id rejected ('profile id error')") }
        } catch { check(false, "pages flow", "\(error)") }

        // 8. CoreBar big screen: zip upload still works, and PREVIEW_SCREENSAVER
        //    with an http URL served by this machine (the device PULLS the image).
        do {
            let png = makePNG(width: 1424, height: 280)
            check(png.count > 100, "rendered 1424×280 PNG", "\(png.count) B")
            let zip = ZipWriter.archive([.init(name: "preview.png", data: png)])
            let (ok, text) = try await session.uploadScreenZip(zip, subDir: "deckhand", isFull: true)
            check(ok, "upload/zip accepted", text.prefix(60).description)
            let st0 = await fetchState()
            let assets = (st0["assets"] as? [[String: Any]])?.compactMap { $0["path"] as? String } ?? []
            check(assets.contains("deckhand/preview.png"), "zip extracted to deckhand/preview.png", assets.joined(separator: ","))

            try PreviewServer.shared.start()
            PreviewServer.shared.publish(png, name: "e2e.png")
            let url = PreviewServer.shared.url(for: "e2e.png", reachableFrom: ip)
            check(url?.hasPrefix("http://") == true, "preview server URL reachable from \(ip)", url ?? "nil")
            // Self-fetch to prove the server speaks HTTP.
            if let u = url.flatMap(URL.init(string:)), let (d, r) = try? await URLSession.shared.data(from: u) {
                check((r as? HTTPURLResponse)?.statusCode == 200 && d == png, "preview server serves the exact PNG")
            } else { check(false, "preview server self-fetch") }
            do { _ = try await session.previewScreen(url: "deckhand/preview.png"); check(false, "non-http preview url rejected") }
            catch { check(true, "non-http preview url rejected client-side") }
            let reply = try await session.previewScreen(url: url ?? "")
            check(reply.contains("\"code\":200") || reply.hasPrefix("sent"), "PREVIEW_SCREENSAVER (30742) dispatched", reply.prefix(80).description)
            try? await Task.sleep(nanoseconds: 800_000_000) // let the mock fetch it
            let st = await fetchState()
            let prev = st["preview"] as? [String: Any]
            check((prev?["url"] as? String) == url, "mock recorded the http preview url", "\(prev?["url"] ?? "nil")")
            check((prev?["fetched"] as? Bool) == true, "mock fetched the image from this machine", "\(prev?["fetchBytes"] ?? "no fetch")")
        } catch { check(false, "big screen flow", "\(error)") }

        // 8b. Persistent link: heartbeat + answering the device's push queries
        do {
            let link = CoreBarLink(ip: ip, token: token, certPin: cert)
            final class Seen: @unchecked Sendable {
                private var types: [String] = []; private let lock = NSLock()
                func add(_ t: String) { lock.withLock { types.append(t) } }
                var all: Set<String> { lock.withLock { Set(types) } }
            }
            let seen = Seen()
            await link.start { type, payload in
                seen.add(type)
                switch type {
                case "CPU": return 37
                case "MEMORY": return 61
                case "STORAGE": return 48
                case "NETWORK": return ["totalReceived": 123_456_789, "totalSent": 9_876_543]
                case "GET_VOLUME": return 45
                case "SET_VOLUME": return payload
                default: return NSNull()
                }
            }
            try? await Task.sleep(nanoseconds: 7_500_000_000)
            let st = await fetchState()
            let linkInfo = st["link"] as? [String: Any]
            let hb = (linkInfo?["heartbeats"] as? Int) ?? 0
            check(await link.state == .connected, "link reports connected")
            check(hb >= 1, "mock received heartbeats (act 20)", "\(hb)")
            let metrics = linkInfo?["macMetrics"] as? [String: Any]
            check((metrics?["CPU"] as? Int) == 37, "CPU query answered with percent", "\(metrics?["CPU"] ?? "nil")")
            check((metrics?["NETWORK"] as? [String: Any])?["totalReceived"] as? Int == 123_456_789, "NETWORK answered with cumulative totals")
            check((linkInfo?["macVolume"] as? Int) == 45, "GET_VOLUME answered", "\(linkInfo?["macVolume"] ?? "nil")")
            let types = seen.all
            check(types.isSuperset(of: ["CPU", "GET_VOLUME", "NETWORK"]), "handler saw CPU/NETWORK/GET_VOLUME pushes", types.sorted().joined(separator: ","))
            await link.stop()
            check(await link.state == .stopped, "link stops cleanly")
        }

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
