import SwiftUI
import UltraBarKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .frame(minWidth: 240)
        } detail: {
            DetailView()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.scan()
                } label: {
                    Label("Scan", systemImage: "antenna.radiowaves.left.and.right")
                }
                .disabled(model.isScanning)
            }
        }
        .overlay(alignment: .bottom) { StatusBar() }
        .sheet(isPresented: Binding(get: { model.pairingPrompt != nil },
                                    set: { if !$0 { model.pairingPrompt = nil } })) {
            VStack(spacing: 16) {
                ProgressView()
                Text(model.pairingPrompt ?? "")
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(width: 360)
        }
    }
}

private struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: $model.selectedSerial) {
            Section("Paired") {
                if model.paired.isEmpty {
                    Text("None yet").foregroundStyle(.secondary)
                }
                ForEach(model.paired) { bar in
                    Label {
                        VStack(alignment: .leading) {
                            Text(bar.name).fontWeight(.medium)
                            Text(bar.serialNo).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "rectangle.on.rectangle.angled")
                    }
                    .tag(bar.serialNo)
                    .contextMenu {
                        Button("Remove / Unpair", role: .destructive) { model.unpair(bar) }
                    }
                }
            }

            Section("Discovered") {
                if model.discovered.isEmpty {
                    Text(model.isScanning ? "Scanning…" : "Press Scan").foregroundStyle(.secondary)
                }
                ForEach(model.discovered) { bar in
                    let isPaired = model.paired.contains { $0.serialNo == bar.serialNo }
                    HStack {
                        VStack(alignment: .leading) {
                            Text(bar.name.isEmpty ? bar.serialNo : bar.name)
                            Text("\(bar.ip)  ·  v\(bar.version)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isPaired {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Pair") { model.pair(bar) }.buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct DetailView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let bar = model.selectedCoreBar {
            VStack(alignment: .leading, spacing: 0) {
                header(bar)
                Divider()
                HSplitView {
                    modulePanel.frame(minWidth: 280)
                    logPanel.frame(minWidth: 280)
                }
            }
        } else {
            ContentUnavailableLikeView()
        }
    }

    private func header(_ bar: Store.PairedCoreBar) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(bar.name).font(.title2).bold()
                Text("\(bar.serialNo)  ·  \(model.ipForSelected() ?? bar.lastIp)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.refreshModules()
            } label: {
                Label("Refresh modules", systemImage: "arrow.clockwise")
            }
            .disabled(model.isWorking)
        }
        .padding()
    }

    private var modulePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Modules").font(.headline)
            if model.modules.isEmpty {
                Text("No modules loaded. Press “Refresh modules”.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Module", selection: $model.selectedModuleSerial) {
                    ForEach(model.modules) { m in
                        Text("\(m.serial)\(m.upSeconds.map { "  ·  up \(formatUptime($0))" } ?? "")")
                            .tag(Optional(m.serial))
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Divider()
            Text("Display").font(.headline)
            HStack {
                Button("Screen On") { model.setScreen(on: true) }
                Button("Screen Off") { model.setScreen(on: false) }
                Button("Reboot", role: .destructive) { model.reboot() }
            }
            .disabled(model.selectedModuleSerial == nil)

            Divider()
            Text("Push an image").font(.headline)
            HStack {
                Text("Canvas")
                Picker("", selection: $model.canvasSize) {
                    ForEach([240, 280, 320, 360, 410, 480], id: \.self) { Text("\($0)px").tag($0) }
                }.labelsHidden().frame(width: 100)
            }
            Button {
                model.chooseAndUploadImage()
            } label: {
                Label("Choose image & upload…", systemImage: "photo.badge.arrow.down")
            }
            .disabled(model.selectedModuleSerial == nil || model.isWorking)
            Text("If the image looks wrong on the cube, try another canvas size — the VivoCube’s native resolution isn’t published, so the right value is found by trying.")
                .font(.caption).foregroundStyle(.secondary)

            Spacer()
        }
        .padding()
    }

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activity").font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(model.log) { e in
                        HStack(alignment: .top) {
                            Text(e.time, style: .time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(e.text).font(.caption).textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
    }

    private func formatUptime(_ s: Int64) -> String {
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

private struct ContentUnavailableLikeView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle.angled").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Select a CoreBar").font(.title3)
            Text("Press Scan, then Pair with your CoreBar. Tap Approve on the device when prompted.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            Button("Scan now") { model.scan() }.disabled(model.isScanning)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StatusBar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 8) {
            if model.isScanning || model.isWorking { ProgressView().controlSize(.small) }
            Text(model.statusLine).font(.caption).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }
}
