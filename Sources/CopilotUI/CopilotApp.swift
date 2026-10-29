import AppKit
import CopilotCore

/// Talking to the GitHub Copilot desktop app.
@MainActor
enum CopilotApp {
    nonisolated static let bundleIdentifier = "com.github.githubapp"

    static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier
    }

    static var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    /// Whether the app is on this Mac: macOS knows it, or something else that opens its `ghapp://` links. Without it,
    /// nothing opens a session's link, and the sessions are the Copilot CLI's, which open in a terminal (`CLISession`).
    nonisolated static var isInstalled: Bool {
        let workspace = NSWorkspace.shared
        return workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
            || URL(string: "ghapp://sessions").flatMap { workspace.urlForApplication(toOpen: $0) } != nil
    }

    /// What to say couldn't be read: not the app's database on a Mac without the app, as with only the Copilot CLI,
    /// which keeps none, so there's none to read. With the app, whatever the engine says.
    nonisolated static func problem(of state: EngineSnapshot, isInstalled: () -> Bool = { CopilotApp.isInstalled }) -> String? {
        state.databaseMissing && !isInstalled() ? nil : state.problem
    }

    /// Opens a session or chat via the app's `ghapp://` deep link.
    static func open(sessionId: String) {
        guard let url = URL(string: "ghapp://sessions/\(sessionId)") else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let applicationURL {
            NSWorkspace.shared.open([url], withApplicationAt: applicationURL, configuration: configuration)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    static func activate() {
        guard let applicationURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
    }
}
