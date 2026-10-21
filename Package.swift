// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BriefBar",
    platforms: [.macOS(.v15)],
    targets: [
        // Shared by every source, with no UI: watching files, reading SQLite, timestamps, starting
        // programs, and which sources are on and where they show in the menu bar.
        .target(
            name: "BriefBarCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "BriefBarCoreTests",
            dependencies: ["BriefBarCore"]
        ),
    ]
)
