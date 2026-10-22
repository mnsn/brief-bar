import BriefBarCore
import Darwin
import Testing
@testable import BriefBarUI

/// The command-line modes and `--render` print or save what they read, so they run only with the permissions of the
/// app that started BriefBar: never with its own Full Disk Access, which whoever started it would get the use of.
@Suite struct CommandLineAccessTests {
    private let pid: pid_t = 500
    private let briefBar = "/Applications/BriefBar.app/Contents/MacOS/BriefBar"

    private func refusal(_ responsible: Attribution.Responsible?) -> String? {
        CommandLineAccess.refusal(Attribution(pid: pid, executable: briefBar, responsible: responsible))
    }

    @Test func runFromAShell() {
        #expect(refusal(.init(pid: 400, path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")) == nil)
        #expect(refusal(.init(pid: pid, path: "/Applications/GitHub Copilot.app/Contents/MacOS/github")) == nil)
    }

    @Test func refusedWithItsOwnPermissions() throws {
        // `open -n -g --stdout out.txt BriefBar.app --args --json`, or a program that disclaimed it.
        let message = try #require(refusal(.init(pid: pid, path: briefBar)))
        #expect(message.contains("Terminal"))
        #expect(refusal(nil) != nil)
    }
}
