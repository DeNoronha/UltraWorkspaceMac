import SwiftUI

/// Whether a saved credential works, as far as Deckhand knows: the service accepted it, turned it down (the reason is
/// on the status line under the rows), or it has not been used yet.
enum CredentialStatus: Equatable {
    case unchecked, working, failed

    /// From a feed's last error and whether it has read anything with the credential.
    static func from(error: String?, working: Bool) -> CredentialStatus {
        error != nil ? .failed : working ? .working : .unchecked
    }
}

/// One credential (API key, client ID, client secret, token, password) as a row: a status mark, the name, the value
/// masked to its last four characters (identifiers such as a client ID shown in full), and a pencil to edit it and a
/// bin to remove it. A missing credential says so in red, one the service turned down gets a red warning, one that
/// works a green tick. Editing happens in a sheet and is saved once, on Save, so the Keychain is written once.
struct CredentialRow: View {
    let title: String
    @Binding var value: String
    var secret = true
    var prompt = "Paste it here"
    /// Optional credentials are grey, not red, while they are not set.
    var optional = false
    var status: CredentialStatus = .unchecked
    /// Called after Save or Remove changed the value.
    var onChange: (() -> Void)? = nil

    @State private var editing = false
    @State private var confirmRemove = false

    init(_ title: String, value: Binding<String>, secret: Bool = true, prompt: String = "Paste it here",
         optional: Bool = false, status: CredentialStatus = .unchecked, onChange: (() -> Void)? = nil) {
        self.title = title; _value = value; self.secret = secret; self.prompt = prompt
        self.optional = optional; self.status = status; self.onChange = onChange
    }

    private var trimmed: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isEmpty: Bool { trimmed.isEmpty }

    var body: some View {
        HStack(spacing: 10) {
            mark.frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                detail
            }
            Spacer(minLength: 12)
            if isEmpty {
                Button("Add…") { editing = true }
            } else {
                Button { editing = true } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help("Edit \(title)")
                    .accessibilityLabel("Edit \(title)")
                Button { confirmRemove = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Remove \(title)")
                    .accessibilityLabel("Remove \(title)")
            }
        }
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $editing) {
            CredentialEditor(title: title, secret: secret, prompt: prompt, adding: isEmpty, initial: secret ? "" : trimmed) { new in
                value = new
                onChange?()
            }
        }
        .confirmationDialog("Remove the \(title.lowercased())?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { value = ""; onChange?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deckhand forgets it on this Mac. You can add it again at any time.")
        }
    }

    @ViewBuilder private var mark: some View {
        if isEmpty {
            if optional { Image(systemName: "circle.dashed").foregroundStyle(.secondary).accessibilityLabel("Not set") }
            else { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).accessibilityLabel("Missing") }
        } else {
            switch status {
            case .working: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Works")
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).accessibilityLabel("Not accepted")
            case .unchecked: Image(systemName: "key.fill").foregroundStyle(.secondary).accessibilityLabel("Saved")
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if isEmpty {
            Text(optional ? "Not set" : "Missing")
                .font(.callout)
                .foregroundStyle(optional ? Color.secondary : Color.red)
        } else {
            HStack(spacing: 6) {
                Text(masked)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.disabled)
                if status == .failed { Text("Not accepted").font(.callout).foregroundStyle(.red) }
            }
        }
    }

    /// A secret shows only its last four characters, and only when it is long enough that they give nothing away.
    private var masked: String {
        guard secret else { return trimmed }
        return trimmed.count >= 12 ? "••••••••" + trimmed.suffix(4) : "••••••••"
    }
}

/// The sheet behind the pencil: one field, Cancel and Save. A secret starts empty (paste the new one) and can be shown
/// while typing; an identifier starts with its current value.
private struct CredentialEditor: View {
    let title: String
    let secret: Bool
    let prompt: String
    let adding: Bool
    let initial: String
    let save: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var reveal = false
    @FocusState private var focused: Bool

    private var cleaned: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(adding ? "Add \(title)" : "Edit \(title)").font(.headline)
            HStack(spacing: 8) {
                Group {
                    if secret && !reveal { SecureField(title, text: $draft, prompt: Text(prompt)) }
                    else { TextField(title, text: $draft, prompt: Text(prompt)) }
                }
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { if !cleaned.isEmpty { commit() } }
                if secret {
                    Button { reveal.toggle(); focused = true } label: { Image(systemName: reveal ? "eye.slash" : "eye") }
                        .buttonStyle(.borderless)
                        .help(reveal ? "Hide" : "Show")
                        .accessibilityLabel(reveal ? "Hide \(title)" : "Show \(title)")
                }
            }
            if secret && !adding {
                Text("Paste the new value; the saved one is replaced on Save.").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { commit() }.keyboardShortcut(.defaultAction).disabled(cleaned.isEmpty || cleaned == initial)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { draft = initial; focused = true }
    }

    private func commit() {
        save(cleaned)
        dismiss()
    }
}
