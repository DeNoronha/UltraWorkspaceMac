import SwiftUI
import UltraBarKit

/// VivoCube: what the cube shows now (device twin), the ordered card list,
/// how it switches, one Send button, maintenance tucked away.
struct VivoCubeView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    let module: AttachedModule
    @StateObject private var ui = UI()
    private final class UI: ObservableObject { @Published var confirmRestart = false; @Published var maintenance = false }

    var body: some View {
        VStack(spacing: 0) {
            Header("VivoCube", "Shows one card at a time.") { wifiPill }
            DeviceStrip(kind: .cube)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 18) {
                        twin
                        cards
                    }
                    switching
                    HStack(alignment: .top, spacing: 14) {
                        Button { model.sendToCube(settings: settings) } label: { Label("Send to cube", systemImage: "arrow.up.circle.fill").frame(minWidth: 120) }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(settings.vivoCards.isEmpty || model.cubeProgress.isRunning || model.isWorking)
                            .help("Draw the cards, upload them as one package and show card 1 (⌘↩)")
                        ProgressRow(progress: model.cubeProgress, lastAt: model.lastCubeSentAt, idle: "Sent").padding(.top, 6)
                    }
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
                Button { model.stepCube(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous card")
                Spacer()
                VStack(spacing: 2) {
                    Text(model.vivoLayerNames.isEmpty ? "—" : (model.cubePackageStale ? "Expected: card " : "Card ") + "\(showingLayer) of \(model.vivoLayerNames.count)").font(.callout).monospacedDigit()
                    Text((showingLayer - 1 < model.vivoLayerNames.count && showingLayer >= 1) ? model.vivoLayerNames[showingLayer - 1] : " ").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.stepCube(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Next card")
            }.disabled(model.vivoLayerNames.count < 2)
            if let st = model.vivoWiFiState, st != 3 {
                Label(model.cubePackageStale ? "Not on Wi-Fi — the cards you sent never arrived; the cube shows what it had before." : "Not on Wi-Fi — new cards cannot reach it.", systemImage: "wifi.slash").font(.caption).foregroundStyle(.orange)
            }
        }.frame(width: 250)
    }

    // MARK: Ordered card list

    private var cards: some View {
        Panel("What the cube shows", footer: "Drag to change the order. \(settings.vivoCards.count) of \(AppModel.maxVivoLayers) slots used.") {
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
                        Spacer()
                        if i + 1 == showingLayer, !model.vivoLayerNames.isEmpty, i < model.vivoLayerNames.count {
                            Text("now").font(.caption2).padding(.horizontal, 6).padding(.vertical, 1).background(Color.green.opacity(0.2)).clipShape(Capsule())
                        }
                        Button { settings.removeVivoCard(t) } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless).accessibilityLabel("Remove \(t.title)")
                    }
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
                ForEach(Theme.allCases.filter { !settings.vivoCards.contains($0) }) { t in
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
        Panel("Switch card", footer: settings.vivoSwitchMode == .timed ? "Timed switching runs on this Mac — Deckhand must be open." : nil) {
            // Plain radio group; the interval is a separate control (a picker inside a radio label is not supported on AppKit).
            Picker("", selection: $settings.vivoSwitchMode) {
                Text("Stay on one card").tag(AppSettings.SwitchMode.stay)
                Text("Switch automatically").tag(AppSettings.SwitchMode.timed)
                Text("Only with the DotKey or the bar's button").tag(AppSettings.SwitchMode.button)
            }
            .pickerStyle(.radioGroup).labelsHidden()
            HStack(spacing: 8) {
                Text("Every").foregroundStyle(settings.vivoSwitchMode == .timed ? .primary : .secondary)
                Picker("", selection: Binding(get: { [15, 30, 60, 180].contains(settings.vivoSeconds) ? settings.vivoSeconds : 30 }, set: { settings.vivoSeconds = $0 })) {
                    Text("15 s").tag(15); Text("30 s").tag(30); Text("1 min").tag(60); Text("3 min").tag(180)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 260).disabled(settings.vivoSwitchMode != .timed)
            }.padding(.leading, 22)
            .onChange(of: settings.vivoSwitchMode) { mode in
                if mode != .timed, model.themeRunning { model.stopThemeRotation(settings: settings) }
                else if mode == .timed, !model.themeRunning, !model.vivoLayerNames.isEmpty { model.sendToCube(settings: settings) }
            }
            if model.themeRunning { Text("Switching every \(settings.vivoSeconds) s · now: \(model.currentThemeLabel)").font(.caption).foregroundStyle(.secondary) }
        }
    }

    // MARK: Maintenance

    private var wifiPill: some View {
        let w = model.vivoWiFi[module.serial] ?? nil
        let ok = model.vivoWiFiState == 3
        return Label(w.map { $0.isCoreBarHotspot ? "CoreBar hotspot" : $0.ssid } ?? "Wi-Fi", systemImage: ok ? "wifi" : "wifi.exclamationmark")
            .font(.caption).foregroundStyle(ok ? Color.secondary : Color.orange)
            .help(ok ? "The cube is connected and can receive cards." : "The cube is not connected — see Maintenance → Wi-Fi.")
    }

    private var maintenance: some View {
        Group {
            HStack {
                Toggle("Screen", isOn: Binding(get: { model.vivoScreenOn ?? true }, set: { model.setCubeScreen(on: $0, serial: module.serial) }))
                    .toggleStyle(.switch)
                Text("Off stays off until you turn it on again.").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button { model.recoverVivoDisplay(serial: module.serial) } label: { Label("Fix black screen", systemImage: "bandage") }
                    .help("Turns the screen on and points the cube at card 1.")
                Button(role: .destructive) { ui.confirmRestart = true } label: { Label("Restart cube", systemImage: "arrow.counterclockwise") }
                Button { model.sendPanelSizeTest(serial: module.serial, size: 240) } label: { Label("Send test picture", systemImage: "checkerboard.rectangle") }
                    .help("Uploads a 240×240 test pattern — a quick way to see whether uploads reach the cube.")
            }
            Divider()
            HStack(spacing: 10) {
                let w = model.vivoWiFi[module.serial] ?? nil
                Image(systemName: model.vivoWiFiState == 3 ? "wifi" : "wifi.exclamationmark").foregroundStyle(model.vivoWiFiState == 3 ? Color.green : Color.orange)
                Text(w.map { ($0.isCoreBarHotspot ? "On the CoreBar's own hotspot (\($0.ssid))" : "On Wi-Fi “\($0.ssid)”") + (model.vivoWiFiState == 3 ? " · connected" : " · not connected") } ?? "Wi-Fi: not read yet")
                Button { model.refreshVivoWiFi(serial: module.serial) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).accessibilityLabel("Read Wi-Fi again")
                Spacer()
                Button { model.showingVivoWiFi = true } label: { Label("Set cube Wi-Fi…", systemImage: "wifi.router") }.disabled(model.isWorking)
            }
            Text("The cube fetches its cards over Wi-Fi. The CoreBar's hotspot falls asleep; a 2.4 GHz network of your own is more reliable.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct VivoWiFiSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let serial: String
    @StateObject private var draft = Draft()
    private final class Draft: ObservableObject { @Published var ssid = ""; @Published var password = "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Join the cube to a Wi-Fi network").font(.title3).bold()
            Text("2.4 GHz networks only — the cube has no 5 GHz radio, and a combined 2.4/5 GHz name may not work. The bar must be on the same network. The password is sent to the cube and kept only in Deckhand's settings so the cube can be switched back later; it is redacted from Deckhand's log.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Wi-Fi name", text: $draft.ssid)
                SecureField("Password", text: $draft.password)
            }.formStyle(.grouped)
            HStack {
                if let h = model.knownHotspot {
                    Button("Back to the CoreBar hotspot (\(h.ssid))") { draft.ssid = h.ssid; draft.password = h.password }.buttonStyle(.link).font(.caption)
                } else {
                    Text("The bar's own hotspot (name “AndroidAP_…” and password) is printed on the bar; Deckhand remembers it once the cube has reported it.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Send to cube") { model.setVivoWiFi(serial: serial, ssid: draft.ssid, password: draft.password); dismiss() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(draft.ssid.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 460)
        .onAppear { if let w = model.vivoWiFi[serial] ?? nil, !w.isCoreBarHotspot { draft.ssid = w.ssid } }
    }
}
