import SwiftUI
import UltraBarKit

/// Device truth, worst first, one button per problem, and a copyable report.
struct StatusView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @StateObject private var ui = UI()
    private final class UI: ObservableObject { @Published var copied = false }

    private var problems: [DoctorItem] { model.doctorItems.filter { $0.state == .fail || $0.state == .warn } }
    private var infos: [DoctorItem] { model.doctorItems.filter { $0.state == .info } }
    private var fine: [DoctorItem] { model.doctorItems.filter { $0.state == .ok } }

    var body: some View {
        VStack(spacing: 0) {
            Header("Status", model.doctorRanAt.map { "Checked \($0.formatted(date: .omitted, time: .shortened)) · again every 30 s while open" } ?? "Asking the bar and its modules…") {
                HStack {
                    Button {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.doctorReportText(settings: settings), forType: .string)
                        ui.copied = true; Task { try? await Task.sleep(nanoseconds: 2_000_000_000); ui.copied = false }
                    } label: { Label(ui.copied ? "Copied" : "Copy report", systemImage: ui.copied ? "checkmark" : "doc.on.doc") }
                    .disabled(model.doctorItems.isEmpty).help("Everything on this page plus settings and the last log lines, as text")
                    Button { model.runDoctor(settings: settings) } label: { Label(model.doctorRunning ? "Checking…" : "Check again", systemImage: "arrow.clockwise") }
                        .keyboardShortcut("r", modifiers: .command).disabled(model.doctorRunning)
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.doctorItems.isEmpty {
                        HStack { ProgressView().controlSize(.small); Text("Checking…").foregroundStyle(.secondary) }
                    } else {
                        if problems.isEmpty {
                            Label("Everything the hardware reports looks fine.", systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.title3)
                        } else {
                            Panel("Needs attention") { ForEach(problems) { row($0) } }
                        }
                        if !infos.isEmpty { Panel("Details") { ForEach(infos) { row($0) } } }
                        if !fine.isEmpty {
                            Panel("Looks fine (\(fine.count))") { ForEach(fine) { row($0) } }
                        }
                    }
                }.padding(20).frame(maxWidth: 760, alignment: .leading)
            }
        }
        .task {
            while !Task.isCancelled {
                model.runDoctor(settings: settings)
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    private func row(_ item: DoctorItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(color(item.state)).frame(width: 9, height: 9).padding(.top, 5)
                .accessibilityLabel(label(item.state))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) { Text(item.name).fontWeight(.medium); Text(item.group).font(.caption2).foregroundStyle(.tertiary) }
                Text(item.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let a = item.action { Button(a.title) { a.run() }.controlSize(.small).fixedSize() }
        }
    }
    private func color(_ s: DoctorItem.State) -> Color { switch s { case .ok: return .green; case .warn: return .orange; case .fail: return .red; case .info: return .secondary } }
    private func label(_ s: DoctorItem.State) -> String { switch s { case .ok: return "OK"; case .warn: return "Warning"; case .fail: return "Problem"; case .info: return "Info" } }
}
