// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BriefBar",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "BriefBar", targets: ["BriefBar"]),
        .executable(name: "BriefBarUpdater", targets: ["BriefBarUpdater"]),
    ],
    dependencies: [
        // In-app updates. Only the updater uses it; the app, the sources and the tests don't.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        // Shared by every source, with no UI: watching files, reading SQLite, timestamps, starting
        // programs, and which sources are on and where they show in the menu bar.
        .target(
            name: "BriefBarCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // Notification Center's database: the notifications of the apps a source asks for, or of every app.
        // Reading it needs Full Disk Access. Teams uses it, and so do Azure DevOps' pull requests sent in
        // chats; Outlook could.
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
        // the network (scripts/check-boundaries.sh).
        .target(
            name: "AzureDevOpsCore",
            dependencies: ["BriefBarCore", "NotificationCenterDB"]
        ),
        // GitHub Copilot app sessions, from the app's database and each agent's event log in ~/.copilot.
        .target(
            name: "CopilotCore",
            dependencies: ["BriefBarCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // Sending a work item to the Copilot CLI, only when you choose to: its prompt, a git worktree, the run, and
        // how it went, from its session log.
        .target(
            name: "CopilotTasks",
            dependencies: ["BriefBarCore", "CopilotCore"]
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
            dependencies: ["BriefBarCore", "BriefBarUI", "NotificationCenterDB", "AzureDevOpsCore", "CopilotTasks"]
        ),
        .target(
            name: "CopilotUI",
            dependencies: ["BriefBarCore", "BriefBarUI", "CopilotCore"]
        ),
        // The app: its sources, the menu-bar items, Settings and the command line. It loads no library but
        // Apple's, so it keeps library validation on, and starts the updater for in-app updates.
        .executableTarget(
            name: "BriefBar",
            dependencies: ["BriefBarCore", "BriefBarUI", "TeamsUI", "AzureDevOpsUI", "CopilotUI"]
        ),
        // The updater: Sparkle, in a helper app inside BriefBar.app, with library validation off and none of
        // BriefBar's privacy permissions (see Sources/BriefBarUpdater/UpdaterController.swift).
        // scripts/build-app.sh embeds Sparkle.framework in the helper's Contents/Frameworks.
        .executableTarget(
            name: "BriefBarUpdater",
            dependencies: ["BriefBarCore", .product(name: "Sparkle", package: "Sparkle")],
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
            dependencies: ["AzureDevOpsCore", "NotificationCenterDB", "BriefBarCore"]
        ),
        .testTarget(
            name: "CopilotCoreTests",
            dependencies: ["CopilotCore", "BriefBarCore"]
        ),
        .testTarget(
            name: "CopilotTasksTests",
            dependencies: ["CopilotTasks", "CopilotCore", "BriefBarCore"]
        ),
        .testTarget(
            name: "TeamsUITests",
            dependencies: ["TeamsUI", "TeamsCore", "NotificationCenterDB", "BriefBarUI"]
        ),
        .testTarget(
            name: "AzureDevOpsUITests",
            dependencies: ["AzureDevOpsUI", "AzureDevOpsCore", "BriefBarUI", "BriefBarCore", "CopilotTasks"]
        ),
    ]
)
