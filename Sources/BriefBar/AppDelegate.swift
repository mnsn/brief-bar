import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model: AppModel
    private let mainMenu: MainMenu
    private let updater: Updater
    private let demo: Bool
    private let opensWindow: Bool

    /// - Parameter openWindow: opens the window once the app has started (`--window`).
    init(demo: Bool, openWindow: Bool = false) {
        model = AppModel(demo: demo)
        mainMenu = MainMenu(model: model)
        updater = Updater(status: model.services.updates)
        self.demo = demo
        opensWindow = openWindow
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu-bar app has no visible windows most of the time; don't let macOS reclaim it.
        ProcessInfo.processInfo.disableAutomaticTermination("Shows what needs you in the menu bar")
        NSApp.mainMenu = mainMenu.make()
        model.launch()
        if opensWindow {
            model.openWindow(at: nil)
        }
        // Only the app checks for updates: never the demo, which makes no network requests, the command-line
        // modes or --render (see main.swift).
        if !demo {
            updater.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.terminate()
    }

    /// Opening the app again (Finder, Spotlight, `open`) shows the first list, or Settings. With a window or Settings
    /// open, clicking the Dock icon brings it forward, as for any app.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // A click on a notification brings BriefBar to the front this way too: what it's about opens instead, in front.
        if model.services.notifier.handleReopen() {
            return false
        }
        if model.hasOpenWindow {
            return true
        }
        model.reopen()
        return false
    }
}
