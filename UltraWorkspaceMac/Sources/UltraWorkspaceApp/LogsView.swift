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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header("Logs", "Every message between this Mac and the bar; secrets redacted.") {
                HStack {
                    Button { reveal() } label: { Label("Reveal in Finder", systemImage: "folder") }
                    Button { copyAll() } label: { Label("Copy", systemImage: "doc.on.doc") }
                    Button(role: .destructive) { WireLog.shared.clear(); watcher.lines = [] } label: { Label("Clear", systemImage: "trash") }
                }
            }
            Divider()

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
    }
}
