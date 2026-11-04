import SwiftUI
import UltraBarKit

/// VivoCube: what the cube shows now (device twin), the ordered card list,
/// how it switches, one Send button, maintenance tucked away.
struct VivoCubeView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    let module: AttachedModule
    @StateObject private var ui = UI()
    private final class UI: ObservableObject { @Published var confirmRestart = false; @Published var confirmLauncher = false }

    var body: some View {
        VStack(spacing: 0) {
            Header("VivoCube", "One card at a time, up to \(AppModel.maxVivoLayers).") {
                Button { model.sendToCube(settings: settings) } label: { Label("Send to cube", systemImage: "arrow.up.circle.fill").frame(minWidth: 120) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(settings.vivoCards.isEmpty || model.cubeProgress.isRunning || model.isWorking)
                    .help("Draw the cards, upload them as one package and show card 1 (⌘↩)")
            }
            DeviceStrip(kind: .cube)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ProgressRow(progress: model.cubeProgress, lastAt: model.lastCubeSentAt, idle: "Sent")
                    HStack(alignment: .top, spacing: 18) {
                        twin
                        cards
                    }
                    switching
                    Panel("Maintenance") { maintenance }
                }.padding(20)
            }
        }
        .onAppear { model.selectedModuleSerial = module.serial }
        .sheet(isPresented: $model.showingVivoWiFi) { VivoWiFiSheet(serial: module.serial).environmentObject(model) }
        .alert("Restart the cube?", isPresented: $ui.confirmRestart) {
            Button("Restart", role: .destructive) { model.restartCube(serial: module.serial) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The cube goes dark for about 20 seconds and comes back on its current card.") }
        .alert("Restart the bar's launcher?", isPresented: $ui.confirmLauncher) {
            Button("Restart", role: .destructive) { Task { await model.restartBarLauncher(reason: "requested under Maintenance") } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The bar's screen reloads for a few seconds; the cube and the other modules stay as they are. Fixes uploads that fail after about 100 sends (a leak in the bar's firmware). Needs Wi-Fi ADB.") }
    }

    // MARK: Twin — the card the device says it is on

    private var showingLayer: Int { model.vivoLayerShowing ?? (model.vivoLayerIndex + 1) }
    private var twin: some View {
        Panel("On the cube now") {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black)
                if let img = model.vivoLayerImages[showingLayer] {
                    Image(nsImage: img).resizable().interpolation(.high)
                        .frame(width: 200, height: 200).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .opacity(model.vivoScreenOn == false ? 0.25 : (model.cubePackageStale ? 0.3 : 1))
                } else {
                    Text(model.vivoLayerImages.isEmpty ? (settings.vivoCards.isEmpty ? "Add a card, then Send to cube." : "Press Send to cube.") : "Card \(showingLayer) is not in the last package.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                }
                if model.vivoScreenOn == false { Label("Screen off", systemImage: "moon.fill").foregroundStyle(.white) }
                else if model.cubePackageStale {
                    Text("Still the previous cards").font(.caption.bold()).foregroundStyle(.white)
                        .padding(6).background(.orange.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(width: 220, height: 220)
            .accessibilityLabel("Picture the cube is showing")
            HStack {
                Button { model.stepCube(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous card").help("Previous card")
                Spacer()
                VStack(spacing: 2) {
                    Text(model.vivoLayerNames.isEmpty ? "—" : (model.cubePackageStale ? "Expected: card " : "Card ") + "\(showingLayer) of \(model.vivoLayerNames.count)").font(.callout).monospacedDigit()
                    Text((showingLayer - 1 < model.vivoLayerNames.count && showingLayer >= 1) ? model.vivoLayerNames[showingLayer - 1] : " ").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.stepCube(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Next card").help("Next card")
            }.disabled(model.vivoLayerNames.count < 2)
            if model.cubeOffline {
                Label(model.cubePackageStale ? "Attached, but not on Wi-Fi — the cards you sent never arrived; the cube shows what it had before." : "Attached, but not on Wi-Fi — new cards cannot be downloaded.", systemImage: "wifi.slash").font(.caption).foregroundStyle(.orange)
            }
        }.frame(width: 250)
    }

    // MARK: Ordered card list

    private var cards: some View {
        Panel("Cards on the cube", footer: "Drag to reorder. \(settings.cubePackageCards.count) of \(AppModel.maxVivoLayers) slots used.") {
            if settings.vivoCards.isEmpty {
                Text("Nothing on the cube yet — add a card.").foregroundStyle(.secondary)
            }
            List {
                ForEach(Array(settings.vivoCards.enumerated()), id: \.element) { i, t in
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                        Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 14)
                        Label(t.title, systemImage: t.icon)
                        if t == .picture, settings.vivoPicturePath.isEmpty { Text("choose a file in Widgets").font(.caption2).foregroundStyle(.orange) }
                        if t == .crypto {
                            let coins = settings.cryptoCoinsConfigured
                            Text(coins.isEmpty ? "choose coins in Widgets" : "\(coins.map { CryptoStats.symbol(for: $0) }.joined(separator: ", ")) → \(coins.count) card\(coins.count == 1 ? "" : "s")")
                                .font(.caption2).foregroundStyle(coins.isEmpty ? .orange : .secondary)
                        }
                        Spacer()
                        if i + 1 == showingLayer, !model.vivoLayerNames.isEmpty, i < model.vivoLayerNames.count {
                            Tag("now", .green).help("The card the cube shows right now")
                        }
                        RemoveMark(title: t.title) { settings.removeVivoCard(t) }
                    }
                    .listRowSeparator(.visible).listRowSeparatorTint(Color.primary.opacity(0.12))
                    .accessibilityActions {
                        Button("Move up") { if i > 0 { settings.moveVivoCards(from: IndexSet(integer: i), to: i - 1) } }
                        Button("Move down") { if i < settings.vivoCards.count - 1 { settings.moveVivoCards(from: IndexSet(integer: i), to: i + 2) } }
                    }
                }
                .onMove { settings.moveVivoCards(from: $0, to: $1) }
            }
            .listStyle(.inset).scrollContentBackground(.hidden)
            .frame(height: CGFloat(max(1, settings.vivoCards.count)) * 28 + 10)
            Menu {
                ForEach(Theme.library.filter { !settings.vivoCards.contains($0) }) { t in
                    Button { add(t) } label: { Label(t.title, systemImage: t.icon) }
                }
            } label: { Label("Add a card…", systemImage: "plus") }
            .frame(width: 150).disabled(settings.vivoSlotsLeft == 0)
            .help(settings.vivoSlotsLeft == 0 ? "The cube holds \(AppModel.maxVivoLayers) cards" : "")
        }
    }

    private func add(_ t: Theme) {
        if t == .picture, settings.vivoPicturePath.isEmpty { WidgetsView.choosePicture(settings) }
        settings.addVivoCard(t)
        model.requestCardPermissions(t)
    }

    // MARK: Switch mode

    private var switching: some View {
        Panel("Switching", footer: settings.vivoSwitchMode == .timed ? "Timed switching runs on this Mac — Deckhand must be open." : nil) {
            // Plain radio group; the interval is a separate control (a picker inside a radio label is not supported on AppKit).
            Picker("", selection: $settings.vivoSwitchMode) {
                Text("Stay on one card").tag(AppSettings.SwitchMode.stay)
                Text("Switch automatically").tag(AppSettings.SwitchMode.timed)
                Text("Only with the DotKey or the bar's button").tag(AppSettings.SwitchMode.button)
            }
            .pickerStyle(.radioGroup).labelsHidden().accessibilityLabel("Switching")
            HStack(spacing: 8) {
                Text("Every").foregroundStyle(settings.vivoSwitchMode == .timed ? .primary : .secondary)
                Picker("", selection: Binding(get: { [15, 30, 60, 180].contains(settings.vivoSeconds) ? settings.vivoSeconds : 30 }, set: { settings.vivoSeconds = $0 })) {
                    Text("15 s").tag(15); Text("30 s").tag(30); Text("1 min").tag(60); Text("3 min").tag(180)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 260).disabled(settings.vivoSwitchMode != .timed).accessibilityLabel("Switch every")
            }.padding(.leading, 22)
            .onChange(of: settings.vivoSwitchMode) { mode in
                if mode != .timed, model.themeRunning { model.stopThemeRotation(settings: settings) }
                else if mode == .timed, !model.themeRunning, !model.vivoLayerNames.isEmpty { model.sendToCube(settings: settings) }
            }
            if model.themeRunning { Text("Switching every \(settings.vivoSeconds) s · now: \(model.currentThemeLabel)").font(.caption).foregroundStyle(.secondary) }
        }
    }

    // MARK: Maintenance

    private var maintenance: some View {
        Group {
            HStack {
                Text("Cube screen").frame(width: 100, alignment: .leading)
                Picker("", selection: Binding(get: { model.vivoScreenOn ?? true }, set: { model.setCubeScreen(on: $0, serial: module.serial) })) {
                    Text("On").tag(true); Text("Off").tag(false)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 120).accessibilityLabel("Cube screen")
                Text(model.vivoScreenOn == nil ? "Not read yet." : (model.vivoScreenOn == true ? "The screen is on." : "The screen is off and stays off until you switch it on here.")).font(.caption).foregroundStyle(.secondary)
            }
            // Two rows, so the four buttons fit at the minimum window width: everyday fixes first, restarts (confirmed) second.
            HStack(spacing: 10) {
                Button { model.recoverVivoDisplay(serial: module.serial) } label: { Label("Fix black screen", systemImage: "bandage") }
                    .help("Turns the screen on and points the cube at card 1.")
                Button { model.sendPanelSizeTest(serial: module.serial, size: 240) } label: { Label("Send test picture", systemImage: "checkerboard.rectangle") }
                    .help("Uploads a 240 × 240 test pattern — a quick way to see whether uploads reach the cube.")
            }
            HStack(spacing: 10) {
                Button(role: .destructive) { ui.confirmRestart = true } label: { Label("Restart cube…", systemImage: "arrow.counterclockwise") }
                    .help("The cube goes dark for about 20 seconds. Asks first.")
                Button(role: .destructive) { ui.confirmLauncher = true } label: { Label("Restart bar launcher…", systemImage: "arrow.counterclockwise.circle") }
                    .help("Over Wi-Fi ADB. The bar's firmware stops taking uploads after about 100 of them; Deckhand does this by itself when it can. Asks first.")
            }
            Divider()
            HStack(spacing: 10) {
                let w = model.vivoWiFi[module.serial] ?? nil
                Image(systemName: model.cubeOffline ? "wifi.exclamationmark" : "wifi").foregroundStyle(model.cubeOffline ? Color.orange : Color.green)
                Text(w.map { ($0.isCoreBarHotspot ? "On the CoreBar's own hotspot (\($0.ssid))" : "On Wi-Fi “\($0.ssid)”") + " · " + model.cubeWiFiLabel } ?? "Wi-Fi: not read yet")
                Button { model.refreshVivoWiFi(serial: module.serial) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).accessibilityLabel("Read Wi-Fi again").help("Read the cube's Wi-Fi state again")
                Spacer()
                Button { model.showingVivoWiFi = true } label: { Label("Set cube Wi-Fi…", systemImage: "wifi.router") }.disabled(model.isWorking)
            }
            Text("The cube fetches its cards over Wi-Fi (2.4 GHz). If it stays “still connecting”, send the same Wi-Fi settings once more — that completes the join.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct VivoWiFiSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let serial: String
    @StateObject private var draft = Draft()
    private final class Draft: ObservableObject { @Published var ssid = ""; @Published var password = ""; @Published var show = false }
    private var saved: [(ssid: String, password: String)] { model.selectedCoreBar.map { Store.shared.savedNetworks(serial: $0.serialNo) } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Join the cube to a Wi-Fi network").font(.title3).bold()
            Text("2.4 GHz networks only — the cube has no 5 GHz radio, and a combined 2.4/5 GHz name may not work. The bar must be on the same network. The password is sent to the cube and kept only in Deckhand's settings so the cube can be switched back later; it is redacted from Deckhand's log.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !saved.isEmpty {
                Text("Networks the cube has successfully joined — click to fill in (right-click to forget):").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(saved, id: \.ssid) { n in
                        Button {
                            draft.ssid = n.ssid; draft.password = n.password
                        } label: { Label(n.ssid.hasPrefix("AndroidAP") ? "CoreBar hotspot (\(n.ssid))" : n.ssid, systemImage: n.ssid.hasPrefix("AndroidAP") ? "dot.radiowaves.left.and.right" : "wifi") }
                        .controlSize(.small)
                        .contextMenu { Button("Forget this network") { if let b = model.selectedCoreBar { Store.shared.forgetNetwork(serial: b.serialNo, ssid: n.ssid) }; draft.objectWillChange.send() } }
                    }
                }
            } else {
                Text("The bar's own hotspot (name “AndroidAP_…” and password) is printed on the bar; Deckhand remembers every network once the cube has reported it.").font(.caption).foregroundStyle(.secondary)
            }
            Form {
                TextField("Wi-Fi name", text: $draft.ssid)
                if draft.show { TextField("Password", text: $draft.password) } else { SecureField("Password", text: $draft.password) }
                Toggle("Show password", isOn: $draft.show)
                if !draft.password.isEmpty { Text("\(draft.password.count) characters").font(.caption).foregroundStyle(.secondary) }
            }.formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Send to cube") { model.setVivoWiFi(serial: serial, ssid: draft.ssid, password: draft.password); dismiss() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(draft.ssid.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 460)
        .onAppear { if let w = model.vivoWiFi[serial] ?? nil { draft.ssid = w.ssid; draft.password = w.password } }
    }
}
