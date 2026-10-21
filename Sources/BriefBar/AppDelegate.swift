import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model: AppModel

    init(demo: Bool) {
        model = AppModel(demo: demo)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu-bar app has no visible windows most of the time; don't let macOS reclaim it.
        ProcessInfo.processInfo.disableAutomaticTermination("Shows what needs you in the menu bar")
        model.launch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.terminate()
    }

    /// Opening the app again (Finder, Spotlight, `open`) shows the first list, or Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.reopen()
        return false
    }
}
