import SwiftUI
import UltraBarKit

/// A binding row: control → action.
private struct BindingRow: View {
    let icon: String; let control: String; let action: String; let note: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(.secondary)
            Text(control).frame(width: 110, alignment: .leading)
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
            Text(action).fontWeight(.medium)
            if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
            Spacer()
        }
    }
}

private struct BindingsFooter: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    let lastUsed: Date?
    var body: some View {
        HStack(spacing: 12) {
            if settings.deckhandPagePublished {
                Label("Active while the Deckhand page is on the bar.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                if let d = lastUsed { Text("Last used \(Int(Date().timeIntervalSince(d))) s ago").foregroundStyle(.tertiary) }
            } else {
                Label("Not active yet — publish the CoreBar page once.", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                Button("Go to CoreBar page") { model.nav = .coreBarPage }.buttonStyle(.link)
            }
        }.font(.caption)
    }
}

struct KnobKeyView: View {
    @EnvironmentObject var model: AppModel
    let module: AttachedModule
    var body: some View {
        VStack(spacing: 0) {
            Header("KnobKey", "Turn and press.")
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 24) {
                        Image(systemName: "dial.medium").font(.system(size: 72)).foregroundStyle(.secondary).frame(width: 110)
                        Panel("What it does") {
                            BindingRow(icon: "arrow.clockwise", control: "Turn", action: "Mac volume", note: "the bar asks this Mac for the level and sets it")
                            BindingRow(icon: "hand.tap", control: "Press", action: "Mute / unmute", note: "")
                            if let v = model.lastKnobVolume { Text("Last level set from the knob: \(v) %").font(.caption).foregroundStyle(.secondary) }
                            BindingsFooter(lastUsed: model.lastVolumePushAt)
                        }
                    }
                    Text("Changing these bindings is planned; today they are fixed and shipped with every CoreBar page publish.").font(.caption).foregroundStyle(.tertiary)
                }.padding(20)
            }
        }
    }
}

struct DotKeyView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    let module: AttachedModule
    private func card(_ n: Int) -> String { n - 1 < settings.vivoCards.count ? settings.vivoCards[n - 1].title : "cube card \(n)" }
    var body: some View {
        VStack(spacing: 0) {
            Header("DotKey", "Three keys: two round, one long.")
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 24) {
                        // As on the desk: two round keys stacked on the left, one tall key on the right.
                        HStack(spacing: 8) {
                            VStack(spacing: 8) { Circle().fill(.quaternary).frame(width: 30, height: 30).overlay(Text("1").font(.caption)); Circle().fill(.quaternary).frame(width: 30, height: 30).overlay(Text("2").font(.caption)) }
                            Capsule().fill(.quaternary).frame(width: 26, height: 68).overlay(Text("3").font(.caption))
                        }.frame(width: 110).padding(.top, 10)
                        Panel("What it does") {
                            BindingRow(icon: "1.circle", control: "Key 1", action: "Cube: \(card(1))", note: "switches on the bar itself")
                            BindingRow(icon: "2.circle", control: "Key 2", action: "Cube: \(card(2))", note: "")
                            BindingRow(icon: "3.circle", control: "Key 3", action: "Cube: next card", note: "via this Mac")
                            BindingRow(icon: "3.circle.fill", control: "Hold key 3", action: "Bar: Standard page", note: "")
                            if !model.modules.contains(where: { $0.isVivoCube }) { Text("No VivoCube found — keys 1 and 2 do nothing until one is attached.").font(.caption).foregroundStyle(.orange) }
                            BindingsFooter(lastUsed: nil)
                        }
                    }
                    Text("Changing these bindings is planned; today they are fixed and shipped with every CoreBar page publish.").font(.caption).foregroundStyle(.tertiary)
                }.padding(20)
            }
        }
    }
}
