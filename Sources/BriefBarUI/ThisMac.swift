import AppKit
import MachO
import ServiceManagement
import SwiftUI
import Synchronization

/// What BriefBar does on your Mac beyond its own windows and files: opening a link, a file, an app or System Settings,
/// bringing another app forward, showing files in the Finder, putting text on the clipboard, asking in an alert or a
/// panel, and beeping; and, for SwiftUI's links, `link(to:label:)` and `opensLinksThroughThisMac()`. All of BriefBar
/// does these through here, and only here, since tests run BriefBar's code on your Mac: in a test process, each is
/// refused, whether or not the test stands in for it, and noted for the test (`noting`). So no test opens a session in
/// the Copilot app, a page in your browser or a script in Terminal, brings up an app, replaces what you copied, waits
/// on an alert that nobody answers, or beeps. `scripts/check-boundaries.sh` checks that no other code does any of them,
/// by the calls the compiled code makes, whatever it's spelled like.
package enum ThisMac {
    /// Whether this process runs tests: whatever runs them, xctest or swiftpm-testing-helper, they're in a test bundle,
    /// as `swift test` builds them. The app and its command line never load one.
    package static let runsTests: Bool = {
        let name = ProcessInfo.processInfo.processName
        if name == "xctest" || name == "swiftpm-testing-helper" { return true }
        return (0..<_dyld_image_count()).contains { index in
            _dyld_get_image_name(index).map { String(cString: $0).contains(".xctest/") } ?? false
        }
    }()

    /// What a test process refused, for the test that did it: what its task, and any task it started, did.
    @TaskLocal package static var noting: Notes?

    /// What a test process refused: "open <link>", "open <app>", "open Login Items in System Settings",
    /// "activate <app>", "show <files> in the Finder", "open <folder> in the Finder", "copy <text>", "ask <alert's
    /// message>", "beep", oldest first.
    package final class Notes: Sendable {
        private let list = Mutex<[String]>([])

        package init() {}

        package var refused: [String] { list.withLock { $0 } }

        fileprivate func add(_ what: String) {
            list.withLock { $0.append(what) }
        }
    }

    /// Opens a link, a page or a file, in the app that opens it: false when nothing opened it, as in a test.
    @discardableResult
    package static func open(_ url: URL) -> Bool {
        guard !refuses("open \(url.absoluteString)") else { return false }
        return NSWorkspace.shared.open(url)
    }

    /// Opens links in an app.
    package static func open(_ urls: [URL], with app: URL, configuration: NSWorkspace.OpenConfiguration) {
        guard !refuses("open \(urls.map(\.absoluteString).joined(separator: " ")) with \(app.lastPathComponent)") else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration)
    }

    /// Opens an app, or brings it to the front.
    package static func openApplication(at app: URL, configuration: NSWorkspace.OpenConfiguration) {
        guard !refuses("open \(app.lastPathComponent)") else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: configuration)
    }

    /// Opens Login Items in System Settings, where you allow BriefBar to open at login.
    package static func openLoginItemsSettings() {
        guard !refuses("open Login Items in System Settings") else { return }
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Brings another app forward, as `app.activate(from:options:)` does, taking over from `other`: false when it didn't,
    /// as in a test.
    @discardableResult
    package static func activate(
        _ app: NSRunningApplication, from other: NSRunningApplication, options: NSApplication.ActivationOptions = []
    ) -> Bool {
        guard !refuses("activate \(app.bundleIdentifier ?? app.localizedName ?? "an app")") else { return false }
        return app.activate(from: other, options: options)
    }

    /// Shows files in the Finder, selected.
    package static func showInFinder(_ files: [URL]) {
        guard !refuses("show \(files.map(\.path).joined(separator: " ")) in the Finder") else { return }
        NSWorkspace.shared.activateFileViewerSelecting(files)
    }

    /// Opens a folder in the Finder, in a window that shows what's in it: never opens the folder itself in an app, as an
    /// app's bundle would be.
    package static func openInFinder(_ folder: URL) {
        guard !refuses("open \(folder.path) in the Finder") else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
    }

    /// Puts text on the clipboard, in place of what you copied.
    package static func copy(_ text: String) {
        guard !refuses("copy \(text)") else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Asks in an alert, and waits for your answer. In a test, which nobody answers, it's as if you closed it unanswered:
    /// `.abort`, which no alert of BriefBar's goes on with.
    @MainActor @discardableResult
    package static func ask(_ alert: NSAlert) -> NSApplication.ModalResponse {
        guard !refuses("ask \(alert.messageText)") else { return .abort }
        return alert.runModal()
    }

    /// Asks in a panel, such as one to choose a folder, and waits for your answer: in a test, as if you canceled it.
    @MainActor @discardableResult
    package static func ask(_ panel: NSSavePanel) -> NSApplication.ModalResponse {
        guard !refuses("ask \(panel.message ?? "")") else { return .cancel }
        return panel.runModal()
    }

    /// Beeps, as the Mac does for what it can't do: a key that can't do what it asks, such as a move the Board refuses.
    package static func beep() {
        guard !refuses("beep") else { return }
        NSSound.beep()
    }

    /// A link to a page or a file, SwiftUI's `Link`, that opens through `open` (`opensLinksThroughThisMac`).
    @MainActor
    package static func link<Label: View>(to url: URL, @ViewBuilder label: () -> Label) -> some View {
        Link(destination: url, label: label).opensLinksThroughThisMac()
    }

    /// What SwiftUI opens a link with, `Link`'s and one in text (`AttributedString`'s `link`) alike: `open`.
    fileprivate static var openURL: OpenURLAction {
        OpenURLAction { url in open(url) ? .handled : .discarded }
    }

    /// Whether to refuse it: in a test process, noting it for the test.
    private static func refuses(_ what: @autoclosure () -> String) -> Bool {
        guard runsTests else { return false }
        noting?.add(what())
        return true
    }
}

extension View {
    /// Opens the links in this view through `ThisMac.open`, rather than as SwiftUI would by itself: `Link`s, and links in
    /// its text, such as a comment's. A view that shows links in text has this, as `RichTextView` does; a `Link` is made
    /// with `ThisMac.link(to:label:)`, which has it.
    package func opensLinksThroughThisMac() -> some View {
        environment(\.openURL, ThisMac.openURL)
    }
}
