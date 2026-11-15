import SwiftUI
import UltraBarKit

/// Controls: what the KnobKey and the DotKey do, on one page (they were two nearly empty pages). The bindings are
/// fixed for now and travel with the CoreBar's Deckhand page, so this page has no Publish of its own: it links to
/// CoreBar, where Publish sends them (the "Publish bindings" button of 2026-11-04 was the same publish by another name).
struct ControlsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings

    private var hasKnob: Bool { model.modules.contains { $0.type == "KNOB_KEY" } }
    private var hasDot: Bool { model.modules.contains { $0.type == "DOT_KEY" } }

    var body: some View {
        Form {
            Section {
                if settings.deckhandPagePublished {
                    StatusLabel("Active while the Deckhand page is on the bar.", .ok)
                } else {
                    HStack {
                        StatusLabel("Not active yet: publish the Deckhand page once.", .attention)
                        Spacer()
                        Button("Open CoreBar") { model.nav = .coreBarPage }
                    }
                }
            } footer: {
                Footnote("The bindings are fixed for now. They reach the bar with every Publish on the CoreBar page.")
            }
            if hasKnob {
                Section("KnobKey") {
                    LabeledContent("Turn", value: "Mac volume")
                    LabeledContent("Press", value: "Play / pause in Music")
                    LabeledContent("Speakers") {
                        if MacAudio.shared.hasControl {
                            Text("\(MacAudio.shared.name) · \(model.lastKnobVolume ?? MacAudio.shared.volume ?? 0) %").foregroundStyle(.secondary)
                        } else {
                            StatusLabel("\(MacAudio.shared.name) has no volume control. Choose other speakers in System Settings → Sound.", .attention)
                        }
                    }
                    // `lastVolumePushAt` is a plain property (not published): read every 5 s.
                    TimelineView(.periodic(from: .now, by: 5)) { _ in
                        LabeledContent("Last used", value: model.lastVolumePushAt.map { "\(Int(Date().timeIntervalSince($0))) s ago" } ?? "Not yet")
                    }
                }
            }
            if hasDot {
                Section {
                    LabeledContent("Key 1", value: "Cube: previous card")
                    LabeledContent("Key 2", value: "Cube: next card")
                    LabeledContent("Hold key 3", value: "Bar: Standard page")
                    if !model.modules.contains(where: { $0.isVivoCube }) {
                        StatusLabel("No VivoCube found: keys 1 and 2 do nothing until one is attached.", .info)
                    }
                } header: {
                    Text("DotKey")
                } footer: {
                    Footnote("Keys 1 and 2 are the two round keys; key 3 is the long one.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationSubtitle([hasKnob ? "KnobKey" : nil, hasDot ? "DotKey" : nil].compactMap { $0 }.joined(separator: " and "))
    }
}
