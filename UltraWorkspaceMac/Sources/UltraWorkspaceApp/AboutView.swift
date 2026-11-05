import SwiftUI
import AppKit

/// About panel: version, author, license, repository and contact.
struct AboutView: View {

    private static let repoURL = URL(string: "https://github.com/DeNoronha/UltraWorkspaceMac")!
    private static let contactEmail = "ramon@denoronha.nl"

    private var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Deckhand"
    }
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return build == short ? "Version \(short)" : "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 0) {
            Header("About Deckhand", "Version, source and license.")
            Divider()
            ScrollView { about.frame(maxWidth: .infinity) }
        }
    }
    private var about: some View {
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

            Text("A native macOS app for the UltraBar X — find and pair your CoreBar, put cards on the bar and on the VivoCube, install apps and screensavers, and see what the hardware is doing.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480)

            Divider().frame(width: 480)

            VStack(alignment: .leading, spacing: 8) {
                row("Author", value: "Ramon de Noronha")
                HStack(spacing: 6) {
                    Text("Repository").frame(width: 92, alignment: .leading).foregroundStyle(.secondary)
                    Link(Self.repoURL.absoluteString, destination: Self.repoURL).lineLimit(1).fixedSize()
                }
                HStack(spacing: 6) {
                    Text("Contact").frame(width: 92, alignment: .leading).foregroundStyle(.secondary)
                    Link(Self.contactEmail, destination: URL(string: "mailto:\(Self.contactEmail)")!).lineLimit(1).fixedSize()
                }
                row("License", value: "MIT")
                row("Built with", value: "Swift 6 · SwiftUI")
            }
            .font(.callout)
            .frame(width: 480, alignment: .leading)

            Divider().frame(width: 480)

            Text("© 2026 Ramon de Noronha. Released under the MIT License.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text("Independent, community software — not affiliated with or endorsed by Sanytron, the maker of UltraBar X.")
                .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 360)

            HStack {
                Button("View on GitHub") { NSWorkspace.shared.open(Self.repoURL) }
            }.padding(.top, 2)
        }
        .padding(28)
    }

    private func row(_ label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).frame(width: 92, alignment: .leading).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
