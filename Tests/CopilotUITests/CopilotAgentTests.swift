import BriefBarUI
import Foundation
import Testing
@testable import CopilotCore
@testable import CopilotUI

/// `--mcp`'s Copilot sessions, as agents read them.
@Suite struct CopilotAgentTests {
    private func session(
        _ id: String, name: String = "Add dark mode", project: String? = "shop-web", branch: String? = "dark-mode", isChat: Bool = false,
        phase: DisplayPhase = .needsYou, reason: StatusReason = .question, detail: String? = nil, choices: [String] = [], since: Date?
    ) -> SessionSnapshot {
        SessionSnapshot(
            id: id, name: name, projectName: project, branch: branch, isChat: isChat, mode: nil, phase: phase, reason: reason,
            headline: reason.headline, detail: detail, choices: choices, since: since
        )
    }

    @Test func describesWhatASessionAsksAndWhere() {
        let now = Date()
        let asking = session("abc", detail: "Should dark mode follow the system?", choices: ["Yes", "No"], since: now.addingTimeInterval(-120))
        #expect(CopilotAgent.line(asking, now: now) == """
            - “Add dark mode” (shop-web, dark-mode): Waiting for your answer, 2m ago. Should dark mode follow the system?
              Choices: Yes · No
              session abc
            """)
        let chat = session("c1", name: "", project: nil, branch: nil, isChat: true, phase: .running, reason: .working, since: now)
        #expect(CopilotAgent.line(chat, now: now) == "- “Untitled chat” (a chat): Working, just now\n  session c1")
    }

    @Test func saysWhereAQuestionAskedForAnotherSessionIsAnswered() {
        let now = Date()
        var coordinator = session("p1", name: "Release 2.5", project: nil, branch: nil, isChat: true, detail: "Which color?", since: now)
        coordinator.asksFor = [RelatedSession(id: "abc", name: "Add dark mode")]
        #expect(CopilotAgent.line(coordinator, now: now) == """
            - “Release 2.5” (a chat): Waiting for your answer, just now. Which color?
              Asks this for “Add dark mode” (session abc)
              session p1
            """)
        var waiting = session("abc", phase: .running, reason: .relayed, detail: "Which color?", since: now)
        waiting.headline = "Answer in “Release 2.5”"
        waiting.answerIn = RelatedSession(id: "p1", name: "Release 2.5")
        #expect(CopilotAgent.line(waiting, now: now) == """
            - “Add dark mode” (shop-web, dark-mode): Answer in “Release 2.5”, just now. Which color?
              Its coordinator asks it: answer in session p1
              session abc
            """)
    }

    /// With Nest Sessions Under Their Parents: one nested under the session that started it is indented under it, and one
    /// that isn't says which session started it, unless it says to answer there already.
    @Test func showsWhichSessionStartedEachOne() {
        let now = Date()
        var nested = session("abc", phase: .running, reason: .working, since: now)
        nested.parent = RelatedSession(id: "p1", name: "Release 2.5")
        nested.depth = 1
        #expect(CopilotAgent.line(nested, now: now) == """
              - “Add dark mode” (shop-web, dark-mode): Working, just now
                session abc
            """)
        var elsewhere = session("abc", detail: "Which color?", choices: ["Blue", "Green"], since: now)
        elsewhere.parent = RelatedSession(id: "p1", name: "Release 2.5")
        #expect(CopilotAgent.line(elsewhere, now: now) == """
            - “Add dark mode” (shop-web, dark-mode): Waiting for your answer, just now. Which color?
              Choices: Blue · Green
              Started by “Release 2.5” (session p1)
              session abc
            """)
        var relayed = session("abc", phase: .running, reason: .relayed, since: now)
        relayed.headline = "Answer in “Release 2.5”"
        relayed.answerIn = RelatedSession(id: "p1", name: "Release 2.5")
        relayed.parent = relayed.answerIn
        #expect(!CopilotAgent.line(relayed, now: now).contains("Started by"))
    }

    @Test func namesPhasesTheWayAgentsCallThem() {
        #expect(DisplayPhase.allCases.map(\.agentName) == ["needs_you", "running", "done", "stopped", "idle"])
        #expect(DisplayPhase.named("needsYou") == .needsYou)
        #expect(DisplayPhase.named("STOPPED") == .stopped)
        #expect(DisplayPhase.named("later") == nil)
    }

    @Test func offersOneToolThatOnlyReads() {
        let agent = CopilotAgent(paths: CopilotPaths(root: URL(fileURLWithPath: "/nonexistent")))
        #expect(agent.tools.map(\.name) == ["copilot_sessions"])
        #expect(agent.tools.allSatisfy { $0.readOnly })
    }
}
