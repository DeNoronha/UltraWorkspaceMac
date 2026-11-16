import SwiftUI

/// A `SecureField` for a key that is saved on commit (Return, leaving the field, or the view going away), not on
/// every keystroke: each save is a Keychain write.
struct CommitSecureField: View {
    let title: String
    @Binding var value: String
    @State private var draft = ""
    @State private var loaded = false
    @FocusState private var focused: Bool

    init(_ title: String, value: Binding<String>) { self.title = title; _value = value }

    var body: some View {
        SecureField(title, text: $draft, prompt: Text("Paste the key here"))
            .focused($focused)
            .onAppear { if !loaded { draft = value; loaded = true } }
            .onSubmit(commit)
            .onChange(of: focused) { f in if !f { commit() } }
            .onDisappear(perform: commit)
    }

    private func commit() {
        let v = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if v != value { value = v }
    }
}
