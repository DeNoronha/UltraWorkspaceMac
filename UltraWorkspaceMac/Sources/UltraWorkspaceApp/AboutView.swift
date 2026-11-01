import SwiftUI
import AppKit

/// About panel: version, author, license, repository and contact.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private static let repoURL = URL(string: "https://github.com/DeNoronha/UltraWorkspaceMac")!
    private static let contactEmail = "ramon@denoronha.nl"

    private var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "UltraWorkspace for Mac"
    }
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return build == short ? "Version \(short)" : "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon).resizable().frame(width: 84, height: 84)
            } else {
                Image(systemName: "rectangle.on.rectangle.angled").font(.system(size: 64)).foregroundStyle(.secondary)
            }

            VStack(spacing: 3) {
                Text(appName).font(.title2).bold()
                Text(version).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }

            Text("A native macOS client for the UltraBar X — discover and pair your CoreBar, control its modules, and publish live widgets to a VivoCube.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)

            Divider().frame(width: 320)

            VStack(alignment: .leading, spacing: 8) {
                row("Author", value: "Ramon de Noronha")
                HStack(spacing: 6) {
                    Text("Repository").frame(width: 92, alignment: .leading).foregroundStyle(.secondary)
                    Link("github.com/DeNoronha/UltraWorkspaceMac", destination: Self.repoURL)
                }
                HStack(spacing: 6) {
                    Text("Contact").frame(width: 92, alignment: .leading).foregroundStyle(.secondary)
                    Link(Self.contactEmail, destination: URL(string: "mailto:\(Self.contactEmail)")!)
                }
                row("License", value: "MIT")
                row("Built with", value: "Swift 6 · SwiftUI")
            }
            .font(.callout)
            .frame(width: 340, alignment: .leading)

            Divider().frame(width: 320)

            Text("© 2026 Ramon de Noronha. Released under the MIT License.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text("Unofficial client — not affiliated with or endorsed by the UltraBar X hardware vendor.")
                .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 360)

            HStack {
                Button("View on GitHub") { NSWorkspace.shared.open(Self.repoURL) }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(.top, 2)
        }
        .padding(28)
        .frame(width: 420)
    }

    private func row(_ label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).frame(width: 92, alignment: .leading).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
