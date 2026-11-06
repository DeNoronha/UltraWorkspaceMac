// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UltraWorkspaceMac",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "UltraBarKit", targets: ["UltraBarKit"]),
        .executable(name: "UltraWorkspaceApp", targets: ["UltraWorkspaceApp"]),
    ],
    targets: [
        .target(name: "UltraBarKit"),
        .executableTarget(
            name: "UltraWorkspaceApp",
            dependencies: ["UltraBarKit"],
            // The bar apps' pages: built into each APK (android/DeckhandMonitor/app/build.gradle.kts), not used by the Mac app.
            exclude: ["Resources/pages"]
        ),
        .executableTarget(name: "kitcheck", dependencies: ["UltraBarKit"]),
    ]
)
