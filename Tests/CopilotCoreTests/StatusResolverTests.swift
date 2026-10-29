import Foundation
import Testing
@testable import CopilotCore
import BriefBarCore

private func meta(
    name: String = "Fix login", type: String = "project", running: Bool? = false, interrupted: Bool = false,
    updatedAt: Date? = t(0), workspaceId: String? = "w1", activity: ActivityPreview? = nil
) -> SessionMeta {
    SessionMeta(
        id: "s1", name: name, sessionType: type, mode: "interactive", isRunning: running, wasInterrupted: interrupted,
        updatedAt: updatedAt, projectName: "acme-web", branch: "fix-login", workspaceId: workspaceId,
        lastActivity: activity
    )
}

private func resolve(
    _ lines: [String]?, _ meta: SessionMeta, now: Date, options: ResolverOptions = ResolverOptions(),
    view: AppViewState = AppViewState(), clearedAt: Date? = nil, viewedAt: Date? = nil
) -> SessionSnapshot {
    StatusResolver.snapshot(
        for: SessionRecord(meta: meta, log: lines.map(logState)), now: now, options: options, view: view,
        clearedAt: clearedAt, viewedAt: viewedAt
    )
}

private func item(
    _ id: String, _ phase: DisplayPhase, since: Date?, name: String = "", reason: StatusReason = .idle
) -> SessionSnapshot {
    SessionSnapshot(
        id: id, name: name, isChat: false, phase: phase, reason: reason, headline: reason.headline, choices: [],
        since: since
    )
}

/// A turn that ended normally at t(3).
private let finishedTurn = [Line.userMessage(at: t(1)), Line.assistantMessage(at: t(2)), Line.turnEnd(at: t(3))]

@Suite struct StatusResolverTests {
    private func verify(
        _ snapshot: SessionSnapshot, _ phase: DisplayPhase, _ reason: StatusReason, since: Date?,
        detail: String? = nil, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(snapshot.phase == phase, sourceLocation: sourceLocation)
        #expect(snapshot.reason == reason, sourceLocation: sourceLocation)
        #expect(snapshot.headline == reason.headline, sourceLocation: sourceLocation)
        #expect(snapshot.since == since, sourceLocation: sourceLocation)
        #expect(snapshot.detail == detail, sourceLocation: sourceLocation)
    }

    @Test func carriesTheContextUsage() {
        var measured = meta()
        measured.contextUsage = ContextUsage(tokens: 120_000, limit: 200_000)
        #expect(resolve(finishedTurn, measured, now: t(10)).contextUsage == ContextUsage(tokens: 120_000, limit: 200_000))
        #expect(resolve(finishedTurn, meta(), now: t(10)).contextUsage == nil)
    }

    @Test func withoutALogTheAppsFlagsDecide() {
        verify(resolve(nil, meta(running: true, updatedAt: t(5)), now: t(10)), .running, .working, since: t(5))
        verify(resolve(nil, meta(interrupted: true, updatedAt: t(5)), now: t(10)), .stopped, .interrupted, since: t(5))
        verify(resolve(nil, meta(interrupted: true, updatedAt: t(5)), now: t(3_606)), .idle, .interrupted, since: t(5))
        verify(resolve(nil, meta(updatedAt: t(5)), now: t(10)), .idle, .idle, since: t(5))
        // A log without a turn in it says nothing either.
        let started = [Line.sessionStart(at: t(1))]
        verify(resolve(started, meta(running: true, updatedAt: t(5)), now: t(10)), .running, .working, since: t(5))
    }

    @Test func working() {
        let lines = [
            Line.userMessage(at: t(1)),
            Line.assistantMessage(toolCalls: ["c1"], at: t(2)),
            Line.toolStart("bash", id: "c1", arguments: ["description": "Run **unit** tests"], at: t(3)),
        ]
        verify(resolve(lines, meta(running: true), now: t(30)), .running, .working, since: t(1), detail: "Run unit tests")
    }

    @Test func questionsNeedYou() {
        let lines = [
            Line.userMessage(at: t(1)),
            Line.toolStart("ask_user", id: "q", arguments: [
                "question": "Use **Postgres** or `SQLite`?", "choices": ["Postgres", "SQLite"],
            ], at: t(2)),
        ]
        let snapshot = resolve(lines, meta(running: true), now: t(30))
        verify(snapshot, .needsYou, .question, since: t(2), detail: "Use Postgres or SQLite?")
        #expect(snapshot.choices == ["Postgres", "SQLite"])
    }

    /// Until it's merged with the session it relays for (`RelayedQuestionsTests`), a relay says what it says first.
    @Test func relayedQuestionsNeedYou() {
        let relay = { (arguments: [String: Any]) in
            [Line.userMessage(at: t(1)), Line.toolStart("relay_session_input", id: "r", arguments: arguments, at: t(2))]
        }
        let framed = relay(["project_session_id": "w-child", "context": "From the **checkout** session."])
        verify(resolve(framed, meta(running: true), now: t(30)), .needsYou, .question, since: t(2), detail: "From the checkout session.")
        verify(resolve(relay(["project_session_id": "w-child"]), meta(running: true), now: t(30)), .needsYou, .question, since: t(2))
    }

    @Test func plansNeedYou() {
        let lines = [
            Line.userMessage(at: t(1)),
            Line.toolStart("exit_plan_mode", id: "p", arguments: ["summary": "## Plan\n- Add tests\n- Ship it"], at: t(2)),
        ]
        verify(
            resolve(lines, meta(running: true), now: t(30)), .needsYou, .planApproval, since: t(2),
            detail: "Plan Add tests Ship it"
        )
    }

    @Test func permissionsNeedYou() {
        let cases: [([String: Any], String?)] = [
            (["kind": "shell", "fullCommandText": "rm -rf build"], "rm -rf build"),
            (["kind": "url"], "url"),
            ([:], nil),
        ]
        for (request, detail) in cases {
            let lines = [Line.userMessage(at: t(1)), Line.permissionRequested(id: "r1", request, at: t(2))]
            verify(resolve(lines, meta(running: true), now: t(30)), .needsYou, .permission, since: t(2), detail: detail)
        }
    }

    @Test func endedSessionsStayHighlightedForAnHour() {
        verify(resolve(finishedTurn, meta(), now: t(3_603)), .done, .finished, since: t(3))
        verify(resolve(finishedTurn, meta(), now: t(3_604)), .idle, .finished, since: t(3))
        let shortWindow = ResolverOptions(recentWindow: 60)
        verify(resolve(finishedTurn, meta(), now: t(64), options: shortWindow), .idle, .finished, since: t(3))
    }

    @Test func onlyClearingThisCompletionDismissesIt() {
        verify(resolve(finishedTurn, meta(), now: t(60), clearedAt: t(3)), .idle, .finished, since: t(3))
        verify(resolve(finishedTurn, meta(), now: t(60), clearedAt: t(2)), .done, .finished, since: t(3))
    }

    @Test func clearingAnEarlierRunDoesNotHideTheNextCompletion() {
        let rerun = finishedTurn + [
            Line.userMessage(at: t(10)), Line.assistantMessage(at: t(11)), Line.turnEnd(at: t(12)),
        ]
        verify(resolve(rerun, meta(), now: t(60), clearedAt: t(4)), .done, .finished, since: t(12))
        verify(resolve(rerun, meta(), now: t(60), clearedAt: t(12)), .idle, .finished, since: t(12))
    }

    @Test func stoppedSessionsAlsoRequireExplicitClearingOrExpiry() {
        let stopped = [Line.userMessage(at: t(1)), Line.sessionError("Failed", at: t(3))]
        verify(resolve(stopped, meta(), now: t(60)), .stopped, .failed, since: t(3), detail: "Failed")
        verify(resolve(stopped, meta(), now: t(60), clearedAt: t(3)), .idle, .failed, since: t(3), detail: "Failed")
        verify(resolve(stopped, meta(), now: t(3_604)), .idle, .failed, since: t(3), detail: "Failed")
    }

    @Test func viewedCompletionsOnlyMoveToIdleWhenEnabled() {
        let autoIdle = ResolverOptions(moveViewedToIdle: true)
        verify(resolve(finishedTurn, meta(), now: t(60), viewedAt: t(4)), .done, .finished, since: t(3))
        verify(resolve(finishedTurn, meta(), now: t(60), options: autoIdle, viewedAt: t(4)), .idle, .finished, since: t(3))
        verify(resolve(finishedTurn, meta(), now: t(60), options: autoIdle, viewedAt: t(2)), .done, .finished, since: t(3))
        let rerun = finishedTurn + [
            Line.userMessage(at: t(10)), Line.assistantMessage(at: t(11)), Line.turnEnd(at: t(12)),
        ]
        verify(resolve(rerun, meta(), now: t(60), options: autoIdle, viewedAt: t(4)), .done, .finished, since: t(12))
        let stopped = [Line.userMessage(at: t(1)), Line.sessionError("Failed", at: t(3))]
        verify(resolve(stopped, meta(), now: t(60), viewedAt: t(4)), .stopped, .failed, since: t(3), detail: "Failed")
        verify(
            resolve(stopped, meta(), now: t(60), options: autoIdle, viewedAt: t(4)),
            .idle, .failed, since: t(3), detail: "Failed"
        )
    }

    @Test func theAppsUnreadMarkersOnlyDismissWhenEnabled() {
        func phase(_ session: SessionMeta, unread: Set<String>?, updatedAt: Date?, enabled: Bool = true) -> DisplayPhase {
            let view = AppViewState(unreadWorkspaceIds: unread, unreadUpdatedAt: updatedAt)
            return resolve(finishedTurn, session, now: t(60), options: ResolverOptions(moveViewedToIdle: enabled), view: view).phase
        }
        #expect(phase(meta(), unread: [], updatedAt: t(10), enabled: false) == .done)
        #expect(phase(meta(), unread: [], updatedAt: t(10)) == .idle)
        #expect(phase(meta(), unread: ["w9"], updatedAt: t(10)) == .idle)
        #expect(phase(meta(), unread: ["w1"], updatedAt: t(10)) == .done)
        #expect(phase(meta(), unread: [], updatedAt: t(2)) == .done)
        #expect(phase(meta(), unread: nil, updatedAt: t(10)) == .done)
        #expect(phase(meta(type: "general_chat", workspaceId: nil), unread: [], updatedAt: t(10)) == .done)
    }

    @Test func aRunningLogTheAppNoLongerRunsGoesStale() {
        let lines = [
            Line.userMessage(at: t(1)),
            Line.assistantMessage(toolCalls: ["c1"], at: t(2)),
            Line.toolStart("bash", id: "c1", at: t(3)),
        ]
        verify(resolve(lines, meta(), now: t(93)), .running, .working, since: t(1))
        verify(resolve(lines, meta(), now: t(94)), .stopped, .unresponsive, since: t(3))
        verify(resolve(lines, meta(interrupted: true), now: t(94)), .stopped, .interrupted, since: t(3))
        verify(resolve(lines, meta(), now: t(3_604)), .idle, .unresponsive, since: t(3))
        // While the app still says it's running, silence alone means nothing.
        verify(resolve(lines, meta(running: true), now: t(10_000)), .running, .working, since: t(1))
    }

    /// The fallback query and the folder scan can't tell whether the app is running a session.
    @Test func anUnknownRunningFlagLeavesItToTheLog() {
        let asking = [
            Line.userMessage(at: t(1)),
            Line.toolStart("ask_user", id: "q", arguments: ["question": "Ship it?"], at: t(2)),
        ]
        // A question can wait for hours; only a flag known to be off means the CLI is gone.
        verify(resolve(asking, meta(running: nil), now: t(10_000)), .needsYou, .question, since: t(2), detail: "Ship it?")
        verify(resolve(asking, meta(running: false), now: t(10_000)), .idle, .unresponsive, since: t(2))
        let working = [Line.userMessage(at: t(1)), Line.toolStart("bash", id: "c1", at: t(2))]
        verify(resolve(working, meta(running: nil), now: t(10_000)), .running, .working, since: t(1))
        // Nor does it start a new turn or stand in for a missing log.
        verify(resolve(finishedTurn, meta(running: nil, updatedAt: t(10)), now: t(20)), .done, .finished, since: t(3))
        verify(resolve(nil, meta(running: nil, updatedAt: t(5)), now: t(10)), .idle, .idle, since: t(5))
    }

    @Test func aNewTurnTheLogHasNotCaughtUpWithIsStarting() {
        verify(resolve(finishedTurn, meta(running: true, updatedAt: t(10)), now: t(20)), .running, .starting, since: t(10))
        // The grace period is over.
        verify(resolve(finishedTurn, meta(running: true, updatedAt: t(10)), now: t(130)), .done, .finished, since: t(3))
        // The app's timestamp belongs to the turn the log already shows.
        verify(resolve(finishedTurn, meta(running: true, updatedAt: t(4)), now: t(20)), .done, .finished, since: t(3))
    }

    @Test func endedTurnsShowTheAppsLastMessage() {
        func detail(_ lines: [String], _ activity: ActivityPreview) -> String? {
            resolve(lines, meta(activity: activity), now: t(60)).detail
        }
        func idle(_ text: String, at date: Date?) -> ActivityPreview {
            ActivityPreview(kind: "agent_idle", text: text, at: date)
        }
        #expect(detail(finishedTurn, idle("I fixed the **login** bug", at: t(4))) == "I fixed the login bug")
        #expect(detail(finishedTurn, idle("Undated", at: nil)) == "Undated")
        #expect(detail(finishedTurn, idle("Just in time", at: t(-27))) == "Just in time")
        // From an earlier turn, about something else, or empty.
        #expect(detail(finishedTurn, idle("Too old", at: t(-28))) == nil)
        #expect(detail(finishedTurn, ActivityPreview(kind: "agent_asking", text: "A question", at: t(4))) == nil)
        #expect(detail(finishedTurn, idle("", at: t(4))) == nil)

        // The CLI's own summary wins.
        let completed = [Line.userMessage(at: t(1)), Line.taskComplete("Shipped **it**", at: t(2))]
        #expect(detail(completed, idle("Preview", at: t(2))) == "Shipped it")
    }

    @Test func failuresAndInterruptions() {
        let failed = [Line.userMessage(at: t(1)), Line.sessionError("Rate limit exceeded", at: t(2))]
        verify(resolve(failed, meta(), now: t(60)), .stopped, .failed, since: t(2), detail: "Rate limit exceeded")

        let failedQuietly = [Line.userMessage(at: t(1)), Line.event("session.error", data: ["errorType": "query"], at: t(2))]
        let errorPreview = ActivityPreview(kind: "agent_error", text: "Something broke", at: t(2))
        verify(
            resolve(failedQuietly, meta(activity: errorPreview), now: t(60)), .stopped, .failed, since: t(2),
            detail: "Something broke"
        )

        let aborted = [Line.userMessage(at: t(1)), Line.abort(at: t(2))]
        let idlePreview = ActivityPreview(kind: "agent_idle", text: "Earlier reply", at: t(2))
        verify(resolve(aborted, meta(activity: idlePreview), now: t(60)), .stopped, .interrupted, since: t(2))
    }

    @Test func namesAndContextPassThrough() {
        let snapshot = resolve(nil, meta(name: "  Fix   the\nlogin  "), now: t(10))
        #expect(snapshot.name == "Fix the login")
        #expect(snapshot.displayName == "Fix the login")
        #expect(snapshot.id == "s1")
        #expect(snapshot.projectName == "acme-web")
        #expect(snapshot.branch == "fix-login")
        #expect(snapshot.mode == "interactive")
        #expect(!snapshot.isChat)

        #expect(resolve(nil, meta(name: " "), now: t(10)).displayName == "Untitled session")
        let chat = resolve(nil, meta(name: "", type: "general_chat", workspaceId: nil), now: t(10))
        #expect(chat.isChat)
        #expect(chat.displayName == "Untitled chat")
    }

    @Test(arguments: [
        ("**Bold** and `code`", "Bold and code"),
        ("__Underlined__ words", "Underlined words"),
        ("See [the docs](https://example.com/docs) now", "See the docs now"),
        ("![diagram](chart.png) above", "diagram above"),
        ("Cut off [link](https://exam", "Cut off link"),
        ("# Title\n> Quote\n- Item\n2. Step", "Title Quote Item Step"),
        ("  spaced \n\n out\t", "spaced out"),
        ("Plain text", "Plain text"),
    ])
    func flattensMarkdown(_ markdown: String, _ expected: String) {
        #expect(PlainText.fromMarkdown(markdown) == expected)
    }

    @Test func orderingPutsWhatNeedsYouFirst() {
        let snapshots = [
            item("idle-undated", .idle, since: nil),
            item("running-old", .running, since: t(1)),
            item("asking-new", .needsYou, since: t(10)),
            item("done", .done, since: t(3)),
            item("idle", .idle, since: t(50)),
            item("running-new", .running, since: t(20)),
            item("asking-old", .needsYou, since: t(5)),
            item("stopped", .stopped, since: t(4)),
            item("tie-10", .done, since: t(2), name: "Session 10"),
            item("tie-2", .done, since: t(2), name: "Session 2"),
            item("same-b", .done, since: t(1), name: "Same"),
            item("same-a", .done, since: t(1), name: "Same"),
        ]
        #expect(SessionOrdering.sorted(snapshots.shuffled()).map(\.id) == [
            "asking-old", "asking-new", "running-new", "running-old",
            "done", "tie-2", "tie-10", "same-a", "same-b", "stopped", "idle", "idle-undated",
        ])
    }

    @Test func countsPhases() {
        let phases: [DisplayPhase] = [.needsYou, .needsYou, .running, .done, .stopped, .idle, .idle, .idle]
        let counts = PhaseCounts(phases.enumerated().map { item("\($0.offset)", $0.element, since: nil) })
        #expect(DisplayPhase.allCases.map { counts[$0] } == [2, 1, 1, 1, 3])
        #expect(counts.active == 5)
        // By state, the same for every source: a session that stopped is something wrong, and idle ones aren't counted.
        #expect(DisplayPhase.allCases.map(\.state) == [.needsYou, .running, .done, .failing, nil])
        #expect(counts.states == StateCounts(needsYou: 2, failing: 1, running: 1, done: 1))

        var edited = PhaseCounts()
        edited[.done] += 2
        #expect(edited.done == 2)
        #expect(edited.active == 2)
    }

    @Test func saysInTheBriefWhatASessionWaitsForOrHowItEnded() {
        func sentence(_ reason: StatusReason, _ detail: String? = nil, name: String = "Add dark mode") -> String {
            var session = item("s", .needsYou, since: nil, name: name, reason: reason)
            session.detail = detail
            return session.briefSentence
        }
        #expect(sentence(.question, "Should it follow the system?") == "“Add dark mode” asks: Should it follow the system?")
        #expect(sentence(.question) == "“Add dark mode” is waiting for your answer.")
        #expect(sentence(.planApproval, "Replace cookies with OAuth.") == "“Add dark mode” has a plan for you to review: Replace cookies with OAuth.")
        #expect(sentence(.permission, "git push origin main") == "“Add dark mode” needs your permission to run git push origin main.")
        #expect(sentence(.finished) == "“Add dark mode” finished.")
        #expect(sentence(.interrupted) == "“Add dark mode” was interrupted.")
        #expect(sentence(.failed, "Lost the connection.\nTry again.") == "“Add dark mode” stopped with an error: Lost the connection. Try again.")
        #expect(sentence(.unresponsive, name: "") == "“Untitled session” stopped responding.")
        var relayed = item("s", .running, since: nil, name: "Add dark mode", reason: .relayed)
        #expect(relayed.briefSentence == "“Add dark mode” waits for your answer in another session.")
        relayed.answerIn = RelatedSession(id: "p", name: "Release 2.5")
        #expect(relayed.briefSentence == "“Add dark mode” waits for your answer in “Release 2.5”.")
        let long = sentence(.question, String(repeating: "Is it this? ", count: 30))
        #expect(long.hasSuffix("…"))
        #expect(long.count < 180)
    }

    @Test func phasesSortByUrgency() {
        #expect(DisplayPhase.allCases.shuffled().sorted() == [.needsYou, .running, .done, .stopped, .idle])
        let reasons: [StatusReason] = [
            .question, .planApproval, .permission, .working, .starting, .relayed,
            .finished, .interrupted, .failed, .unresponsive, .idle,
        ]
        #expect(reasons.filter { item("s", .idle, since: nil, reason: $0).isEnded }
            == [.finished, .interrupted, .failed, .unresponsive])
    }

    /// A session the app doesn't list, such as a task BriefBar sent to the Copilot CLI: what follows it says how it
    /// stands, and it's highlighted as long as the app's are.
    @Test func sessionsTheAppDoesNotListShowLikeItsOwn() {
        func unlisted(_ reason: StatusReason, detail: String? = nil, since: Date? = t(3), now: Date = t(60), isSeen: Bool = false) -> SessionSnapshot {
            StatusResolver.snapshot(
                unlisted: "task", name: " Fix Comments:\n!4071  Fix totals ", place: "shop-web", reason: reason, detail: detail,
                since: since, now: now, isSeen: isSeen
            )
        }
        let working = unlisted(.working, detail: "Run the **cart** tests")
        verify(working, .running, .working, since: t(3), detail: "Run the cart tests")
        #expect(working.name == "Fix Comments: !4071 Fix totals")
        #expect(working.projectName == "shop-web")
        #expect(working.branch == nil)
        #expect(!working.isChat)
        verify(unlisted(.starting), .running, .starting, since: t(3))

        verify(unlisted(.finished, detail: "Changes ready:\n- fixed it"), .done, .finished, since: t(3), detail: "Changes ready: fixed it")
        verify(unlisted(.failed, detail: "git failed"), .stopped, .failed, since: t(3), detail: "git failed")
        verify(unlisted(.interrupted), .stopped, .interrupted, since: t(3))
        // Seen, or ended over an hour ago: idle, as it ended.
        verify(unlisted(.finished, isSeen: true), .idle, .finished, since: t(3))
        verify(unlisted(.finished, now: t(3_604)), .idle, .finished, since: t(3))
        verify(unlisted(.failed, since: nil), .idle, .failed, since: nil)
        verify(unlisted(.finished, detail: "  "), .done, .finished, since: t(3))
    }
}
