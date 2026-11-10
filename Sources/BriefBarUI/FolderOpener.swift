import AppKit
import BriefBarCore
import Combine

/// Opens a folder, such as the worktree a pull request's Copilot session works in, in an editor or a terminal on this Mac
/// or in the Finder, or copies its path, when you click. Of the apps BriefBar knows (`FolderApps`), it offers those
/// LaunchServices finds, looked for as they're first wanted and again each time BriefBar comes to the front; and a folder
/// opens in the one you opened one in last, kept in the preferences by its bundle identifier (`chosenKey`). The demo has
/// VS Code and Terminal, made up, and opens nothing.
@MainActor
package final class FolderOpener: ObservableObject {
    package static let chosenKey = "folders.openWith"

    /// The known apps on this Mac, editors first, as found last: none until they're first wanted (`lookForApps`).
    @Published package private(set) var installed: [FolderApp] = []
    /// The app you opened a folder in last, while BriefBar knows it.
    @Published package private(set) var chosen: String?

    private let defaults: UserDefaults
    private let isDemo: Bool
    /// Where an app is on this Mac, by its bundle identifier: LaunchServices', or a test's.
    private let locate: (String) -> URL?
    private var hasLooked = false
    private var activations: AnyCancellable?

    /// The demo's, made up: what it shows wherever it's drawn.
    static let demoApps = ["com.microsoft.VSCode", "com.apple.Terminal"].compactMap(FolderApps.app(withID:))

    package init(defaults: UserDefaults, isDemo: Bool, locate: ((String) -> URL?)? = nil) {
        self.defaults = defaults
        self.isDemo = isDemo
        self.locate = locate ?? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        chosen = FolderApps.app(withID: defaults.string(forKey: Self.chosenKey))?.id
    }

    /// The app a folder opens in: the one you opened one in last, while it's here, or else the first editor, or else the
    /// first terminal (`FolderApps.preferred`).
    package var preferred: FolderApp? {
        FolderApps.preferred(chosen: chosen, among: installed)
    }

    /// Looks for the apps the first time they're wanted, and from then on each time BriefBar comes to the front, for one
    /// installed or removed meanwhile.
    package func lookForApps() {
        guard !hasLooked else { return }
        hasLooked = true
        lookAgain()
        activations = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.lookAgain() } }
    }

    private func lookAgain() {
        let found = isDemo ? Self.demoApps : FolderApps.installed { locate($0) != nil }
        if found != installed { installed = found }
    }

    /// Opens the folder in the app, which folders open in from then on. Nothing opens, but a beep, once the folder or the
    /// app is gone.
    package func open(_ folder: URL, in app: FolderApp) {
        if chosen != app.id {
            chosen = app.id
            defaults.set(app.id, forKey: Self.chosenKey)
        }
        guard !isDemo else { return }
        guard Self.isFolder(folder), let location = locate(app.id) else {
            lookAgain()
            ThisMac.beep()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        ThisMac.open([folder], with: location, configuration: configuration)
    }

    /// Opens the folder in the Finder, in a window that shows what's in it.
    package func openInFinder(_ folder: URL) {
        guard !isDemo else { return }
        guard Self.isFolder(folder) else {
            ThisMac.beep()
            return
        }
        ThisMac.openInFinder(folder)
    }

    /// Puts the folder's path on the clipboard.
    package func copyPath(_ folder: URL) {
        ThisMac.copy(folder.path)
    }

    private static func isFolder(_ url: URL) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue
    }
}
