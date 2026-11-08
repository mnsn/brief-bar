import AppKit
import BriefBarUI
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
        await ThisMac.$noting.withValue(notes) {
            #expect(!ThisMac.open(session))
            ThisMac.open([session], with: terminal, configuration: NSWorkspace.OpenConfiguration())
            ThisMac.openApplication(at: terminal, configuration: NSWorkspace.OpenConfiguration())
            ThisMac.showInFinder([terminal])
            ThisMac.copy("Fix the comments")
            #expect(ThisMac.ask(alert) == .abort)
            await Task { ThisMac.copy("Push and reply") }.value
        }
        #expect(notes.refused == [
            "open \(session.absoluteString)", "open \(session.absoluteString) with Terminal.app", "open Terminal.app",
            "show \(terminal.path) in the Finder", "copy Fix the comments", "ask Remove the worktree?", "copy Push and reply",
        ])
        // What's done after, outside the test's scope, isn't noted for it.
        ThisMac.copy("Nothing")
        #expect(notes.refused.count == 7)
    }
}
