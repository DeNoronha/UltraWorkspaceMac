import SwiftUI
import UltraBarKit

/// Library of cards Deckhand can draw: preview, settings, and "Add to the cube".
struct WidgetsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @StateObject private var pm = PreviewModel()

    var body: some View {
        VStack(spacing: 0) {
            Header("Widgets", "Cards Deckhand draws for the cube.")
            Divider()
            HSplitView {
                List(selection: Binding(get: { model.selectedAddon as Theme? }, set: { if let v = $0 { model.selectedAddon = v } })) {
                    ForEach(Theme.allCases) { t in
                        HStack {
                            Label(t.title, systemImage: t.icon)
                            Spacer()
                            if settings.vivoCards.contains(t) { Image(systemName: "circle.circle").font(.caption).foregroundStyle(.secondary).help("In the cube's card list") }
                        }.tag(t)
                    }
                }
                .frame(minWidth: 200, maxWidth: 260)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 20) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black)
                                if let img = pm.image {
                                    Image(nsImage: img).resizable().interpolation(.high).frame(width: 200, height: 200).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                } else if pm.loading { ProgressView() } else { Text("—").foregroundStyle(.secondary) }
                            }
                            .frame(width: 220, height: 220)
                            .accessibilityLabel("Preview of \(model.selectedAddon.title)")
                            VStack(alignment: .leading, spacing: 10) {
                                Label(model.selectedAddon.title, systemImage: model.selectedAddon.icon).font(.title3).bold()
                                Text(blurb(model.selectedAddon)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                HStack {
                                    if settings.vivoCards.contains(model.selectedAddon) {
                                        if model.lastCubeSentAt != nil, !model.cubeOffline, CoreBarSession.UploadDiag.shared.last.hasPrefix("accepted") {
                                            Label("On the cube", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                                        } else {
                                            Label(model.lastCubeSentAt == nil ? "In the cube's list — not sent yet" : "In the cube's list — the last send did not arrive", systemImage: "circle.circle").foregroundStyle(.orange)
                                        }
                                        Button("Remove") { settings.removeVivoCard(model.selectedAddon) }
                                    } else {
                                        Button { if model.selectedAddon == .picture, settings.vivoPicturePath.isEmpty { Self.choosePicture(settings) }; settings.addVivoCard(model.selectedAddon); model.requestCardPermissions(model.selectedAddon) } label: { Label("Add to the cube", systemImage: "plus") }
                                            .buttonStyle(.borderedProminent).disabled(settings.vivoSlotsLeft == 0)
                                        if settings.vivoSlotsLeft == 0 { Text("The cube is full (\(AppModel.maxVivoLayers) cards).").font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Button { reload() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).accessibilityLabel("Redraw preview")
                                }
                            }
                        }
                        Divider()
                        addonSettings(model.selectedAddon)
                        Spacer()
                    }.padding(20).frame(minWidth: 360, alignment: .leading)
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: model.selectedAddon) { _ in reload() }
        .onChange(of: settings.vivoPicturePath) { _ in reload() }
    }
    private func reload() { pm.reload { await model.previewImage(model.selectedAddon, settings: settings) } }

    static func choosePicture(_ settings: AppSettings) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .image]
        panel.allowsMultipleSelection = false
        panel.message = "Pick a picture for the cube (it is scaled to 240 × 240)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Copy next to our settings so the card keeps working if the original moves.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("UltraWorkspaceMac", isDirectory: true)
        let dest = base.appendingPathComponent("picture." + (url.pathExtension.isEmpty ? "png" : url.pathExtension))
        try? FileManager.default.removeItem(at: dest)
        if (try? FileManager.default.copyItem(at: url, to: dest)) != nil { settings.vivoPicturePath = dest.path } else { settings.vivoPicturePath = url.path }
    }

    private func blurb(_ t: Theme) -> String {
        switch t {
        case .weather: return "Live weather and clock via Open-Meteo — free, no key."
        case .music: return "What Music is playing, with album art."
        case .cpu: return "CPU and memory use of this Mac."
        case .network: return "Download and upload speed of this Mac."
        case .claude: return "Claude Code activity: tokens used today and active sessions."
        case .battery: return "Battery charge and power state (a desktop Mac shows “On AC power”)."
        case .disk: return "How full the startup disk is."
        case .worldclock: return "The time in Amsterdam, New York and Tokyo."
        case .crypto: return "Bitcoin and Ethereum in EUR with 24-hour change (CoinGecko, no key)."
        case .calendar: return "Your next calendar events. macOS asks for Calendar access the first time."
        case .diskio: return "Live disk read/write throughput."
        case .topcpu: return "The apps using the most CPU right now."
        case .uptime: return "How long this Mac has been running, with load averages."
        case .picture: return "A picture of your own, scaled to the cube's 240 × 240 panel."
        }
    }

    @ViewBuilder private func addonSettings(_ t: Theme) -> some View {
        switch t {
        case .weather:
            Panel("Weather settings") {
                Picker("Location", selection: $settings.locationMode) {
                    Text("Same as this Mac").tag(AppSettings.LocationMode.auto)
                    Text("Manual").tag(AppSettings.LocationMode.manual)
                }.pickerStyle(.radioGroup)
                if settings.locationMode == .manual {
                    TextField("City (e.g. Amsterdam)", text: $settings.manualCity).frame(width: 220)
                    HStack { TextField("Lat", text: $settings.manualLat).frame(width: 90); TextField("Lon", text: $settings.manualLon).frame(width: 90) }
                } else {
                    Text("Time zone: \(settings.macTimeZone)").font(.caption).foregroundStyle(.secondary)
                }
                Picker("Units", selection: $settings.units) { Text("°C").tag(AppSettings.Units.metric); Text("°F").tag(AppSettings.Units.imperial) }
                    .pickerStyle(.segmented).frame(width: 160)
                Toggle("24-hour clock", isOn: $settings.clock24h).toggleStyle(.switch)
            }
        case .music:
            Panel("Music") { MusicControls() }
        case .picture:
            Panel("Picture") {
                HStack {
                    Text(settings.vivoPicturePath.isEmpty ? "No picture chosen." : (settings.vivoPicturePath as NSString).lastPathComponent).foregroundStyle(.secondary)
                    Button("Choose…") { Self.choosePicture(settings) }
                }
            }
        default:
            EmptyView()
        }
    }
}

struct MusicControls: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.nowPlaying.hasTrack ? model.nowPlaying.title : "Nothing playing").fontWeight(.medium)
            Text(model.nowPlaying.hasTrack ? model.nowPlaying.artist : " ").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { model.musicPrevious() } label: { Image(systemName: "backward.fill") }.accessibilityLabel("Previous track")
                Button { model.musicPlayPause() } label: { Image(systemName: model.nowPlaying.isPlaying ? "pause.fill" : "play.fill") }.accessibilityLabel(model.nowPlaying.isPlaying ? "Pause" : "Play")
                Button { model.musicNext() } label: { Image(systemName: "forward.fill") }.accessibilityLabel("Next track")
                Button { model.musicVolume(-10) } label: { Image(systemName: "speaker.wave.1.fill") }.accessibilityLabel("Quieter")
                Button { model.musicVolume(10) } label: { Image(systemName: "speaker.wave.3.fill") }.accessibilityLabel("Louder")
            }.buttonStyle(.bordered)
        }
    }
}
