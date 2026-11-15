import SwiftUI
import AppKit

// The small set of building blocks every page uses, so the same thing looks and reads the same everywhere
// (design pass of 2026-11-15, after the HIG review):
//  • Colour rule: orange only for "needs you", red for "failed", green for "OK / connected", the accent colour for
//    "update available", secondary for everything informational. Never colour alone: always a symbol and words.
//  • Status and error lines are `.callout`, not `.caption`; caption is for metadata (versions, times).
//  • One prominent action per page, in the toolbar (`prominentAction()`), filled with the accent colour so it reads as
//    enabled at a glance, also when the window is not active; in a detail pane the item's main action (Install,
//    Update to …) is `primaryInline()`. Other inline buttons are plain push buttons. Grey means disabled, nothing else.
//  • Removing from a list is the same minus mark everywhere (`RemoveMark`); device and account actions ask first.

/// What a status line is about. Decides the symbol, the colour and the words a screen reader hears first.
enum StatusKind {
    case ok, attention, failed, info, update

    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        case .info: return "info.circle"
        case .update: return "arrow.down.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .ok: return .green
        case .attention: return .orange
        case .failed: return .red
        case .info: return .secondary
        case .update: return .accentColor
        }
    }
    var spoken: String {
        switch self {
        case .ok: return "OK"
        case .attention: return "Needs attention"
        case .failed: return "Failed"
        case .info: return "Note"
        case .update: return "Update available"
        }
    }
}

/// One status or error line: symbol + text in `.callout`. The text stays primary so it is readable in dark mode and
/// with Increase Contrast; only the symbol carries the colour.
struct StatusLabel: View {
    let text: String
    let kind: StatusKind
    init(_ text: String, _ kind: StatusKind) { self.text = text; self.kind = kind }
    var body: some View {
        Label {
            Text(text).foregroundStyle(kind == .info ? .secondary : .primary).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: kind.symbol).foregroundStyle(kind.color)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind.spoken): \(text)")
    }
}

/// A short "Working…" line with a spinner, for a task that runs on the bar.
struct BusyLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// Small capsule for a list row or a detail title: "Installed", "Update 1.3", "In use", "Built in".
struct Tag: View {
    let text: String; let kind: StatusKind
    init(_ text: String, _ kind: StatusKind) { self.text = text; self.kind = kind }
    var body: some View {
        Text(text).font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
            .background(kind.color.opacity(kind == .info ? 0.12 : 0.18), in: Capsule())
            .accessibilityLabel(text)
    }
}

/// The accent-filled capsule behind the page's key action and a detail pane's main action. Drawn by Deckhand rather than
/// the system on purpose: the system's prominent styles turn grey whenever the window is not the active one, and in
/// test that read as "disabled" (Update All, 2026-11-15, twice). This one stays blue while it can be pressed and is grey
/// only when it is really disabled.
struct AccentFillButtonStyle: ButtonStyle {
    var toolbar = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(enabled ? Color.white : Color.secondary)
            .padding(.horizontal, toolbar ? 14 : 10)
            .padding(.vertical, toolbar ? 6 : 3)
            .background(Capsule().fill(enabled ? Color.accentColor : Color.secondary.opacity(0.18)))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

extension View {
    /// The page's one key action in the toolbar: an accent capsule (see `AccentFillButtonStyle`). Wrap it in
    /// `ToolbarItem(...).accentToolbarItem()` so the toolbar does not draw its own glass around it as well.
    func prominentAction() -> some View { buttonStyle(AccentFillButtonStyle(toolbar: true)) }

    /// The main action of a detail pane or section (Install, Update to 2.4): the same accent capsule, so it is clearly
    /// the thing to press and clearly enabled. Pass `false` to draw it as a plain push button (e.g. Reinstall).
    @ViewBuilder func primaryInline(_ prominent: Bool = true) -> some View {
        if prominent { self.buttonStyle(AccentFillButtonStyle()) } else { self }
    }
}

extension ToolbarContent {
    /// No shared glass background behind a toolbar item that draws its own accent capsule (macOS 26 and later).
    @ToolbarContentBuilder func accentToolbarItem() -> some ToolbarContent {
        if #available(macOS 26.0, *) { self.sharedBackgroundVisibility(.hidden) } else { self }
    }
}

// MARK: Images from the bar and the marketplace

/// Loads an icon once and keeps it for the session. AsyncImage fetched the same icon again on every redraw of a list,
/// and in some list rows never showed it at all (the blank tiles of the review, S7).
@MainActor final class IconLoader: ObservableObject {
    private static let cache = NSCache<NSURL, NSImage>()
    @Published private(set) var image: NSImage?
    private var url: URL?

    func load(_ url: URL?) {
        guard url != self.url else { return }
        self.url = url
        image = nil
        guard let url else { return }
        if let hit = Self.cache.object(forKey: url as NSURL) { image = hit; return }
        if url.isFileURL {
            if let img = NSImage(contentsOf: url) { Self.cache.setObject(img, forKey: url as NSURL); image = img }
            return
        }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url), let img = NSImage(data: data) else { return }
            Self.cache.setObject(img, forKey: url as NSURL)
            if self.url == url { self.image = img }
        }
    }
}

/// An app's icon: the picture from the bar or the catalogue, else an SF Symbol, else a tile with the name's first letter.
struct AppIcon: View {
    let url: URL?
    var title: String = ""
    var fallback: String? = nil
    var size: CGFloat = 32
    @StateObject private var loader = IconLoader()

    var body: some View {
        Group {
            if let img = loader.image {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else if let fallback {
                Image(systemName: fallback).font(.system(size: size * 0.55)).foregroundStyle(.secondary)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(Color.accentColor.gradient)
                    Text(title.first.map { String($0).uppercased() } ?? "?")
                        .font(.system(size: size * 0.5, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
        .onAppear { loader.load(url) }
        .onChange(of: url) { loader.load($0) }
    }
}

// MARK: Removing

/// The minus mark that takes a row out of a list — the same look, size, help and accessibility label everywhere.
/// What happens after the click is the caller's: card lists remove at once with Undo (nothing reaches a device until
/// Publish / Send to Cube); lists that are saved and followed by the bar at once ask first.
/// The grip at the start of a row that can be dragged to another place in its list (`ReorderableRows` does the
/// work; the whole row drags, the grip says that it can). Also reachable from the row's context menu.
struct DragHandle: View {
    var body: some View {
        Image(systemName: "line.3.horizontal")
            .foregroundStyle(.secondary)
            .frame(width: 16)
            .help("Drag to reorder")
            .accessibilityHidden(true)
    }
}

// MARK: Reordering

/// The rows of a list the user puts in order, for inside a `Section` of a grouped `Form`. Each row gets a
/// `DragHandle`, can be dragged (anywhere but its buttons) to another place with an insertion line showing where
/// it lands, and has Move Up / Move Down in its context menu and as VoiceOver actions.
///
/// Why not `ForEach.onMove`: on macOS that only works inside a `List`; inside a `Form` it silently does nothing,
/// and a `List` nested in the Form's scroll view scrolls by itself and does not look like the section around it.
/// So the rows are plain Form rows with an AppKit-style drag (`onDrag`) and a drop target per row (`onDrop`).
///
/// `move` gets the same arguments `onMove` would (source offsets, destination offset as in `Array.move`), and only
/// for a real change, so callers keep their save code. A drag is accepted only from this list in this app: the
/// drag carries a one-time token that the drop checks against the drag pasteboard.
struct ReorderableRows<Item, ID: Hashable, Row: View, Menu: View>: View {
    let items: [Item]
    let id: KeyPath<Item, ID>
    /// Words for the two directions: "Up"/"Down" for a list, "Left"/"Right" where the order is left to right on the bar.
    var directions: (String, String) = ("Up", "Down")
    let move: (IndexSet, Int) -> Void
    @ViewBuilder let row: (Int, Item) -> Row
    /// More context menu items under the move items (start with a `Divider`).
    @ViewBuilder var menu: (Int, Item) -> Menu

    @State private var dragged: ID?
    @State private var token = ""
    /// Where the dragged row would go (0...items.count, as `Array.move`'s `toOffset`), while over a row.
    @State private var insertAt: Int?
    @State private var heights: [ID: CGFloat] = [:]

    var body: some View {
        ForEach(items.indices.map { Slot(index: $0, key: items[$0][keyPath: id]) }, id: \.key) { slot in
            let i = slot.index, key = slot.key, item = items[i]
            HStack(spacing: 0) {
                DragHandle().padding(.trailing, 8)
                row(i, item)
            }
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights[key] = $0 }
            .overlay(alignment: .top) { if showsLine(at: i) { InsertionLine().offset(y: -5) } }
            .overlay(alignment: .bottom) { if i == items.count - 1, showsLine(at: items.count) { InsertionLine().offset(y: 5) } }
            .onDrag {
                dragged = key
                token = "deckhand-reorder:" + UUID().uuidString
                return NSItemProvider(object: token as NSString)
            }
            .onDrop(of: [.utf8PlainText], delegate: RowDrop(owner: self, index: i, height: heights[key] ?? 0))
            .contextMenu {
                Button("Move \(directions.0)") { step(i, -1) }.disabled(i == 0)
                Button("Move \(directions.1)") { step(i, 1) }.disabled(i >= items.count - 1)
                menu(i, item)
            }
            .accessibilityActions {
                if i > 0 { Button("Move \(directions.0.lowercased())") { step(i, -1) } }
                if i < items.count - 1 { Button("Move \(directions.1.lowercased())") { step(i, 1) } }
            }
        }
    }

    private struct Slot { let index: Int; let key: ID }

    private func step(_ i: Int, _ delta: Int) {
        guard i + delta >= 0, i + delta < items.count else { return }
        move(IndexSet(integer: i), delta < 0 ? i - 1 : i + 2)
    }

    private var draggedIndex: Int? { dragged.flatMap { d in items.firstIndex { $0[keyPath: id] == d } } }

    /// An insertion right before or right after the dragged row changes nothing, so it gets no line.
    private func showsLine(at offset: Int) -> Bool {
        guard insertAt == offset, let from = draggedIndex else { return false }
        return offset != from && offset != from + 1
    }

    private struct InsertionLine: View {
        var body: some View {
            Capsule().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private struct RowDrop: DropDelegate {
        let owner: ReorderableRows
        let index: Int
        let height: CGFloat

        private func offset(_ info: DropInfo) -> Int { info.location.y < height / 2 ? index : index + 1 }

        func validateDrop(info: DropInfo) -> Bool { owner.dragged != nil }
        func dropEntered(info: DropInfo) { owner.insertAt = offset(info) }
        func dropUpdated(info: DropInfo) -> DropProposal? {
            let o = offset(info)
            if owner.insertAt != o { owner.insertAt = o }
            return DropProposal(operation: .move)
        }
        func dropExited(info: DropInfo) { if owner.insertAt == index || owner.insertAt == index + 1 { owner.insertAt = nil } }
        func performDrop(info: DropInfo) -> Bool {
            let to = offset(info)
            let from = owner.draggedIndex
            let ours = !owner.token.isEmpty && NSPasteboard(name: .drag).string(forType: .string) == owner.token
            owner.insertAt = nil
            owner.dragged = nil
            owner.token = ""
            guard ours, let from else { return false }
            if to != from && to != from + 1 { owner.move(IndexSet(integer: from), to) }
            return true
        }
    }
}

extension ReorderableRows where Menu == EmptyView {
    init(items: [Item], id: KeyPath<Item, ID>, directions: (String, String) = ("Up", "Down"),
         move: @escaping (IndexSet, Int) -> Void, @ViewBuilder row: @escaping (Int, Item) -> Row) {
        self.init(items: items, id: id, directions: directions, move: move, row: row, menu: { _, _ in EmptyView() })
    }
}

struct RemoveMark: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle").frame(width: 28, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Remove \(title)")
        .accessibilityLabel("Remove \(title)")
    }
}

/// Registers an Undo (and its Redo) for a change of one AppSettings value, under Edit › Undo and ⌘Z.
@MainActor func registerUndo<T>(_ undo: UndoManager?, _ settings: AppSettings, _ keyPath: ReferenceWritableKeyPath<AppSettings, T>, old: T, name: String) {
    guard let undo else { return }
    undo.registerUndo(withTarget: settings) { s in
        MainActor.assumeIsolated {
            let current = s[keyPath: keyPath]
            s[keyPath: keyPath] = old
            registerUndo(undo, s, keyPath, old: current, name: name)
        }
    }
    undo.setActionName(name)
}

// MARK: Help

/// The native round help button (?) that opens a Help topic.
struct HelpButton: NSViewRepresentable {
    let topic: HelpTopic
    init(_ topic: HelpTopic) { self.topic = topic }

    func makeNSView(context: Context) -> NSButton {
        let b = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.open))
        b.bezelStyle = .helpButton
        b.setAccessibilityLabel("Help: \(topic.title)")
        b.toolTip = topic.title
        return b
    }
    func updateNSView(_ b: NSButton, context: Context) { context.coordinator.topic = topic }
    func makeCoordinator() -> Coordinator { Coordinator(topic: topic) }

    @MainActor final class Coordinator: NSObject {
        var topic: HelpTopic
        init(topic: HelpTopic) { self.topic = topic }
        @objc func open() { HelpWindow.open(topic) }
    }
}

/// Longer background for a section, folded away: the section's footer stays one sentence.
struct DetailsDisclosure<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String = "Details", @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        DisclosureGroup(title) {
            VStack(alignment: .leading, spacing: 6) { content }
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}

extension DetailsDisclosure where Content == Text {
    init(_ title: String = "Details", text: String) { self.init(title) { Text(text) } }
}

// MARK: Opening the Settings and Help windows from anywhere

/// The panes of the Settings window (⌘,).
enum SettingsTab: String, CaseIterable {
    case general, location, bars, debugBridge, privacy
    static let key = "settingsTab"
}

@MainActor
enum SettingsWindow {
    /// SwiftUI's `openSettings` (macOS 14 and later), handed over by the main window when it appears.
    static var openAction: (() -> Void)?

    static func open(_ tab: SettingsTab? = nil) {
        if let tab { UserDefaults.standard.set(tab.rawValue, forKey: SettingsTab.key) }
        AppActivation.bringToFront()
        if let openAction { openAction() }
        else { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
    }
}

@available(macOS 14.0, *)
private struct SettingsOpenerBridge: View {
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onAppear { let open = openSettings; SettingsWindow.openAction = { open() } }
    }
}

extension View {
    /// Lets `SettingsWindow.open` use SwiftUI's own action where there is one.
    func registersSettingsOpener() -> some View {
        background {
            if #available(macOS 14.0, *) { SettingsOpenerBridge() }
        }
    }
}

/// "Amsterdam", "This Mac's location": the one line every Weather / Flights / Sun & Moon / Tide setting shows,
/// with the way to the single place where it is set (Settings → Location & Units).
struct LocationSummaryRow: View {
    @EnvironmentObject var settings: AppSettings
    var body: some View {
        LabeledContent("Location") {
            HStack(spacing: 8) {
                Text(summary).foregroundStyle(.secondary)
                Button("Change…") { SettingsWindow.open(.location) }
            }
        }
    }
    private var summary: String {
        switch settings.locationMode {
        case .auto: return "Same as this Mac"
        case .manual: return settings.manualCity.isEmpty ? "\(settings.manualLat), \(settings.manualLon)" : settings.manualCity
        }
    }
}

// MARK: Filter bar

/// The one filter bar: directly under the toolbar, at the top of the list or content it filters, on every page that
/// has filters (Apps, Screensavers, Logs). Always the same height and the same order: scope picker, search field,
/// then on the trailing side the list's Refresh. The toolbar keeps only the page's primary action, the Activity
/// toggle and the connection badge (owner's feedback on the first redesign, 2026-11-15).
struct FilterBar<Scope: Hashable & Identifiable>: View {
    var scopes: [Scope] = []
    var scopeTitle: (Scope) -> String = { _ in "" }
    var scope: Binding<Scope>? = nil
    var search: Binding<String>? = nil
    var searchPrompt = "Filter"
    var refresh: (() -> Void)? = nil
    var refreshDisabled = false
    var refreshHelp = "Refresh (⌘R)"

    static var height: CGFloat { 40 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // A compact pop-up, not a segmented control: the list column is narrow and the search field needs the room.
                if let scope, !scopes.isEmpty {
                    Picker("Show", selection: scope) { ForEach(scopes) { Text(scopeTitle($0)).tag($0) } }
                        .pickerStyle(.menu).labelsHidden().controlSize(.small).fixedSize()
                        .help("Which items the list shows")
                }
                if let search {
                    SearchField(text: search, prompt: searchPrompt).frame(minWidth: 80, maxWidth: .infinity)
                } else {
                    Spacer(minLength: 0)
                }
                if let refresh {
                    Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .keyboardShortcut("r", modifiers: .command)
                        .disabled(refreshDisabled)
                        .help(refreshHelp)
                        .accessibilityLabel("Refresh")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: Self.height)
            Divider()
        }
    }
}

/// No scope: a filter bar with only a search field (and Refresh).
enum NoScope: Hashable, Identifiable { case none; var id: Self { self } }

/// The system search field (magnifying glass, clear button), small, for the filter bar.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let f = NSSearchField()
        f.placeholderString = prompt
        f.controlSize = .small
        f.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        f.delegate = context.coordinator
        f.sendsSearchStringImmediately = true
        f.setAccessibilityLabel(prompt)
        return f
    }
    func updateNSView(_ f: NSSearchField, context: Context) {
        if f.stringValue != text { f.stringValue = text }
    }
    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ n: Notification) {
            guard let f = n.object as? NSSearchField else { return }
            text.wrappedValue = f.stringValue
        }
    }
}

/// A section footer: one short sentence, leading-aligned under the group (a bare Text sat at the trailing edge).
struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }
}
