import CopilotCore
import Foundation
import Testing
@testable import CopilotTasks

/// A prompt sent to one of the Copilot app's sessions, which BriefBar doesn't run: what became of it is what the session's
/// log says from when it was sent, never the history before.
@Suite struct SessionTurnTests {
    private func log(_ lines: [String]) -> SessionLogState {
        var state = SessionLogState()
        state.apply(lines.compactMap(EventLineParser.parse))
        return state
    }

    private func at(_ seconds: Int) -> Date {
        Date(timeIntervalSince1970: 1_792_000_000 + TimeInterval(seconds))
    }

    /// An earlier turn, which finished before the prompt was sent at 100.
    private let earlier = [Line.userMessage(at: 0), Line.taskComplete("Added the backoff", at: 30)]

    @Test func waitsUntilTheSessionTakesItUp() {
        #expect(SessionTurn.of(sentAt: at(100), log: nil, isRunning: false, isOpen: false) == SessionTurn(phase: .waiting, since: at(100)))
        #expect(SessionTurn.of(sentAt: at(100), log: log(earlier), isRunning: false, isOpen: true).phase == .waiting)
    }

    /// A turn that ran as the prompt was sent, or copied for you to paste, is an earlier message's: its end isn't the
    /// prompt's, until the session gets a message since, the prompt itself as the earliest.
    @Test func aTurnUnderWayAsItWasSentIsntIts() {
        let running = [Line.userMessage(at: 50), Line.toolStart("bash", id: "c1", description: "Build", at: 60)]
        let endedSince = log(running + [Line.taskComplete("Built it", at: 130)])
        #expect(SessionTurn.of(sentAt: at(100), log: endedSince, isRunning: false, isOpen: true) == SessionTurn(phase: .waiting, since: at(100)))
        #expect(SessionTurn.of(sentAt: at(100), log: log(running), isRunning: true, isOpen: true).phase == .waiting)
        // Pasted once it ended: the turn it starts is the prompt's.
        let pasted = log(running + [Line.taskComplete("Built it", at: 130), Line.userMessage(at: 140), Line.taskComplete("Capped it", at: 170)])
        #expect(SessionTurn.of(sentAt: at(100), log: pasted, isRunning: false, isOpen: true)
            == SessionTurn(phase: .finished(summary: "Capped it"), since: at(170)))
        // Pasted while it ran, the turn takes it in, and its end is the prompt's too.
        let steered = log(running + [Line.userMessage(at: 110), Line.taskComplete("Built it and capped it", at: 150)])
        #expect(SessionTurn.of(sentAt: at(100), log: steered, isRunning: false, isOpen: true).phase == .finished(summary: "Built it and capped it"))
    }

    @Test func worksWhileATurnRunsAndEndsAsTheLogSays() {
        let working = log(earlier + [Line.userMessage(at: 110), Line.toolStart("bash", id: "c1", description: "Run the tests", at: 120)])
        #expect(SessionTurn.of(sentAt: at(100), log: working, isRunning: true, isOpen: true)
            == SessionTurn(phase: .working(step: "Run the tests"), since: at(110)))
        // The app's flag can lag behind: a turn the log says runs, with the session open, works.
        #expect(SessionTurn.of(sentAt: at(100), log: working, isRunning: false, isOpen: true).phase == .working(step: "Run the tests"))
        // With neither, it was cut off.
        #expect(SessionTurn.of(sentAt: at(100), log: working, isRunning: false, isOpen: false) == SessionTurn(phase: .stopped, since: at(120)))
        let done = log(earlier + [Line.userMessage(at: 110), Line.taskComplete("Capped the backoff at 30 s", at: 150)])
        let finished = SessionTurn.of(sentAt: at(100), log: done, isRunning: false, isOpen: true)
        #expect(finished == SessionTurn(phase: .finished(summary: "Capped the backoff at 30 s"), since: at(150)))
        #expect(finished.isOver)
        let failed = log(earlier + [Line.userMessage(at: 110), Line.event("session.error", data: ["errorType": "quota", "message": "Out of credits"], at: 130)])
        #expect(SessionTurn.of(sentAt: at(100), log: failed, isRunning: false, isOpen: false).phase == .failed("Out of credits"))
        let aborted = log(earlier + [Line.userMessage(at: 110), Line.event("abort", data: ["reason": "user"], at: 130)])
        #expect(SessionTurn.of(sentAt: at(100), log: aborted, isRunning: false, isOpen: true).phase == .stopped)
    }

    /// While it asks you something, you answer it in the app.
    @Test func needsYouWhileItAsks() {
        let asking = log(earlier + [
            Line.userMessage(at: 110),
            Line.event("tool.execution_start", data: ["toolCallId": "q1", "toolName": "ask_user", "arguments": ["question": "Cap at 30 s or 60 s?"]], at: 115),
        ])
        let turn = SessionTurn.of(sentAt: at(100), log: asking, isRunning: true, isOpen: true)
        #expect(turn.phase == .needsYou)
        #expect(!turn.isOver)
    }
}
