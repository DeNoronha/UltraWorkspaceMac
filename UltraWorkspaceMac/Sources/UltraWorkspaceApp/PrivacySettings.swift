import SwiftUI
import UltraBarKit

/// Settings → Privacy: the diagnostic log switch (off by default) and Clear for the log and Activity. Self-contained,
/// so the Settings window can be rearranged around it.
struct PrivacySettingsSection: View {
    @EnvironmentObject var model: AppModel
    @State private var on = WireLog.shared.enabled
    @State private var size = WireLog.shared.fileSize
    @State private var confirmClear = false

    var body: some View {
        Section {
            Toggle("Keep a diagnostic log", isOn: $on)
                .onChange(of: on) { v in
                    WireLog.shared.enabled = v
                    if !v { model.log.removeAll() }
                    size = WireLog.shared.fileSize
                }
            LabeledContent("Log", value: status)
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([WireLog.shared.fileURL]) }
                    .disabled(size == 0)
                Button("Clear Log and Activity…") { confirmClear = true }
                .disabled(size == 0 && model.log.isEmpty && WireLog.shared.recent().isEmpty)
                .help("Empties the log file and the Activity list on this Mac. Nothing on the bar changes.")
                .alert("Clear the log and Activity?", isPresented: $confirmClear) {
                    Button("Clear", role: .destructive) { WireLog.shared.clear(); model.log.removeAll(); size = WireLog.shared.fileSize }
                    Button("Cancel", role: .cancel) {}
                } message: { Text("The log file and the Activity list on this Mac are emptied. Nothing on the bar changes.") }
            }
            DetailsDisclosure(text: "While on, Deckhand keeps every message to and from the bar (the Logs page) and the Activity list, for troubleshooting. Keys, tokens and passwords are always removed, places are rounded to about 10 km and Wi\u{2011}Fi names shortened. Lines older than 7 days are dropped and the file stays under 2 MB. While off, nothing is kept.")
        } header: {
            Text("Diagnostic log")
        } footer: {
            Footnote("Off by default. Keys and passwords are never written to it.")
        }
        .onAppear { on = WireLog.shared.enabled; size = WireLog.shared.fileSize }
    }

    private var status: String {
        let kb = size >= 1024 ? "\(size / 1024) KB on disk" : (size == 0 ? "empty" : "\(size) B on disk")
        if let since = WireLog.shared.enabledSince { return "On since \(since.formatted(date: .abbreviated, time: .shortened)) · \(kb)" }
        return "Off · \(kb)"
    }
}
