import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Apps → Zeekr: the sign-in (from FCC's Keychain items or pasted), the home location and the car pictures.
struct ZeekrSettings: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @State private var connecting = false
    @State private var confirmDisconnect = false
    @State private var homeNote: String?
    @State private var pictureNote: String?
    @State private var tick = 0

    private var feed: ZeekrFeed { model.barPages.zeekr }

    var body: some View {
        Panel("Zeekr account", footer: "Read-only: Deckhand asks Zeekr's EU gateway for the car's status, never sends a command. The sign-in is kept in a user-only file on this Mac and only sent to eu-snc-tsp-api-gw.zeekrlife.com; the bar gets what it shows, not the sign-in, the VIN or the car's coordinates.") {
            TimelineView(.periodic(from: .now, by: 3)) { _ in
                let creds = ZeekrFeed.loadCredentials()
                VStack(alignment: .leading, spacing: 6) {
                    if let c = creds {
                        HStack(spacing: 6) {
                            Image(systemName: feed.needsSignIn ? "exclamationmark.triangle.fill" : "checkmark.seal.fill").foregroundStyle(feed.needsSignIn ? .orange : .green)
                            Text(c.source == "fcc" ? "Signed in with FCC's sign-in" : "Signed in with pasted values")
                        }
                        if let exp = c.accessExpires {
                            Text("Access token valid until \(exp.formatted(date: .abbreviated, time: .shortened))" + (c.refreshToken == nil ? " · no refresh token, so it cannot be renewed here" : " · renewed automatically a day before"))
                                .font(.caption).foregroundStyle(exp < Date() ? .orange : .secondary)
                        }
                        if let e = feed.lastError { Text(e).font(.caption).foregroundStyle(.orange) }
                        else if let at = feed.fetchedAt { Text("Last asked \(at.formatted(date: .omitted, time: .shortened))" + (feed.status?.charging == true ? " · charging, every minute or two" : " · every 5 minutes while Zeekr is on the bar")).font(.caption).foregroundStyle(.secondary) }
                        else { Text("Asks while the Zeekr app is on the bar.").font(.caption).foregroundStyle(.secondary) }
                    } else {
                        Text("Not signed in.").foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button(ZeekrFeed.loadCredentials() == nil ? "Connect…" : "Connect again…") { connecting = true }
                if ZeekrFeed.loadCredentials() != nil {
                    Button("Disconnect", role: .destructive) { confirmDisconnect = true }
                }
            }
        }
        .sheet(isPresented: $connecting) { ZeekrConnectSheet { feed.poke() } }
        .confirmationDialog("Forget the Zeekr sign-in on this Mac?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) { ZeekrFeed.saveCredentials(nil) }
        } message: { Text("FCC and the Zeekr app are not affected.") }

        Panel("Home", footer: "Within 150 m of home the bar says Home; anywhere else it shows a short address from Apple's map service, asked again only when the car has moved. Kept in zeekr/settings.json on this Mac.") {
            let home = ZeekrFeed.loadSettings().home
            Text(home == nil ? "No home set." : String(format: "Home is set (%.4f, %.4f).", home![0], home![1])).foregroundStyle(.secondary)
            HStack {
                Button("Where the car is now") { homeNote = feed.setHomeToCar() ? nil : "The car's position is not known yet."; tick += 1 }
                Button("This Mac's location") {
                    Task { @MainActor in
                        if let l = try? await model.resolveLocation(settings: settings) { feed.setHome((l.lat, l.lon)); homeNote = "Set to \(l.name)." }
                        else { homeNote = "This Mac's location is not known." }
                        tick += 1
                    }
                }
                if home != nil { Button("Clear") { feed.setHome(nil); homeNote = nil; tick += 1 }.buttonStyle(.borderless) }
            }
            if let homeNote { Text(homeNote).font(.caption).foregroundStyle(.secondary) }
        }.id("home\(tick)")

        Panel("Car picture", footer: "Your own pictures of the car, one per state, kept in Deckhand's private zeekr folder and sent only to your bar; Deckhand and its bar app carry none. Without a picture the bar draws a plain car. Import from FCC copies FCC's pictures from its checkout (frontend/public/images/zeekr).") {
            HStack(alignment: .top, spacing: 14) {
                ForEach(ZeekrFeed.pictures, id: \.variant) { p in
                    VStack(spacing: 6) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.11, green: 0.125, blue: 0.16))
                            if let url = ZeekrFeed.pictureURL(p.variant), let img = NSImage(contentsOf: url), ZeekrFeed.hasPicture(p.variant) {
                                Image(nsImage: img).resizable().scaledToFit().padding(6)
                            } else { Image(systemName: "car.side").font(.title).foregroundStyle(.secondary) }
                        }.frame(width: 150, height: 84)
                        Text(p.label).font(.caption)
                        HStack(spacing: 8) {
                            Button("Choose…") { choose(p.variant) }.buttonStyle(.borderless).font(.caption)
                            if ZeekrFeed.hasPicture(p.variant) { Button("Remove") { ZeekrFeed.removePicture(p.variant); tick += 1 }.buttonStyle(.borderless).font(.caption) }
                        }
                    }
                }
            }
            HStack {
                Button { importFCC() } label: { Label("Import from FCC…", systemImage: "square.and.arrow.down") }
                Button { NSWorkspace.shared.activateFileViewerSelecting([ZeekrFeed.ensureFolder()]) } label: { Label("Show folder", systemImage: "folder") }.buttonStyle(.borderless)
                if let pictureNote { Text(pictureNote).font(.caption).foregroundStyle(.secondary) }
            }
        }.id("pic\(tick)")
    }

    private func choose(_ variant: String) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]; p.allowsMultipleSelection = false; p.prompt = "Use picture"
        p.message = "A picture of the car, ideally a PNG with a transparent background, about twice as wide as high."
        guard p.runModal() == .OK, let url = p.url else { return }
        pictureNote = ZeekrFeed.choosePicture(variant, from: url) ? nil : "That file is not a picture macOS can read."
        tick += 1
    }

    private func importFCC() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.prompt = "Import"
        p.message = "Choose your FCC checkout (or its frontend/public/images/zeekr folder)."
        if FileManager.default.fileExists(atPath: ZeekrFeed.fccDefault.path) { p.directoryURL = ZeekrFeed.fccDefault }
        guard p.runModal() == .OK, let url = p.url else { return }
        let n = ZeekrFeed.importPictures(fromFCC: url)
        pictureNote = n == 0 ? "No FCC car pictures in that folder." : "\(n) picture\(n == 1 ? "" : "s") imported."
        tick += 1
    }
}

/// Connect: take FCC's sign-in from the Keychain (macOS asks the owner), or paste the values from a capture of the
/// Zeekr phone app, the same three fields FCC's Settings asks for plus the refresh token.
private struct ZeekrConnectSheet: View {
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var access = ""
    @State private var refresh = ""
    @State private var vin = ""
    @State private var device = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect your Zeekr").font(.title3.bold())
            Text("Zeekr has no sign-in that other apps can use: the phone app encrypts the password and the car's VIN with keys of its own. Deckhand therefore uses the same values as Fast Charge Companion (FCC).")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Use FCC's sign-in").font(.headline)
                    Text("Copies FCC's access token, refresh token, encrypted VIN and device ID from the Keychain. macOS asks once per item whether Deckhand may read it: choose Allow. Deckhand keeps its own copy and does not change FCC's.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Use FCC's sign-in") {
                        do { ZeekrFeed.saveCredentials(try ZeekrCredentials.importFromFCC()); onSaved(); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Or paste them").font(.headline)
                    Text("From a capture of the Zeekr phone app (for example with Proxyman), any request to eu-snc-tsp-api-gw.zeekrlife.com: the Authorization, X-VIN and X-DEVICE-ID headers; the refresh token from the login or refresh answer, if you have it.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    SecureField("Authorization (Bearer eyJ…)", text: $access)
                    SecureField("Refresh token (optional)", text: $refresh)
                    SecureField("X-VIN", text: $vin)
                    TextField("X-DEVICE-ID", text: $device)
                    Button("Save") {
                        let c = ZeekrCredentials(accessToken: ZeekrCredentials.clean(access), refreshToken: refresh.isEmpty ? nil : ZeekrCredentials.clean(refresh),
                                                 encryptedVin: ZeekrCredentials.clean(vin), deviceId: ZeekrCredentials.clean(device), source: "pasted")
                        guard c.complete else { error = "Authorization, X-VIN and X-DEVICE-ID are all needed."; return }
                        ZeekrFeed.saveCredentials(c); onSaved(); dismiss()
                    }.disabled(access.isEmpty || vin.isEmpty || device.isEmpty)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(20).frame(width: 520)
        .onAppear {
            // The encrypted VIN and device ID belong to the phone's device binding and outlive the tokens, so when
            // only the sign-in has expired a new Authorization (and refresh token) is all that needs pasting.
            if let c = ZeekrFeed.loadCredentials() { vin = c.encryptedVin; device = c.deviceId }
        }
    }
}
