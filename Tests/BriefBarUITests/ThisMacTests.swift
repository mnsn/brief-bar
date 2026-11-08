import AppKit
import BriefBarUI
import SwiftUI
import Testing

/// Tests run BriefBar's code on your Mac: there, `ThisMac` refuses what BriefBar does on it beyond its own windows, says
/// it didn't happen, and notes it for the test that did it, in its own task and the tasks it starts.
@MainActor
@Suite struct ThisMacTests {
    @Test func knowsItRunsTests() {
        #expect(ThisMac.runsTests)
    }

    @Test func refusesAndNotesWhatItWouldDoOnThisMac() async {
        let notes = ThisMac.Notes()
        let session = URL(string: "ghapp://sessions/\(UUID().uuidString.lowercased())")!
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app", isDirectory: true)
        let alert = NSAlert()
        alert.messageText = "Remove the worktree?"
        let itself = NSRunningApplication.current
        await ThisMac.$noting.withValue(notes) {
            #expect(!ThisMac.open(session))
            ThisMac.open([session], with: terminal, configuration: NSWorkspace.OpenConfiguration())
            ThisMac.openApplication(at: terminal, configuration: NSWorkspace.OpenConfiguration())
            ThisMac.openLoginItemsSettings()
            #expect(!ThisMac.activate(itself, from: itself))
            ThisMac.showInFinder([terminal])
            ThisMac.copy("Fix the comments")
            #expect(ThisMac.ask(alert) == .abort)
            ThisMac.beep()
            await Task { ThisMac.copy("Push and reply") }.value
        }
        #expect(notes.refused == [
            "open \(session.absoluteString)", "open \(session.absoluteString) with Terminal.app", "open Terminal.app",
            "open Login Items in System Settings", "activate \(itself.bundleIdentifier ?? itself.localizedName ?? "an app")",
            "show \(terminal.path) in the Finder", "copy Fix the comments", "ask Remove the worktree?", "beep",
            "copy Push and reply",
        ])
        // What's done after, outside the test's scope, isn't noted for it.
        ThisMac.copy("Nothing")
        #expect(notes.refused.count == 10)
    }

    /// SwiftUI's links open with what its environment says opens them (`openURL`): a `Link` that `link(to:label:)` makes,
    /// and links in the text of a view that has `opensLinksThroughThisMac()`, open through `ThisMac.open`, as what's there
    /// opens. Each is to a page no app opens, so that a link that went around ThisMac would open nothing either. (A test
    /// can't click one: SwiftUI builds no accessibility tree for VoiceOver's press while nothing like VoiceOver asks.)
    @Test func swiftUIsLinksOpenThroughThisMac() throws {
        let page = try #require(URL(string: "briefbar-tests-open-nothing:page"))
        let inText = try #require(URL(string: "briefbar-tests-open-nothing:text"))
        let inLink = Opener(), underIt = Opener()
        let host = NSHostingView(rootView: VStack {
            ThisMac.link(to: page) { Opener.Finding(opener: inLink) }
            Opener.Finding(opener: underIt).opensLinksThroughThisMac()
        }.fixedSize())
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 400, height: 200), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        let notes = ThisMac.Notes()
        ThisMac.$noting.withValue(notes) {
            inLink.openURL?(page)
            underIt.openURL?(inText)
        }
        #expect(notes.refused == ["open \(page.absoluteString)", "open \(inText.absoluteString)"])
    }

    /// What opens links where a view is, as SwiftUI's environment has it there, once the view's drawn.
    @MainActor
    private final class Opener {
        var openURL: OpenURLAction?

        struct Finding: View {
            let opener: Opener
            @Environment(\.openURL) private var openURL

            var body: some View {
                opener.openURL = openURL
                return Text("Open it")
            }
        }
    }
}
