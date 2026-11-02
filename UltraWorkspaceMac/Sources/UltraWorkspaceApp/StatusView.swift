import SwiftUI
import UltraBarKit

/// Device status ("Doctor"): what the hardware reports right now, plus a copyable
/// text report — the alternative to photographing the device.
struct StatusView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @StateObject private var ui = UI()
    private final class UI: ObservableObject { @Published var copied = false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Status").font(.title2).bold()
                    Text(model.doctorRanAt.map { "Checked \($0.formatted(date: .omitted, time: .shortened))" } ?? "Reads the device's own state — no photo needed.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.doctorReportText(), forType: .string)
                    ui.copied = true
                    Task { try? await Task.sleep(nanoseconds: 2_000_000_000); ui.copied = false }
                } label: { Label(ui.copied ? "Copied" : "Copy report", systemImage: ui.copied ? "checkmark" : "doc.on.doc") }
                .disabled(model.doctorItems.isEmpty)
                Button { model.runDoctor(settings: settings) } label: { Label(model.doctorRunning ? "Checking…" : "Run checks", systemImage: "stethoscope") }
                    .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(model.doctorRunning)
            }.padding()
            Divider()
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if model.doctorItems.isEmpty {
                            Text("Press “Run checks”. Deckhand then asks the CoreBar and the modules what they are doing: reachability, the live link, pages, the VivoCube's Wi-Fi/screen/current widget, SenseCube readings, the KnobKey link and the last upload result.")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(groups(), id: \.self) { g in
                            Text(g).font(.headline).padding(.top, 6)
                            ForEach(model.doctorItems.filter { $0.group == g }) { item in
                                HStack(alignment: .top, spacing: 8) {
                                    Circle().fill(color(item.state)).frame(width: 9, height: 9).padding(.top, 5)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.name).fontWeight(.medium)
                                        Text(item.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }.padding().frame(maxWidth: .infinity, alignment: .leading)
                }
                // Device twin: what the VivoCube should be showing right now.
                VStack(alignment: .leading, spacing: 8) {
                    Text("VivoCube — expected picture").font(.headline)
                    let showing = model.doctorItems.first { $0.group == "VivoCube" && $0.name == "Showing" }
                    let layer = showing.flatMap { Int($0.detail.components(separatedBy: " ").dropFirst().first ?? "") } ?? (model.vivoLayerIndex + 1)
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black)
                        if let img = model.vivoLayerImages[layer] {
                            Image(nsImage: img).resizable().interpolation(.high).frame(width: 200, height: 200).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        } else {
                            Text(model.vivoLayerImages.isEmpty ? "No package sent in this session" : "Layer \(layer): not in the last package").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                        }
                    }.frame(width: 220, height: 220)
                    Text(model.vivoLayerNames.isEmpty ? "" : "Layers in the last package: " + model.vivoLayerNames.enumerated().map { "\($0.offset + 1) \($0.element)" }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("This is the image Deckhand rendered for the layer the device says it is showing. If the device shows something else, the package was not applied (see Last upload / Wi-Fi).")
                        .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }.padding().frame(minWidth: 260, maxWidth: 300)
            }
        }
        .onAppear { if model.doctorItems.isEmpty { model.runDoctor(settings: settings) } }
    }

    private func groups() -> [String] { var seen: [String] = []; for i in model.doctorItems where !seen.contains(i.group) { seen.append(i.group) }; return seen }
    private func color(_ s: DoctorItem.State) -> Color { switch s { case .ok: return .green; case .warn: return .orange; case .fail: return .red; case .info: return .secondary } }
}
