import Foundation
import Testing
@testable import CopilotCore

private func asking(_ question: String, choices: [String] = [], at date: Date) -> [String] {
    [
        Line.userMessage(at: t(0)),
        Line.toolStart("ask_user", id: "q", arguments: ["question": question, "choices": choices], at: date),
    ]
}

private func planning(_ summary: String, at date: Date) -> [String] {
    [Line.userMessage(at: t(0)), Line.toolStart("exit_plan_mode", id: "p", arguments: ["summary": summary], at: date)]
}

private func relaying(_ session: String, context: String? = nil, at date: Date) -> [String] {
    var arguments: [String: Any] = ["project_session_id": session, "request_id": "request-\(session)"]
    if let context { arguments["context"] = context }
    return [Line.userMessage(at: t(0)), Line.toolStart("relay_session_input", id: "r", arguments: arguments, at: date)]
}

private func working(at date: Date) -> [String] {
    [Line.userMessage(at: t(0)), Line.toolStart("bash", id: "b", arguments: ["description": "Run the tests"], at: date)]
}

private func record(
    _ id: String, _ name: String, workspace: String? = nil, coordinator: String? = nil, _ lines: [String]
) -> SessionRecord {
    SessionRecord(
        meta: SessionMeta(
            id: id, name: name, isRunning: true, updatedAt: t(0), coordinatorSessionId: coordinator, workspaceId: workspace
        ),
        log: logState(lines)
    )
}

private func merged(_ records: [SessionRecord], now: Date = t(60)) -> [String: SessionSnapshot] {
    let snapshots = records.map { StatusResolver.snapshot(for: $0, now: now) }
    return Dictionary(uniqueKeysWithValues: RelayedQuestions.merge(snapshots, records: records).map { ($0.id, $0) })
}

@Suite struct RelayedQuestionsTests {
    private let release = RelatedSession(id: "coordinator", name: "Release 2.5")
    private let colors = RelatedSession(id: "child", name: "Pick colors")

    /// The app tells the coordinator, which relays it: you answer it there, once.
    @Test func aRelayedQuestionShowsOnceWhereTheCoordinatorAsksIt() throws {
        let question = asking("Which **color**?", choices: ["Blue", "Green"], at: t(10))
        // A relay names a session by its workspace or its own ID. It's enough on its own, whatever the app records.
        for (named, coordinator) in [("w-child", "coordinator"), ("child", nil)] {
            let sessions = merged([
                record("child", "Pick colors", workspace: "w-child", coordinator: coordinator, question),
                record("coordinator", "Release 2.5", relaying(named, context: "From the theme session.", at: t(12))),
            ])
            let asking = try #require(sessions["coordinator"])
            #expect(asking.phase == .needsYou)
            #expect(asking.reason == .question)
            #expect(asking.headline == "Waiting for your answer")
            #expect(asking.detail == "Which color?")
            #expect(asking.choices == ["Blue", "Green"])
            #expect(asking.since == t(10))
            #expect(asking.asksFor == [colors])
            #expect(asking.answerIn == nil)

            let waiting = try #require(sessions["child"])
            #expect(waiting.phase == .running)
            #expect(waiting.reason == .relayed)
            #expect(waiting.headline == "Answer in “Release 2.5”")
            #expect(waiting.detail == "Which color?")
            #expect(waiting.choices == ["Blue", "Green"])
            #expect(waiting.since == t(10))
            #expect(waiting.answerIn == release)
            #expect(waiting.asksFor.isEmpty)
            #expect(PhaseCounts(Array(sessions.values)).needsYou == 1)
        }
    }

    /// A plan can't be relayed, so the coordinator asks about it in its own words.
    @Test func aPlanTheCoordinatorAsksAboutShowsOnce() throws {
        let sessions = merged([
            record("child", "Pick colors", coordinator: "coordinator", planning("Use the brand palette.", at: t(10))),
            record("coordinator", "Release 2.5", asking("Approve “Pick colors”'s plan?", at: t(40))),
        ])
        let asking = try #require(sessions["coordinator"])
        #expect(asking.phase == .needsYou)
        #expect(asking.detail == "Approve “Pick colors”'s plan?")
        #expect(asking.since == t(10))
        #expect(asking.asksFor == [colors])
        let waiting = try #require(sessions["child"])
        #expect(waiting.phase == .running)
        #expect(waiting.reason == .relayed)
        #expect(waiting.detail == "Use the brand palette.")
        #expect(waiting.since == t(10))
        #expect(waiting.answerIn == release)
    }

    @Test func untilTheCoordinatorAsksTheSessionNeedsYouItself() {
        func phases(_ child: [String], coordinator: String? = "coordinator", _ asking: [String]) -> [String: StatusReason] {
            merged([
                record("child", "Pick colors", coordinator: coordinator, child),
                record("coordinator", "Release 2.5", asking),
            ]).mapValues(\.reason)
        }
        let plan = planning("Use the brand palette.", at: t(10))
        // It hasn't asked yet.
        #expect(phases(plan, working(at: t(12))) == ["child": .planApproval, "coordinator": .working])
        // Its question came first, so it isn't about the plan.
        #expect(phases(plan, asking("Ship on Friday?", at: t(5))) == ["child": .planApproval, "coordinator": .question])
        // It doesn't coordinate the session, nor relays its question.
        #expect(phases(plan, coordinator: nil, asking("Ship on Friday?", at: t(40))) == ["child": .planApproval, "coordinator": .question])
        #expect(phases(plan, coordinator: "someone-else", asking("Ship on Friday?", at: t(40)))
            == ["child": .planApproval, "coordinator": .question])
        // Only the session itself can answer a permission prompt.
        let permission = [
            Line.userMessage(at: t(0)), Line.permissionRequested(id: "r1", ["kind": "shell", "fullCommandText": "git push"], at: t(10)),
        ]
        #expect(phases(permission, asking("Push?", at: t(40))) == ["child": .permission, "coordinator": .question])
        // A relay is only of a question.
        #expect(phases(plan, coordinator: nil, relaying("child", at: t(40))) == ["child": .planApproval, "coordinator": .question])
        // A coordinator that isn't listed asks nothing here.
        let alone = merged([record("child", "Pick colors", coordinator: "coordinator", plan)])
        #expect(alone["child"]?.reason == .planApproval)
    }

    /// The session it relays for isn't listed, archived say: the relay says what it says before the question.
    @Test func aRelayForAnUnlistedSessionKeepsItsOwnWords() throws {
        let sessions = merged([record("coordinator", "Release 2.5", relaying("w-gone", context: "From the theme session.", at: t(12)))])
        let asking = try #require(sessions["coordinator"])
        #expect(asking.phase == .needsYou)
        #expect(asking.detail == "From the theme session.")
        #expect(asking.since == t(12))
        #expect(asking.asksFor.isEmpty)
    }

    /// Once it asks, it brings you the rest that waited for it before, one after another.
    @Test func everySessionThatWaitedForTheCoordinatorShowsOnce() throws {
        let sessions = merged([
            record("first", "Pick colors", coordinator: "coordinator", asking("Which color?", at: t(10))),
            record("second", "Pick fonts", coordinator: "coordinator", planning("Use Inter.", at: t(20))),
            record("later", "Pick icons", coordinator: "coordinator", asking("Which icons?", at: t(40))),
            record("coordinator", "Release 2.5", relaying("first", at: t(30))),
        ])
        let asking = try #require(sessions["coordinator"])
        #expect(asking.detail == "Which color?")
        #expect(asking.since == t(10))
        #expect(asking.asksFor.map(\.id) == ["first", "second"])
        #expect(sessions["first"]?.answerIn == release)
        #expect(sessions["second"]?.answerIn == release)
        // It asked for it after the coordinator asked, so maybe not through it.
        #expect(sessions["later"]?.phase == .needsYou)
        #expect(sessions["later"]?.answerIn == nil)
    }

    /// A coordinator that's coordinated in turn: you answer where the question reaches you.
    @Test func aRelayOfARelayIsAnsweredWhereItEnds() throws {
        let sessions = merged([
            record("child", "Pick colors", workspace: "w-child", coordinator: "coordinator", asking("Which color?", at: t(10))),
            record("coordinator", "Release 2.5", workspace: "w-coordinator", coordinator: "planner", relaying("w-child", at: t(12))),
            record("planner", "Plan the quarter", relaying("w-coordinator", at: t(14))),
        ])
        let planner = RelatedSession(id: "planner", name: "Plan the quarter")
        let asking = try #require(sessions["planner"])
        #expect(asking.phase == .needsYou)
        #expect(asking.detail == "Which color?")
        #expect(asking.since == t(10))
        #expect(asking.asksFor.map(\.id) == ["child", "coordinator"])
        for id in ["child", "coordinator"] {
            #expect(sessions[id]?.phase == .running)
            #expect(sessions[id]?.detail == "Which color?")
            #expect(sessions[id]?.answerIn == planner)
        }
    }

    /// Sessions can't relay each other's questions, but if they seemed to, one of them would still need you.
    @Test func aCycleStillLeavesOneToAnswer() {
        let sessions = merged([
            record("a", "A", workspace: "w-a", relaying("w-b", at: t(12))),
            record("b", "B", workspace: "w-b", relaying("w-a", at: t(14))),
        ])
        #expect(sessions["a"]?.phase == .needsYou)
        #expect(sessions["a"]?.asksFor == [RelatedSession(id: "b", name: "B")])
        #expect(sessions["b"]?.answerIn == RelatedSession(id: "a", name: "A"))
    }

    @Test func leavesEverythingElseAsItIs() {
        let records = [
            record("child", "Pick colors", coordinator: "coordinator", asking("Which color?", at: t(10))),
            record("coordinator", "Release 2.5", working(at: t(12))),
        ]
        let snapshots = records.map { StatusResolver.snapshot(for: $0, now: t(60)) }
        #expect(RelayedQuestions.merge(snapshots, records: records) == snapshots)
        #expect(RelayedQuestions.merge([], records: records).isEmpty)
    }
}
