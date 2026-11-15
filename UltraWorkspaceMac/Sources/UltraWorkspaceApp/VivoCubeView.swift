import SwiftUI
import UltraBarKit

/// VivoCube: what the cube shows now (device twin), the ordered card list, how it switches, Send to Cube in the
/// toolbar, maintenance at the end. This is the one place where the cube's cards are chosen and ordered.
struct VivoCubeView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @Environment(\.undoManager) private var undo
    let module: AttachedModule
    @StateObject private var ui = UI()
    private final class UI: ObservableObject { @Published var confirmRestart = false }

    var body: some View {
        Form {
            DeviceStatusSection(kind: .cube) {
                ProgressRow(progress: model.cubeProgress, lastAt: model.lastCubeSentAt, idle: "Sent")
            }
            twin
            cards
            switching
            maintenance
        }
        .formStyle(.grouped)
        .navigationSubtitle("Up to \(AppModel.maxVivoLayers) cards, one at a time")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.sendToCube(settings: settings) } label: { Label("Send to Cube", systemImage: "arrow.up.circle") }
                    .labelStyle(.titleAndIcon)
                    .prominentAction()
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(settings.vivoCards.isEmpty || model.cubeProgress.isRunning || model.isWorking)
                    .help("Draw the cards, upload them as one package and show card 1 (⌘↩)")
            }
        }
        .onAppear { model.selectedModuleSerial = module.serial }
        .sheet(isPresented: $model.showingVivoWiFi) { VivoWiFiSheet(serial: module.serial).environmentObject(model) }
        .alert("Restart the cube?", isPresented: $ui.confirmRestart) {
            Button("Restart", role: .destructive) { model.restartCube(serial: module.serial) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The cube goes dark for about 20 seconds and comes back on its current card.") }
    }

    // MARK: Twin — the card the device says it is on

    private var showingLayer: Int { model.vivoLayerShowing ?? (model.vivoLayerIndex + 1) }
    private var twin: some View {
        Section("On the cube now") {
            HStack(alignment: .center, spacing: 20) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black)
                    if let img = model.vivoLayerImages[showingLayer] {
                        Image(nsImage: img).resizable().interpolation(.high)
                            .frame(width: 150, height: 150).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .opacity(model.vivoScreenOn == false ? 0.25 : (model.cubePackageStale ? 0.3 : 1))
                    } else {
                        Text(model.vivoLayerImages.isEmpty ? (settings.vivoCards.isEmpty ? "Add a card, then Send to Cube." : "Press Send to Cube.") : "Card \(showingLayer) is not in the last package.")
                            .font(.callout).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center).padding()
                    }
                    if model.vivoScreenOn == false { Label("Screen off", systemImage: "moon").foregroundStyle(.white) }
                    else if model.cubePackageStale {
                        Text("Still the previous cards").font(.callout.bold()).foregroundStyle(.white)
                            .padding(6).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .frame(width: 166, height: 166)
                .accessibilityLabel("Picture the cube is showing")
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.vivoLayerNames.isEmpty ? "Nothing sent yet" : (model.cubePackageStale ? "Expected: card " : "Card ") + "\(showingLayer) of \(model.vivoLayerNames.count)")
                        .font(.title3).monospacedDigit()
                    Text((showingLayer - 1 < model.vivoLayerNames.count && showingLayer >= 1) ? model.vivoLayerNames[showingLayer - 1] : " ").foregroundStyle(.secondary)
                    HStack {
                        Button { model.stepCube(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous card").help("Previous card")
                        Button { model.stepCube(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Next card").help("Next card")
                    }.disabled(model.vivoLayerNames.count < 2)
                    if model.cubeOffline {
                        StatusLabel(model.cubePackageStale ? "Not on Wi\u{2011}Fi: the cards you sent never arrived." : "Not on Wi\u{2011}Fi: new cards cannot reach the cube.", .attention)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Ordered card list

    private var cards: some View {
        Section {
            if settings.vivoCards.isEmpty { Text("No cards yet. Add one below.").foregroundStyle(.secondary) }
            ReorderableRows(items: settings.vivoCards, id: \.self, move: { settings.moveVivoCards(from: $0, to: $1) }) { i, t in
                HStack(spacing: 8) {
                    Text("\(i + 1)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 16)
                    Label(t.title, systemImage: t.icon)
                    if t == .picture, settings.vivoPicturePath.isEmpty { Tag("Choose a picture", .attention) }
                    if t == .crypto {
                        let coins = settings.cryptoCoinsConfigured
                        if coins.isEmpty { Tag("Choose coins", .attention) }
                        else { Text("\(coins.map { CryptoStats.symbol(for: $0) }.joined(separator: ", ")) · \(coins.count) card\(coins.count == 1 ? "" : "s")").font(.callout).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if i + 1 == showingLayer, !model.vivoLayerNames.isEmpty, i < model.vivoLayerNames.count {
                        Tag("Showing", .info).help("The card the cube shows right now")
                    }
                    Button("Settings") { model.selectedAddon = t; model.nav = .cubeCards }
                        .buttonStyle(.borderless).help("Open \(t.title) in Cube Cards")
                    RemoveMark(title: t.title) { remove(t) }
                }
            } menu: { _, t in
                Divider()
                Button("Remove") { remove(t) }
            }
            Menu {
                ForEach(Theme.library.filter { !settings.vivoCards.contains($0) }) { t in
                    Button { add(t) } label: { Label(t.title, systemImage: t.icon) }
                }
            } label: { Label("Add a Card", systemImage: "plus") }
            .fixedSize()
            .disabled(settings.vivoSlotsLeft == 0)
            .help(settings.vivoSlotsLeft == 0 ? "The cube holds \(AppModel.maxVivoLayers) cards" : "")
        } header: {
            Text("Cards on the cube")
        } footer: {
            Footnote("\(settings.cubePackageCards.count) of \(AppModel.maxVivoLayers) slots used. Drag to reorder.")
        }
    }

    private func add(_ t: Theme) {
        if t == .picture, settings.vivoPicturePath.isEmpty { CubeCardsView.choosePicture(settings) }
        settings.addVivoCard(t)
        model.requestCardPermissions(t)
    }

    private func remove(_ t: Theme) {
        let before = settings.vivoThemes
        settings.removeVivoCard(t)
        registerUndo(undo, settings, \.vivoThemes, old: before, name: "Remove \(t.title)")
    }

    // MARK: Switch mode

    private var switching: some View {
        Section {
            Picker("Mode", selection: $settings.vivoSwitchMode) {
                Text("Stay on one card").tag(AppSettings.SwitchMode.stay)
                Text("Switch automatically").tag(AppSettings.SwitchMode.timed)
                Text("Only with the DotKey or the bar's button").tag(AppSettings.SwitchMode.button)
            }
            .pickerStyle(.radioGroup)
            Picker("Every", selection: Binding(get: { [15, 30, 60, 180].contains(settings.vivoSeconds) ? settings.vivoSeconds : 30 }, set: { settings.vivoSeconds = $0 })) {
                Text("15 s").tag(15); Text("30 s").tag(30); Text("1 min").tag(60); Text("3 min").tag(180)
            }
            .pickerStyle(.segmented)
            .disabled(settings.vivoSwitchMode != .timed)
            .onChange(of: settings.vivoSwitchMode) { mode in
                if mode != .timed, model.themeRunning { model.stopThemeRotation(settings: settings) }
                else if mode == .timed, !model.themeRunning, !model.vivoLayerNames.isEmpty { model.sendToCube(settings: settings) }
            }
            if model.themeRunning { StatusLabel("Switching every \(settings.vivoSeconds) s · now: \(model.currentThemeLabel)", .info) }
        } header: {
            Text("Switching")
        } footer: {
            if settings.vivoSwitchMode == .timed { Footnote("Timed switching runs on this Mac, so Deckhand must be running.") }
        }
    }

    // MARK: Maintenance

    private var maintenance: some View {
        Section {
            Picker("Cube screen", selection: Binding(get: { model.vivoScreenOn ?? true }, set: { model.setCubeScreen(on: $0, serial: module.serial) })) {
                Text("On").tag(true); Text("Off").tag(false)
            }
            .pickerStyle(.segmented)
            .help(model.vivoScreenOn == false ? "The screen stays off until you switch it on here." : "")
            LabeledContent("Wi\u{2011}Fi") {
                let w = model.vivoWiFi[module.serial] ?? nil
                Text(w.map { ($0.isCoreBarHotspot ? "CoreBar hotspot" : $0.ssid) + " · " + model.cubeWiFiLabel } ?? "Not read yet")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Refresh") { model.refreshVivoWiFi(serial: module.serial); Task { await model.refreshDeviceState() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Ask the cube again what it shows and which Wi\u{2011}Fi it is on (⌘R)")
                Button("Set Cube Wi\u{2011}Fi…") { model.showingVivoWiFi = true }.disabled(model.isWorking)
                Button("Fix Black Screen") { model.recoverVivoDisplay(serial: module.serial) }
                    .help("Turns the screen on and points the cube at card 1.")
                Button("Send Test Picture") { model.sendPanelSizeTest(serial: module.serial, size: 240) }
                    .help("Uploads a test pattern: a quick way to see whether uploads reach the cube.")
                Button("Restart Cube…") { ui.confirmRestart = true }
            }
            if model.cubeOffline {
                StatusLabel("The cube fetches its cards over 2.4 GHz Wi\u{2011}Fi. If it stays “still connecting”, send the same Wi\u{2011}Fi once more.", .info)
            }
        } header: {
            Text("Maintenance")
        } footer: {
            HStack(spacing: 4) {
                Text("Uploads still failing?")
                Button("Restart the bar launcher in Bar System") { model.nav = .barSystem }.buttonStyle(.link)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct VivoWiFiSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let serial: String
    @StateObject private var draft = Draft()
    private final class Draft: ObservableObject { @Published var ssid = ""; @Published var password = ""; @Published var show = false; @Published var forget: String? }
    private var saved: [(ssid: String, password: String)] { model.selectedCoreBar.map { Store.shared.savedNetworks(serial: $0.serialNo) } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Network name", text: $draft.ssid)
                    if draft.show { TextField("Password", text: $draft.password) } else { SecureField("Password", text: $draft.password) }
                    Toggle("Show password", isOn: $draft.show)
                } header: {
                    Text("Join the cube to a Wi\u{2011}Fi network")
                } footer: {
                    Footnote("2.4 GHz only, on the same network as the bar. The password goes to the cube and stays in this Mac's Keychain.")
                }
                if !saved.isEmpty {
                    Section {
                        ForEach(saved, id: \.ssid) { n in
                            LabeledContent {
                                HStack {
                                    Button("Use") { draft.ssid = n.ssid; draft.password = n.password }
                                    RemoveMark(title: n.ssid) { draft.forget = n.ssid }
                                }
                            } label: {
                                Label(n.ssid.hasPrefix("AndroidAP") ? "CoreBar hotspot (\(n.ssid))" : n.ssid,
                                      systemImage: n.ssid.hasPrefix("AndroidAP") ? "dot.radiowaves.left.and.right" : "wifi")
                            }
                        }
                    } header: {
                        Text("Networks the cube has joined")
                    } footer: {
                        Footnote("The bar's own hotspot name and password are printed on the bar.")
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Send to Cube") { model.setVivoWiFi(serial: serial, ssid: draft.ssid, password: draft.password); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.ssid.trimmingCharacters(in: .whitespaces).isEmpty)
            }.padding(16)
        }
        .frame(width: 480, height: 440)
        .confirmationDialog("Forget “\(draft.forget ?? "")”?", isPresented: Binding(get: { draft.forget != nil }, set: { if !$0 { draft.forget = nil } }), titleVisibility: .visible) {
            Button("Forget", role: .destructive) {
                if let b = model.selectedCoreBar, let ssid = draft.forget { Store.shared.forgetNetwork(serial: b.serialNo, ssid: ssid) }
                draft.forget = nil
            }
            Button("Cancel", role: .cancel) { draft.forget = nil }
        } message: { Text("Deckhand forgets this network and its password. The cube stays on the network it is on.") }
        .onAppear { if let w = model.vivoWiFi[serial] ?? nil { draft.ssid = w.ssid; draft.password = w.password } }
    }
}
