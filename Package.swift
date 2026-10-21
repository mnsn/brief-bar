// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BriefBar",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "BriefBar", targets: ["BriefBar"]),
    ],
    targets: [
        // Shared by every source, with no UI: watching files, reading SQLite, timestamps, starting
        // programs, and which sources are on and where they show in the menu bar.
        .target(
            name: "BriefBarCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // GitHub Copilot app sessions, from the app's database and each agent's event log in ~/.copilot.
        .target(
            name: "CopilotCore",
            dependencies: ["BriefBarCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // Shared by every source's app code: the source protocol, menu-bar drawing, widgets,
        // notifications, Full Disk Access and the gear menu's own items.
        .target(
            name: "BriefBarUI",
            dependencies: ["BriefBarCore"]
        ),
        // Each source's app code: its lists, settings, widget and command-line modes.
        .target(
            name: "CopilotUI",
            dependencies: ["BriefBarCore", "BriefBarUI", "CopilotCore"]
        ),
        // The app: its sources, the menu-bar items, Settings and the command line.
        .executableTarget(
            name: "BriefBar",
            dependencies: ["BriefBarCore", "BriefBarUI", "CopilotUI"]
        ),
        .testTarget(
            name: "BriefBarCoreTests",
            dependencies: ["BriefBarCore"]
        ),
        .testTarget(
            name: "CopilotCoreTests",
            dependencies: ["CopilotCore", "BriefBarCore"]
        ),
    ]
)
