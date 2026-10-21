import AppKit
import TeamsCore

/// Talking to the Microsoft Teams app.
@MainActor
enum TeamsApp {
    /// New Teams, then classic Teams.
    nonisolated static let bundleIdentifiers = TeamsBundle.identifiers

    static var applicationURL: URL? {
        bundleIdentifiers.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    /// The running Teams, new Teams first.
    static var runningApplication: NSRunningApplication? {
        bundleIdentifiers.lazy.compactMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }.first
    }

    /// Opens a chat link in Teams itself, so a browser never handles it. Without a link, just brings Teams up.
    static func open(_ link: URL?) {
        guard let link else {
            activate()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let applicationURL {
            NSWorkspace.shared.open([link], withApplicationAt: applicationURL, configuration: configuration)
        } else {
            NSWorkspace.shared.open(link)
        }
    }

    static func activate() {
        guard let applicationURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
    }
}
