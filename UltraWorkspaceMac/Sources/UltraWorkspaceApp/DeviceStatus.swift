import SwiftUI
import UltraBarKit

/// The first section of a device page: what the device shows right now (read back, not assumed), the last Publish or
/// Send, and only when something is wrong one sentence with one button that fixes it. Part of the page's Form, so it
/// scrolls under the glass toolbar instead of sitting in an opaque band (design pass 2026-11-15).
struct DeviceStatusSection<Extra: View>: View {
    enum Kind { case bar, cube }
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    let kind: Kind
    @ViewBuilder let extra: Extra

    var body: some View {
        Section {
            // The time of the last Publish or Send is on the progress row below (`extra`), so not repeated here.
            LabeledContent("Showing now") { Text(DeviceStatusText.showing(model, settings, kind == .cube, withTime: false)).multilineTextAlignment(.trailing) }
            if kind == .cube, let w = model.selectedModuleSerial.flatMap({ model.vivoWiFi[$0] ?? nil }) {
                LabeledContent("Wi\u{2011}Fi") {
                    Label(w.isCoreBarHotspot ? "CoreBar hotspot" : w.ssid, systemImage: model.cubeOffline ? "wifi.exclamationmark" : "wifi")
                        .foregroundStyle(model.cubeOffline ? Color.orange : Color.secondary)
                        .help(model.cubeOffline ? "The cube is \(model.cubeWiFiLabel)." : "The cube is connected and can receive cards.")
                }
            }
            extra
            if let f = model.deviceFault(settings: settings, cube: kind == .cube) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    // No fixedSize on the text beside the button: it would be measured at zero width (2026-11-03).
                    StatusLabel(f.message, .attention).frame(maxWidth: .infinity, alignment: .leading)
                    Button(f.action.title) { f.action.run() }.fixedSize()
                }
            }
        }
        // Each refresh is several connections to the bar: skipped while the window is hidden or covered (the
        // view's task keeps running when the window is minimized) and while this Mac is idle.
        .task {
            while !Task.isCancelled {
                if MainWindow.isOnScreen, !PowerState.shared.idle { await model.refreshDeviceState(); await Task.relaxedSleep(30) }
                else { await Task.relaxedSleep(5) }
            }
        }
    }
}

/// What the bar and the cube show right now, in words: the same sentence on the device pages and on Overview.
/// `withTime: false` leaves out "· published 5:54" / "· sent 5:54" where a progress row already shows that time.
@MainActor
enum DeviceStatusText {
    static func showing(_ model: AppModel, _ settings: AppSettings, _ cube: Bool, withTime: Bool = true) -> String {
        let time: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }
        let stamp: (String, Date?) -> String = { verb, d in (withTime ? d : nil).map { " · \(verb) \(time($0))" } ?? "" }
        if cube {
            if model.cubePackageStale {
                return "The previous cards: the cube is off Wi\u{2011}Fi" + (model.lastCubeSentAt.map { withTime ? " · sent \(time($0)), not delivered" : " · the last send was not delivered" } ?? "")
            }
            if let l = model.vivoLayerShowing {
                if l >= 1, l <= model.vivoLayerNames.count {
                    return "Card \(l) of \(model.vivoLayerNames.count): \(model.vivoLayerNames[l - 1])" + stamp("sent", model.lastCubeSentAt)
                }
                return "Card \(l)" + (model.vivoLayerNames.isEmpty ? " · nothing sent from this Mac yet" : " · not in the last package")
            }
            return "Not read yet"
        }
        let name = model.currentPageId.flatMap { id in model.corebarPages.first { $0.id == id }?.name ?? id }
        let base = name.map { "The \($0) page" } ?? (settings.deckhandPagePublished ? "Unknown until Deckhand switches the page" : "The Deckhand page is not published yet")
        return base + stamp("published", model.lastPagePublishedAt)
    }
}
