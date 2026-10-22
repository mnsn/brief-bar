import BriefBarCore
import CopilotCore
import Foundation
import Testing
@testable import CopilotTasks

@Suite struct RunStatusTests {
    private func log(_ lines: [String]) -> SessionLogState {
        var state = SessionLogState()
        state.apply(lines.compactMap(EventLineParser.parse))
        return state
    }

    private var working: SessionLogState {
        log([Line.userMessage(), Line.toolStart("bash", id: "c1", description: "Build the solution", at: 5)])
    }

    @Test func worksWhileItsProcessRuns() {
        let status = RunStatus.derive(log: working, isRunning: true, exitStatus: nil, stoppedByYou: false, output: nil)
        #expect(status.phase == .working)
        #expect(status.detail == "Build the solution")
        // Before Copilot has written its log.
        #expect(RunStatus.derive(log: nil, isRunning: true, exitStatus: nil, stoppedByYou: false, output: nil).phase == .working)
    }

    /// In autopilot, Copilot goes on after a turn that looks like its last, and after an error: while its process
    /// runs, it's working whatever its log says.
    @Test func keepsWorkingWhileItsProcessRunsWhateverTheLogSays() {
        let paused = log([Line.userMessage(), Line.message("Done with the change", at: 5), Line.event("assistant.turn_end", at: 6)])
        #expect(paused.phase == .finished)
        let erred = log([Line.userMessage(), Line.event("session.error", data: ["errorType": "rate_limit", "message": "Slow down"], at: 9)])
        #expect(erred.phase == .failed)
        for state in [paused, erred] {
            #expect(RunStatus.derive(log: state, isRunning: true, exitStatus: nil, stoppedByYou: false, output: nil) == RunStatus(phase: .working))
        }
    }

    /// Once its process is gone, the log says how it ended.
    @Test func endsAsTheLogSays() {
        let done = log([Line.userMessage(), Line.taskComplete("Opened a pull request", at: 30)])
        let status = RunStatus.derive(log: done, isRunning: false, exitStatus: nil, stoppedByYou: false, output: nil)
        #expect(status.phase == .finished)
        #expect(status.detail == "Opened a pull request")
        let failed = log([Line.userMessage(), Line.event("session.error", data: ["errorType": "quota", "message": "Out of credits"], at: 9)])
        #expect(RunStatus.derive(log: failed, isRunning: false, exitStatus: 1, stoppedByYou: false, output: nil)
                == RunStatus(phase: .failed, since: failed.phaseSince, detail: "Out of credits"))
        let aborted = log([Line.userMessage(), Line.event("abort", data: ["reason": "user"], at: 9)])
        #expect(RunStatus.derive(log: aborted, isRunning: false, exitStatus: nil, stoppedByYou: false, output: nil).phase == .stopped)
    }

    @Test func endsByHowItsProcessEndedWhenTheLogDoesnt() {
        #expect(RunStatus.derive(log: working, isRunning: false, exitStatus: nil, stoppedByYou: true, output: nil).phase == .stopped)
        #expect(RunStatus.derive(log: working, isRunning: false, exitStatus: 0, stoppedByYou: false, output: nil).phase == .finished)
        let crashed = RunStatus.derive(log: working, isRunning: false, exitStatus: 1, stoppedByYou: false, output: "\nError: model not available\n\n")
        #expect(crashed.phase == .failed)
        #expect(crashed.detail == "Error: model not available")
        // Ended while BriefBar wasn't running, so nobody saw how.
        #expect(RunStatus.derive(log: working, isRunning: false, exitStatus: nil, stoppedByYou: false, output: nil).phase == .stopped)
    }

    @Test func failsWhenCopilotNeverStartedWorking() {
        let status = RunStatus.derive(log: nil, isRunning: false, exitStatus: 1, stoppedByYou: false, output: "error: unknown option '--autopilot'\n")
        #expect(status == RunStatus(phase: .failed, detail: "error: unknown option '--autopilot'"))
        #expect(RunStatus.derive(log: nil, isRunning: false, exitStatus: 2, stoppedByYou: false, output: "")
                .detail == "Copilot exited with status 2 before it started working.")
        #expect(RunStatus.derive(log: nil, isRunning: false, exitStatus: nil, stoppedByYou: false, output: nil)
                .detail == "Copilot ended before it started working.")
    }
}

@Suite struct RunTranscriptTests {
    @Test func findsTheLastPullRequestLink() {
        let text = """
            Looked at https://dev.azure.com/contoso/Storefront/_git/web/pullrequest/12 first.
            Opened [the pull request](https://dev.azure.com/contoso/Storefront/_git/web/pullrequest/77).
            """
        #expect(RunTranscript.pullRequest(in: text)?.absoluteString == "https://dev.azure.com/contoso/Storefront/_git/web/pullrequest/77")
        #expect(RunTranscript.pullRequest(in: "See https://contoso.visualstudio.com/DefaultCollection/Storefront/_git/web/pullRequest/9, thanks")?
            .absoluteString == "https://contoso.visualstudio.com/DefaultCollection/Storefront/_git/web/pullRequest/9")
        #expect(RunTranscript.pullRequest(in: "https://github.com/contoso/web/pull/5.")?.absoluteString == "https://github.com/contoso/web/pull/5")
        #expect(RunTranscript.pullRequest(in: "https://dev.azure.com/contoso/Storefront/_workitems/edit/4217") == nil)
        #expect(RunTranscript.pullRequest(in: "No link here") == nil)
    }

    /// The summary it called the task done with, and its own last message, not a subagent's.
    @Test func readsCopilotsLastWords() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = folder.appendingPathComponent("events.jsonl")
        let lines = [
            Line.userMessage(),
            Line.message("Working on it", at: 1),
            Line.taskComplete("Opened https://dev.azure.com/contoso/Storefront/_git/web/pullrequest/77", at: 20),
            Line.message("Done: pull request 77 is ready for review.", at: 21),
            Line.message("A subagent's report", subagent: true, at: 22),
            Line.event("session.shutdown", data: ["shutdownType": "routine"], at: 23),
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: events, atomically: true, encoding: .utf8)
        let words = RunTranscript.lastWords(events: events)
        #expect(words.summary == "Opened https://dev.azure.com/contoso/Storefront/_git/web/pullrequest/77")
        #expect(words.message == "Done: pull request 77 is ready for review.")
        let missing = RunTranscript.lastWords(events: folder.appendingPathComponent("missing.jsonl"))
        #expect(missing.summary == nil && missing.message == nil)
    }

    @Test func followsARunsLogAsItGrows() async throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = folder.appendingPathComponent("events.jsonl")
        let monitor = RunMonitor()
        #expect(await monitor.log(id: "s1", events: events) == nil)
        try (Line.userMessage() + "\n").write(to: events, atomically: false, encoding: .utf8)
        #expect(await monitor.log(id: "s1", events: events)?.phase == .running)
        let handle = try FileHandle(forWritingTo: events)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((Line.taskComplete("Done", at: 9) + "\n").utf8))
        try handle.close()
        #expect(await monitor.log(id: "s1", events: events)?.phase == .finished)
    }

    /// A run's files are in folders any program running as you can write to, and BriefBar may have Full Disk Access:
    /// a link there could point it at any file, so none is followed.
    @Test func followsNoLinkToAnotherFile() async throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let secret = folder.appendingPathComponent("secret.txt")
        try (Line.taskComplete("https://dev.azure.com/contoso/Storefront/_git/web/pullrequest/1", at: 1) + "\n")
            .write(to: secret, atomically: true, encoding: .utf8)
        let link = folder.appendingPathComponent("events.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)

        #expect(LocalFile.isLink(link))
        #expect(LocalFile.tail(of: link, maxBytes: 1_024) == nil)
        #expect(LocalFile.tail(of: folder, maxBytes: 1_024) == nil)
        #expect(LocalFile.tail(of: secret, maxBytes: 8)?.count == 8)
        let words = RunTranscript.lastWords(events: link)
        #expect(words.summary == nil && words.message == nil)
        #expect(await RunMonitor().log(id: "s1", events: link) == nil)
    }

    /// A run keeps only its session's ID; its files follow from it, so the preferences can't point BriefBar elsewhere.
    @Test func findsARunsFilesFromItsSessionsID() {
        let id = "9d59036c-4479-437f-b4b5-20cccc53e849"
        var run = CopilotRun(
            id: id, workItem: sampleItem.reference, options: CopilotModel.standard, repository: URL(fileURLWithPath: "/r"),
            worktree: URL(fileURLWithPath: "/w"), startedAt: Date(), process: DetachedProgram.Handle(pid: 0, startedAt: nil)
        )
        #expect(run.isValid)
        #expect(run.events(in: URL(fileURLWithPath: "/Users/robin/.copilot")).path == "/Users/robin/.copilot/session-state/\(id)/events.jsonl")
        #expect(run.output(in: URL(fileURLWithPath: "/out")).path == "/out/\(id).log")
        for invalid in ["../../Library/Messages/chat", id.uppercased(), "s1", ""] {
            run.id = invalid
            #expect(!run.isValid, "\(invalid)")
        }
    }
}
