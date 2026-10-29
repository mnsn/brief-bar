import BriefBarCore
import Foundation
import Testing
@testable import CopilotCore

/// The Copilot app's runtime marks the sessions it has open with `inuse.<pid>.lock`: a turn the CLI runs in one of them
/// then is one the app never sees, so BriefBar's CLI runs keep out of them.
@Suite struct SessionLockTests {
    @Test func readsTheProcessFromTheLocksName() {
        #expect(SessionLock.pid(inLockNamed: "inuse.33057.lock") == 33057)
        for name in ["inuse.33057.hold", "inuse..lock", "inuse.-1.lock", "inuse.0.lock", "inuse.12a.lock", "events.jsonl",
                     "inuse.99999999999.lock", "xinuse.1.lock"] {
            #expect(SessionLock.pid(inLockNamed: name) == nil, "\(name)")
        }
    }

    @Test func isHeldOnlyByAProgramThatsStillRunning() throws {
        try withTemporaryDirectory { folder in
            #expect(!SessionLock.isHeld(sessionFolder: folder))
            // The app leaves a lock behind when it quits: that one doesn't count.
            try Data().write(to: folder.appendingPathComponent("inuse.4242.lock"))
            try Data().write(to: folder.appendingPathComponent("inuse.4242.hold"))
            #expect(!SessionLock.isHeld(sessionFolder: folder, isRunning: { _ in false }))
            #expect(SessionLock.isHeld(sessionFolder: folder, isRunning: { $0 == 4242 }, startTime: { _ in nil }))
            // This test's own process stands in for the app's.
            try Data("\(getpid())\n".utf8).write(to: folder.appendingPathComponent("inuse.\(getpid()).lock"))
            #expect(SessionLock.isHeld(sessionFolder: folder))
        }
        #expect(!SessionLock.isHeld(sessionFolder: URL(fileURLWithPath: "/nonexistent")))
    }

    /// Which program holds it, to bring up the terminal a Copilot CLI has it open in: only one that's still running.
    @Test func namesTheProgramThatHoldsIt() throws {
        try withTemporaryDirectory { folder in
            #expect(SessionLock.holder(sessionFolder: folder) == nil)
            try Data().write(to: folder.appendingPathComponent("inuse.4242.lock"))
            #expect(SessionLock.holder(sessionFolder: folder, isRunning: { _ in false }) == nil)
            #expect(SessionLock.holder(sessionFolder: folder, isRunning: { $0 == 4242 }, startTime: { _ in nil }) == 4242)
            try FileManager.default.removeItem(at: folder.appendingPathComponent("inuse.4242.lock"))
            try Data().write(to: folder.appendingPathComponent("inuse.\(getpid()).lock"))
            #expect(SessionLock.holder(sessionFolder: folder) == getpid())
        }
    }

    /// macOS reuses process IDs: a lock whose process ID belongs to a program that started after the lock was written was
    /// left by one that's gone, and doesn't count.
    @Test func doesNotTakeAReusedProcessIDForTheLocksProgram() throws {
        try withTemporaryDirectory { folder in
            let lock = folder.appendingPathComponent("inuse.4242.lock")
            try Data("4242\n".utf8).write(to: lock)
            let written = Date(timeIntervalSince1970: 1_792_000_000)
            try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: lock.path)
            let running: (pid_t) -> Bool = { $0 == 4242 }
            // Started before the lock was written: it's the program that wrote it.
            #expect(SessionLock.isHeld(sessionFolder: folder, isRunning: running, startTime: { _ in written.addingTimeInterval(-60) }))
            // Started after: another program has its ID now.
            #expect(!SessionLock.isHeld(sessionFolder: folder, isRunning: running, startTime: { _ in written.addingTimeInterval(60) }))
            // Without its start time, it counts.
            #expect(SessionLock.isHeld(sessionFolder: folder, isRunning: running, startTime: { _ in nil }))
        }
        // This test's own process, which started before a lock it writes now, and after one written long ago.
        try withTemporaryDirectory { folder in
            let lock = folder.appendingPathComponent("inuse.\(getpid()).lock")
            try Data().write(to: lock)
            #expect(SessionLock.isHeld(sessionFolder: folder))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: lock.path)
            #expect(!SessionLock.isHeld(sessionFolder: folder))
        }
    }

    @Test func readsAValueFromASessionsWorkspace() {
        let text = """
            id: 5d2e8a90-1f3b-4e7c-8a26-7b9c0d4e5f02
            cwd: /Users/robin/dev/copilot-worktrees/checkout/fix-total
            git_root: '/Users/robin/dev/copilot-worktrees/checkout/fix-total'
            name: "Fix the checkout total"
            summary_count: 0
            """
        #expect(SessionStateScanner.value("cwd", inWorkspace: text) == "/Users/robin/dev/copilot-worktrees/checkout/fix-total")
        #expect(SessionStateScanner.value("git_root", inWorkspace: text) == "/Users/robin/dev/copilot-worktrees/checkout/fix-total")
        #expect(SessionStateScanner.value("name", inWorkspace: text) == "Fix the checkout total")
        #expect(SessionStateScanner.value("branch", inWorkspace: text) == nil)
        #expect(SessionStateScanner.value("cwd", inWorkspace: "cwd:\n") == nil)
    }
}
