import SwiftUI
import UltraBarKit

/// Overview (was Status): what the bar and the cube show now, the problems first with one button each, everything the
/// hardware reports, and a copyable report.
struct OverviewView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @StateObject private var ui = UI()
    private final class UI: ObservableObject { @Published var copied = false }

    private var problems: [DoctorItem] { model.doctorItems.filter { $0.state == .fail || $0.state == .warn } }
    private var infos: [DoctorItem] { model.doctorItems.filter { $0.state == .info } }
    private var fine: [DoctorItem] { model.doctorItems.filter { $0.state == .ok } }

    var body: some View {
        Form {
            Section("Now") {
                LabeledContent("Connection") { ConnectionText() }
                if model.selectedCoreBar != nil {
                    LabeledContent("CoreBar") { Text(DeviceStatusText.showing(model, settings, false)).multilineTextAlignment(.trailing) }
                    if model.modules.contains(where: { $0.isVivoCube }) {
                        LabeledContent("VivoCube") { Text(DeviceStatusText.showing(model, settings, true)).multilineTextAlignment(.trailing) }
                    }
                }
            }
            if model.doctorItems.isEmpty {
                Section { BusyLabel("Asking the bar and its modules…") }
            } else {
                Section("Needs attention") {
                    if problems.isEmpty { StatusLabel("Everything the hardware reports looks fine.", .ok) }
                    ForEach(problems) { row($0) }
                }
                if !infos.isEmpty { Section("Details") { ForEach(infos) { row($0) } } }
                if !fine.isEmpty { Section("Looks fine (\(fine.count))") { ForEach(fine) { row($0) } } }
            }
            Section {
                Button(ui.copied ? "Copied" : "Copy Report") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.doctorReportText(settings: settings), forType: .string)
                    ui.copied = true; Task { try? await Task.sleep(nanoseconds: 2_000_000_000); ui.copied = false }
                }
                .disabled(model.doctorItems.isEmpty)
            } header: {
                Text("Report")
            } footer: {
                Footnote("Everything on this page with your settings and the last log lines, as text for a bug report. No keys; addresses, serials and places are masked.")
            }
        }
        .formStyle(.grouped)
        .navigationSubtitle(model.doctorRanAt.map { "Checked \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.runDoctor(settings: settings) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: .command).disabled(model.doctorRunning)
                    .help("Ask the bar and its modules again (⌘R). Also every 30 s while this page is open.")
            }
        }
        .task {
            while !Task.isCancelled {
                // Not while the window is hidden or covered, or this Mac is idle (the view's task keeps running when
                // the window is minimized); checked again within 5 s of it showing.
                if MainWindow.isOnScreen, !PowerState.shared.idle { model.runDoctor(settings: settings); await Task.relaxedSleep(30) }
                else { await Task.relaxedSleep(5) }
            }
        }
    }

    private func row(_ item: DoctorItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: kind(item.state).symbol).foregroundStyle(kind(item.state).color)
                .accessibilityLabel(kind(item.state).spoken)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(item.group): \(item.name)")
                Text(item.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let a = item.action { Button(a.title) { a.run() }.fixedSize() }
        }
    }

    private func kind(_ s: DoctorItem.State) -> StatusKind {
        switch s { case .ok: return .ok; case .warn: return .attention; case .fail: return .failed; case .info: return .info }
    }
}
