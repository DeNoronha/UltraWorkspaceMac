import SwiftUI
import UltraBarKit

/// The always-visible truth line at the top of every device page:
/// connection · what the device shows · last applied · one fault + one button.
struct DeviceStrip: View {
    enum Kind { case bar, cube }
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    let kind: Kind

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                LinkBadge()
                if let age = model.lastPushAt.map({ Int(Date().timeIntervalSince($0)) }), model.link.isConnected {
                    Text("last request \(age) s ago").font(.caption).foregroundStyle(.tertiary)
                }
                if kind == .cube, let w = model.selectedModuleSerial.flatMap({ model.vivoWiFi[$0] ?? nil }) {
                    Label(w.isCoreBarHotspot ? "CoreBar hotspot" : w.ssid, systemImage: model.cubeOffline ? "wifi.exclamationmark" : "wifi")
                        .font(.caption).foregroundStyle(model.cubeOffline ? Color.orange : Color.secondary)
                        .help(model.cubeOffline ? "The cube is \(model.cubeWiFiLabel) — see Maintenance → Wi-Fi." : "The cube is connected and can receive cards.")
                }
                Spacer()
                showing.font(.caption).foregroundStyle(.secondary)
            }
            if let f = model.deviceFault(settings: settings, cube: kind == .cube) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    // No fixedSize here: inside an HStack next to a button it gets measured at zero width,
                    // reports a mile-high minimum, and the split view grows past the window (2026-11-03).
                    Text(f.message).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    Button(f.action.title) { f.action.run() }.controlSize(.small).fixedSize()
                }
                .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { while !Task.isCancelled { await model.refreshDeviceState(); try? await Task.sleep(nanoseconds: 30_000_000_000) } }
    }

    private var showing: Text {
        switch kind {
        case .cube:
            if model.cubePackageStale {
                return Text("Cube is off Wi-Fi — still shows its previous cards") + (model.lastCubeSentAt.map { Text(" · sent \($0.formatted(date: .omitted, time: .shortened)), not delivered") } ?? Text(""))
            }
            if let l = model.vivoLayerShowing {
                if l >= 1, l <= model.vivoLayerNames.count {
                    return Text("Cube shows card \(l) of \(model.vivoLayerNames.count): \(model.vivoLayerNames[l - 1])") + sent
                }
                return Text("Cube is on card \(l)") + (model.vivoLayerNames.isEmpty ? Text(" · nothing sent from this Mac yet") : Text(" · not in the last package"))
            }
            return Text("Cube: not read yet")
        case .bar:
            let name = model.currentPageId.flatMap { id in model.corebarPages.first { $0.id == id }?.name ?? id }
            let base = name.map { "Bar shows the \($0) page" } ?? (settings.deckhandPagePublished ? "Bar: page unknown until Deckhand switches it" : "Bar: Deckhand page not published yet")
            return Text(base) + (model.lastPagePublishedAt.map { Text(" · published \($0.formatted(date: .omitted, time: .shortened))") } ?? Text(""))
        }
    }
    private var sent: Text { model.lastCubeSentAt.map { Text(" · sent \($0.formatted(date: .omitted, time: .shortened))") } ?? Text("") }
}
