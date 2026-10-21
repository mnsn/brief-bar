// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BriefBar",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "BriefBar", targets: ["BriefBar"]),
    ],
    dependencies: [
        // In-app updates. Only the app target uses it; the sources and the tests don't.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        // Shared by every source, with no UI: watching files, reading SQLite, timestamps, starting
        // programs, and which sources are on and where they show in the menu bar.
        .target(
            name: "BriefBarCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // Notification Center's database: the notifications of the apps a source asks for. Reading it
        // needs Full Disk Access. Teams uses it; Outlook could.
        .target(
            name: "NotificationCenterDB",
            dependencies: ["BriefBarCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // Unread Microsoft Teams chats, from the notifications Teams sends to Notification Center.
        .target(
            name: "TeamsCore",
            dependencies: ["BriefBarCore", "NotificationCenterDB"]
        ),
        // Azure DevOps pull requests, read with the Azure CLI's sign-in. The only module that may use
        // the network (scripts/check-networking.sh).
        .target(
            name: "AzureDevOpsCore",
            dependencies: ["BriefBarCore"]
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
            name: "TeamsUI",
            dependencies: ["BriefBarCore", "BriefBarUI", "NotificationCenterDB", "TeamsCore"]
        ),
        .target(
            name: "AzureDevOpsUI",
            dependencies: ["BriefBarCore", "BriefBarUI", "AzureDevOpsCore"]
        ),
        .target(
            name: "CopilotUI",
            dependencies: ["BriefBarCore", "BriefBarUI", "CopilotCore"]
        ),
        // The app: its sources, the menu-bar items, Settings and the command line.
        .executableTarget(
            name: "BriefBar",
            dependencies: [
                "BriefBarCore", "BriefBarUI", "TeamsUI", "AzureDevOpsUI", "CopilotUI",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            // scripts/build-app.sh embeds Sparkle.framework in the app's Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "BriefBarCoreTests",
            dependencies: ["BriefBarCore"]
        ),
        .testTarget(
            name: "BriefBarUITests",
            dependencies: ["BriefBarUI", "BriefBarCore"]
        ),
        .testTarget(
            name: "TeamsCoreTests",
            dependencies: ["TeamsCore", "NotificationCenterDB", "BriefBarCore"]
        ),
        .testTarget(
            name: "AzureDevOpsCoreTests",
            dependencies: ["AzureDevOpsCore", "BriefBarCore"]
        ),
        .testTarget(
            name: "CopilotCoreTests",
            dependencies: ["CopilotCore", "BriefBarCore"]
        ),
    ]
)
