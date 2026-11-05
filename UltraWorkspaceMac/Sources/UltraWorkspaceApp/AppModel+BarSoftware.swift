import Foundation
import UltraBarKit

/// What Deckhand knows about the bar's own software: the launcher (`com.ultrabar.launch`) and the bridge service
/// (`com.ultrabar.hub`) as installed on the bar, and the vendor's latest release on GitHub.
struct BarSoftwareStatus: Sendable {
    var launcher: (name: String, code: Int)?
    var bridge: (name: String, code: Int)?
    var release: VendorRelease.Release?
    var checkedAt: Date?
    /// Why the check or the update stopped; shown under the rows.
    var message: String?

    func newer(_ asset: VendorRelease.Asset?, than installed: (name: String, code: Int)?) -> Bool {
        guard let asset, let installed else { return false }
        return asset.versionCode > installed.code
    }
    var launcherUpdate: VendorRelease.Asset? { newer(release?.launcher, than: launcher) ? release?.launcher : nil }
    var bridgeUpdate: VendorRelease.Asset? { newer(release?.bridge, than: bridge) ? release?.bridge : nil }
    var updates: [VendorRelease.Asset] { [bridgeUpdate, launcherUpdate].compactMap { $0 } }   // bridge first, launcher last (it restarts)
}

extension AppModel {
    /// Where the vendor's files are kept between a check and the install (and reused when the size matches).
    static let vendorCacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let d = base.appendingPathComponent("Deckhand/vendor", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private func adbForBar() -> AdbBridge? {
        guard let adb = AdbBridge.find(), let ip = ipForSelected() else { return nil }
        return AdbBridge(path: adb, ip: ip)
    }

    /// Read the two versions off the bar over ADB and the latest release from GitHub.
    func checkBarSoftware() {
        guard barSoftwareBusy == nil else { return }
        barSoftwareBusy = "Checking…"
        Task {
            defer { barSoftwareBusy = nil }
            var st = BarSoftwareStatus(checkedAt: Date())
            if let b = adbForBar(), await b.connect(), !(await b.state()).contains("unauthorized") {
                st.launcher = await b.packageVersion(VendorRelease.launcherPackage)
                st.bridge = await b.packageVersion(VendorRelease.bridgePackage)
            } else {
                st.message = "The bar's versions need the debug bridge: finish the three steps above first."
            }
            do { st.release = try await VendorRelease.fetchLatest() }
            catch { st.message = (st.message.map { $0 + " " } ?? "") + "Could not read the vendor's releases on GitHub: \(FriendlyError.text(error))" }
            barSoftware = st
        }
    }

    /// Download the newer APKs, check each one's manifest, install the bridge then the launcher, re-check.
    /// The launcher restarts when it is replaced: the bar's screen goes blank for a few seconds and the link reconnects.
    func updateBarSoftware() {
        guard barSoftwareBusy == nil, let b = adbForBar() else { return }
        let assets = barSoftware.updates
        guard !assets.isEmpty else { return }
        barSoftwareBusy = "Starting…"
        Task {
            defer { barSoftwareBusy = nil }
            var st = barSoftware; st.message = nil
            var done: [String] = []
            do {
                for asset in assets {
                    let file = try await download(asset)
                    let info = try ApkInfo.read(apk: file)
                    let expected = asset == st.release?.launcher ? VendorRelease.launcherPackage : VendorRelease.bridgePackage
                    guard info.package == expected else {
                        throw UltraBarError.protocolError("\(asset.name) is not \(expected) but \(info.package); not installed.")
                    }
                    let installed = info.package == VendorRelease.launcherPackage ? st.launcher : st.bridge
                    guard info.versionCode > (installed?.code ?? 0) else {
                        throw UltraBarError.protocolError("\(asset.name) is version \(info.versionName) (\(info.versionCode)), not newer than what the bar has; not installed.")
                    }
                    barSoftwareBusy = "Installing \(asset.name) on the bar… (\(info.package == VendorRelease.launcherPackage ? "the launcher restarts" : "a minute or two"))"
                    say("Bar: installing \(asset.name)…")
                    let out = await b.install(apkPath: file.path, timeout: 600)
                    guard out.contains("Success") else {
                        throw UltraBarError.protocolError("adb install of \(asset.name) failed: \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
                    }
                    done.append("\(info.package == VendorRelease.launcherPackage ? "launcher" : "bridge") \(info.versionName)")
                }
                say("Bar: \(done.joined(separator: " and ")) installed.")
            } catch {
                st.message = FriendlyError.text(error)
                say("Bar software update stopped: \(st.message!)")
            }
            // Re-read what the bar has now (the launcher may still be coming back; wait a little for it).
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            barSoftwareBusy = "Checking…"
            if await b.connect() {
                st.launcher = await b.packageVersion(VendorRelease.launcherPackage)
                st.bridge = await b.packageVersion(VendorRelease.bridgePackage)
            }
            st.checkedAt = Date()
            barSoftware = st
        }
    }

    /// Fetch one release asset into the vendor cache; a file already there with the published size is reused.
    private func download(_ asset: VendorRelease.Asset) async throws -> URL {
        let dest = Self.vendorCacheDir.appendingPathComponent(asset.name)
        if let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int), size == asset.size, size > 0 { return dest }
        barSoftwareBusy = "Downloading \(asset.name) (\(asset.size / 1_000_000) MB)…"
        var req = URLRequest(url: asset.url); req.timeoutInterval = 300
        req.setValue("Deckhand (+https://denoronha.github.io/UltraWorkspaceMac/)", forHTTPHeaderField: "User-Agent")
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        guard let h = resp as? HTTPURLResponse, h.statusCode == 200 else {
            throw UltraBarError.protocolError("GitHub answered \((resp as? HTTPURLResponse)?.statusCode ?? 0) for \(asset.name)")
        }
        let got = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int) ?? 0
        guard asset.size == 0 || got == asset.size else { throw UltraBarError.protocolError("\(asset.name): got \(got) bytes, the release lists \(asset.size)") }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }
}
