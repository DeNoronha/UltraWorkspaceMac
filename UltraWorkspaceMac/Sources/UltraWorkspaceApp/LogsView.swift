import SwiftUI
import AppKit
import UltraBarKit

/// Polls the wire log so the view updates live: every 2 s, and only publishes when a line was added (the ring is
/// up to 1,000 lines; publishing an unchanged copy every second re-diffed the whole list).
@MainActor final class LogWatcher: ObservableObject {
    @Published var lines: [String] = []
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let now = WireLog.shared.recent()
                if now.count != self.lines.count || now.last != self.lines.last { self.lines = now }
                // Nobody sees the page while the window is hidden or covered: just wait for it to come back.
                await Task.relaxedSleep(MainWindow.isOnScreen ? 2 : 10)
            }
        }
    }
    func stop() { task?.cancel(); task = nil }
}

struct LogsView: View {
    @StateObject private var watcher = LogWatcher()
    @State private var copied = false
    @State private var confirmClear = false
    @State private var search = ""

    /// Newest first, like Activity (2026-11-15): the wire log's ring is oldest first, so it is turned round here. The
    /// file on disk stays oldest first, because it is only ever appended to.
    private var shownLines: [String] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let newestFirst = watcher.lines.reversed()
        return q.isEmpty ? Array(newestFirst) : newestFirst.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            FilterBar<NoScope>(search: $search, searchPrompt: "Filter")
            if watcher.lines.isEmpty {
                EmptyState(icon: "doc.text.magnifyingglass",
                           title: WireLog.shared.enabled ? "Nothing Logged Yet" : "The Diagnostic Log Is Off",
                           text: WireLog.shared.enabled ? "Messages between this Mac and the bar appear here." : "Turn it on to keep every message between this Mac and the bar, for troubleshooting.") {
                    if !WireLog.shared.enabled { Button("Privacy Settings…") { SettingsWindow.open(.privacy) } }
                }
            } else {
                // New lines come in at the top, where the view starts; it no longer scrolls to the end by itself.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(shownLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.callout.monospaced())
                                .foregroundStyle(color(for: line))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .navigationSubtitle("Messages between this Mac and the bar, newest first; secrets removed")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { copyAll() } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .disabled(shownLines.isEmpty).help("Copy the lines shown here as text, newest first")
                Button { confirmClear = true } label: { Label("Clear…", systemImage: "trash") }
                    .disabled(watcher.lines.isEmpty && WireLog.shared.fileSize == 0).help("Empty the log file. Asks first.")
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
        // Direction is information, not status: the accent colour for what this Mac sends, primary for the bar's
        // answers, secondary for the rest (no green or orange, which mean OK and "needs you" elsewhere).
        if line.contains(" >> ") { return .accentColor }
        if line.contains(" << ") { return .primary }
        return .secondary
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shownLines.joined(separator: "\n"), forType: .string)
        copied = true
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); copied = false }
    }
}
