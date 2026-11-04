import SwiftUI
import AppKit
import UltraBarKit

/// Polls the wire log so the view updates live.
@MainActor final class LogWatcher: ObservableObject {
    @Published var lines: [String] = []
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.lines = WireLog.shared.recent()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
    func stop() { task?.cancel(); task = nil }
}

struct LogsView: View {
    @StateObject private var watcher = LogWatcher()
    @State private var copied = false
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header("Logs", "Every message between this Mac and the bar; secrets redacted.") {
                HStack {
                    Button { reveal() } label: { Label("Reveal in Finder", systemImage: "folder") }
                        .help("Show the log file in the Finder")
                    Button { copyAll() } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                        .disabled(watcher.lines.isEmpty).help("Copy every line shown here as text")
                    Button(role: .destructive) { confirmClear = true } label: { Label("Clear…", systemImage: "trash") }
                        .disabled(watcher.lines.isEmpty).help("Empty the log file. Asks first.")
                }
            }
            Divider()
            if watcher.lines.isEmpty {
                Text("Nothing logged yet.").foregroundStyle(.secondary).padding(20)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(watcher.lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(color(for: line))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(8)
                }
                .onChange(of: watcher.lines.count) { _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        .onAppear { watcher.start() }
        .onDisappear { watcher.stop() }
        .alert("Clear the log?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { WireLog.shared.clear(); watcher.lines = [] }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The log file on this Mac is emptied. Nothing on the bar changes.") }
    }

    private func color(for line: String) -> Color {
        if line.contains(" >> ") { return .blue }
        if line.contains(" << ") { return .green }
        if line.contains(" HTTP ") { return .orange }
        return .secondary
    }

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([WireLog.shared.fileURL])
    }
    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(watcher.lines.joined(separator: "\n"), forType: .string)
        copied = true
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); copied = false }
    }
}
