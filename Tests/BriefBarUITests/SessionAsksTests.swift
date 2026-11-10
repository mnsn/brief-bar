import BriefBarCore
import Foundation
import Synchronization
import Testing
@testable import BriefBarUI

/// Ask… asks a Copilot session aside, through what the app gives it (`SessionAsks.setAsker`), and keeps what it answered
/// in memory only, by the session, wherever it shows; its field is open for one session at a time; and taking the way to ask
/// away stops what's asked and forgets everything. Nothing here runs the Copilot CLI.
@MainActor
@Suite struct SessionAsksTests {
    private let session = ItemRef.session("2F8A4C6E-1B3D-4E5F-8A7B-9C0D1E2F3A14")!
    private let other = ItemRef.session("c3e8f1a2-6b4d-4e97-a1c5-2f7d9b0e8a11")!

    /// Stands in for the Copilot CLI: keeps what it's asked, in order, and answers each question as a test tells it to, in
    /// order, or as soon as it's asked when told before; stopped, it says so.
    private final class Asker: Sendable {
        private struct State {
            var requests: [SessionAsks.Request] = []
            var waiting: [(id: Int, continuation: CheckedContinuation<Result<String, SessionAsks.Problem>, Never>)] = []
            var ready: [Result<String, SessionAsks.Problem>] = []
            var cancelled = 0
            var count = 0
        }

        private let state = Mutex(State())

        var asked: [SessionAsks.Request] { state.withLock { $0.requests } }
        var cancelled: Int { state.withLock { $0.cancelled } }

        /// Answers the question that's waited longest, or the next one asked.
        func answer(_ result: Result<String, SessionAsks.Problem>) {
            let waiting = state.withLock { state -> CheckedContinuation<Result<String, SessionAsks.Problem>, Never>? in
                guard !state.waiting.isEmpty else {
                    state.ready.append(result)
                    return nil
                }
                return state.waiting.removeFirst().continuation
            }
            waiting?.resume(returning: result)
        }

        func ask(_ request: SessionAsks.Request) async -> Result<String, SessionAsks.Problem> {
            let id = state.withLock { state -> Int in
                state.requests.append(request)
                state.count += 1
                return state.count
            }
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let now = state.withLock { state -> Result<String, SessionAsks.Problem>? in
                        if Task.isCancelled { return .failure(SessionAsks.Problem("Stopped")) }
                        if !state.ready.isEmpty { return state.ready.removeFirst() }
                        state.waiting.append((id, continuation))
                        return nil
                    }
                    if let now { continuation.resume(returning: now) }
                }
            } onCancel: {
                let waiting = state.withLock { state -> CheckedContinuation<Result<String, SessionAsks.Problem>, Never>? in
                    state.cancelled += 1
                    guard let index = state.waiting.firstIndex(where: { $0.id == id }) else { return nil }
                    return state.waiting.remove(at: index).continuation
                }
                waiting?.resume(returning: .failure(SessionAsks.Problem("Stopped")))
            }
        }
    }

    private func asks() -> (SessionAsks, Asker) {
        let asks = SessionAsks()
        let asker = Asker()
        asks.setAsker { await asker.ask($0) }
        return (asks, asker)
    }

    private func ended(_ asks: SessionAsks, _ session: ItemRef) async throws {
        try await until("the question to end") { asks.question(for: session)?.isAsking == false }
    }

    @Test func asksTheSessionYourQuestionAndShowsItsAnswer() async throws {
        let (asks, asker) = asks()
        #expect(asks.canAsk)
        asks.openField(for: session)
        asks.setWords("  Why did you cap it at 30 s?\n", for: session)
        asks.ask(session, question: asks.words(for: session))
        // Its field closes as it's asked.
        #expect(!asks.isFieldOpen(for: session))
        let asking = try #require(asks.question(for: session))
        #expect(asking.isAsking)
        #expect(asking.asked == "Why did you cap it at 30 s?")
        #expect(asking.shownQuestion == "Why did you cap it at 30 s?")
        try await until("the session to be asked") { asker.asked.count == 1 }
        let request = try #require(asker.asked.first)
        #expect(request.session == "2f8a4c6e-1b3d-4e5f-8a7b-9c0d1e2f3a14")
        #expect(request.question == "Why did you cap it at 30 s?")
        #expect(request.earlier == nil)
        #expect(request.prompt == SessionAskPrompt.prompt(question: "Why did you cap it at 30 s?"))

        asker.answer(.success("\n**Because** the load balancer gives up at 60 s.\n"))
        try await ended(asks, session)
        let answered = try #require(asks.question(for: session))
        #expect(answered.state == .answered("**Because** the load balancer gives up at 60 s."))
        #expect(answered.endedAt != nil)
        #expect(answered.answer == SessionAnswer(question: "Why did you cap it at 30 s?", answer: "**Because** the load balancer gives up at 60 s."))
        // Only that session's.
        #expect(asks.question(for: other) == nil)

        asks.dismiss(session)
        #expect(asks.question(for: session) == nil)
    }

    /// Asked nothing in your words, it asks where the session stands.
    @Test func emptyAsksWhereItStands() async throws {
        let (asks, asker) = asks()
        asks.ask(session, question: "  \n ")
        let asking = try #require(asks.question(for: session))
        #expect(asking.asked == nil)
        #expect(asking.shownQuestion == "Where do you stand?")
        try await until("the session to be asked") { asker.asked.count == 1 }
        #expect(asker.asked.first?.question == nil)
        #expect(asker.asked.first?.prompt == SessionAskPrompt.prompt(question: nil))
        #expect(asker.asked.first?.prompt.contains("Where do you stand? Say what's done") == true)
    }

    /// Ask More follows up on the answer that shows: the next copy of the session never saw it, so the question quotes it.
    /// Empty, it asks where the session stands now.
    @Test func askMoreFollowsUpOnTheAnswerThatShows() async throws {
        let (asks, asker) = asks()
        asks.ask(session, question: nil)
        asker.answer(.success("Done: the backoff. Left: Sam's comment."))
        try await ended(asks, session)
        let earlier = SessionAnswer(question: nil, answer: "Done: the backoff. Left: Sam's comment.")

        asks.ask(session, question: nil)
        let asking = try #require(asks.question(for: session))
        #expect(asking.earlier == earlier)
        #expect(asking.shownQuestion == "Where do you stand now?")
        try await until("the session to be asked again") { asker.asked.count == 2 }
        let request = asker.asked[1]
        #expect(request.earlier == earlier)
        #expect(request.prompt == SessionAskPrompt.prompt(question: nil, earlier: earlier))
        #expect(request.prompt.contains("Done: the backoff."))

        asker.answer(.success("Sam approved it."))
        try await ended(asks, session)
        // And on that one, next: your words, with the one before.
        asks.ask(session, question: "Who's left?")
        try await until("the session to be asked a third time") { asker.asked.count == 3 }
        #expect(asker.asked[2].earlier == SessionAnswer(question: nil, answer: "Sam approved it."))
        #expect(asker.asked[2].question == "Who's left?")
    }

    /// Why there's no answer shows; Try Again asks the same again, following up on the same answer.
    @Test func failsWithWhyAndTriesAgainAsAsked() async throws {
        let (asks, asker) = asks()
        asks.ask(session, question: nil)
        asker.answer(.success("Done."))
        try await ended(asks, session)
        asks.ask(session, question: "Why?")
        asker.answer(.failure(SessionAsks.Problem("You're out of premium requests this month.", detail: "402 quota exceeded")))
        try await ended(asks, session)
        let failed = try #require(asks.question(for: session))
        #expect(failed.state == .failed(SessionAsks.Problem("You're out of premium requests this month.", detail: "402 quota exceeded")))
        #expect(failed.answer == nil)

        asks.tryAgain(session)
        #expect(asks.question(for: session)?.isAsking == true)
        try await until("the session to be asked again") { asker.asked.count == 3 }
        #expect(asker.asked[2].question == "Why?")
        #expect(asker.asked[2].earlier == SessionAnswer(question: nil, answer: "Done."))
        #expect(asker.asked[2].prompt == asker.asked[1].prompt)
        asker.answer(.success("Because."))
        try await ended(asks, session)
        #expect(asks.question(for: session)?.state == .answered("Because."))
        // Nothing to try again once it answered.
        asks.tryAgain(session)
        #expect(asks.question(for: session)?.state == .answered("Because."))
        #expect(asker.asked.count == 3)
    }

    @Test func anEmptyAnswerSaysSo() async throws {
        let (asks, asker) = asks()
        asks.ask(session, question: nil)
        asker.answer(.success(" \n"))
        try await ended(asks, session)
        #expect(asks.question(for: session)?.state == .failed(SessionAsks.Problem("Copilot answered nothing.")))
    }

    /// Asking again stops what's asked, deleting its copy of the session, and what it would answer isn't wanted; dismissing
    /// it stops it too.
    @Test func askingAgainOrDismissingStopsWhatsAsked() async throws {
        let (asks, asker) = asks()
        asks.ask(session, question: "First?")
        try await until("the session to be asked") { asker.asked.count == 1 }
        asks.ask(session, question: "Second?")
        try await until("the first question to stop") { asker.cancelled == 1 }
        try await until("the session to be asked again") { asker.asked.count == 2 }
        #expect(asks.question(for: session)?.asked == "Second?")
        #expect(asks.question(for: session)?.isAsking == true)
        asker.answer(.success("The second answer."))
        try await ended(asks, session)
        #expect(asks.question(for: session)?.state == .answered("The second answer."))

        asks.ask(other, question: nil)
        try await until("the other session to be asked") { asker.asked.count == 3 }
        asks.dismiss(other)
        try await until("its question to stop") { asker.cancelled == 2 }
        #expect(asks.question(for: other) == nil)
        // The other session's answer stays.
        #expect(asks.question(for: session)?.state == .answered("The second answer."))
    }

    /// Without a way to ask, as with Send Work to Copilot off, Ask… doesn't show: what's asked stops, and what was asked and
    /// answered, and what you wrote, are forgotten.
    @Test func takingTheAskerAwayStopsAndForgetsEverything() async throws {
        let (asks, asker) = asks()
        asks.ask(session, question: nil)
        asker.answer(.success("Done."))
        try await ended(asks, session)
        asks.ask(other, question: "Why?")
        try await until("the other session to be asked") { asker.asked.count == 2 }
        asks.openField(for: session)
        asks.setWords("And now?", for: session)

        asks.setAsker(nil)
        #expect(!asks.canAsk)
        #expect(asks.questions.isEmpty)
        #expect(asks.field == nil)
        try await until("what's asked to stop") { asker.cancelled == 1 }
        #expect(!asks.offers(session))
        asks.openField(for: session)
        #expect(!asks.isFieldOpen(for: session))
        asks.ask(session, question: nil)
        #expect(asks.question(for: session) == nil)
        #expect(asker.asked.count == 2)
    }

    /// Only Copilot sessions are asked.
    @Test func asksOnlySessions() {
        let (asks, _) = asks()
        let workItem = ItemRef.workItem(organization: "contoso", id: 5112)
        let pullRequest = ItemRef.pullRequest(organization: "contoso", number: 4102)
        #expect(asks.offers(session))
        #expect(!asks.offers(workItem))
        #expect(!asks.offers(pullRequest))
        #expect(!asks.offers(nil))
        asks.openField(for: workItem)
        #expect(asks.field == nil)
        asks.ask(pullRequest, question: "Why?")
        #expect(asks.questions.isEmpty)
    }

    /// One field is open at a time, as Explain's composer is, keeping what you wrote in it until you ask or close it.
    @Test func oneFieldIsOpenAtATime() {
        let (asks, _) = asks()
        asks.openField(for: session)
        asks.setWords("Why 30 s?", for: session)
        // Opening it again keeps what you wrote.
        asks.openField(for: session)
        #expect(asks.words(for: session) == "Why 30 s?")
        asks.openField(for: other)
        #expect(!asks.isFieldOpen(for: session))
        #expect(asks.isFieldOpen(for: other))
        #expect(asks.words(for: other).isEmpty)
        #expect(asks.words(for: session).isEmpty)
        // A closed one keeps nothing.
        asks.setWords("Lost", for: session)
        #expect(asks.field == SessionAsks.Field(session: other, words: ""))
        asks.closeField(for: session)
        #expect(asks.isFieldOpen(for: other))
        asks.closeField(for: other)
        #expect(asks.field == nil)
    }

    /// No field opens for a session while it's asked: asking it there would stop that question, a premium request already,
    /// for another. Trying again closes its field, as asking does.
    @Test func noFieldOpensWhileTheSessionIsAsked() async throws {
        let (asks, asker) = asks()
        asks.openField(for: session)
        asks.ask(session, question: nil)
        #expect(asks.field == nil)
        asks.openField(for: session)
        #expect(asks.field == nil)
        // Another session's opens.
        asks.openField(for: other)
        #expect(asks.isFieldOpen(for: other))

        asker.answer(.failure(SessionAsks.Problem("You're out of premium requests this month.")))
        try await ended(asks, session)
        asks.openField(for: session)
        asks.setWords("Why?", for: session)
        asks.tryAgain(session)
        #expect(asks.question(for: session)?.isAsking == true)
        #expect(asks.field == nil)
        asker.answer(.success("Done."))
        try await ended(asks, session)
        asks.openField(for: session)
        #expect(asks.isFieldOpen(for: session))
    }

    /// As GitHub Copilot is turned off: what's asked of the sessions it listed stops, and what they were asked and answered,
    /// and their field, are forgotten; a task BriefBar sent keeps its own, as Azure DevOps lists it, and Ask… goes on.
    @Test func forgetsTheSessionsASourceListed() async throws {
        let (asks, asker) = asks()
        let task = ItemRef.session("9a4f2b17-c3d8-4e61-b5a0-2e8d7c6b4a03")!
        asks.ask(task, question: nil)
        asker.answer(.success("Fixed the comments."))
        try await ended(asks, task)
        asks.ask(session, question: nil)
        asker.answer(.success("Done."))
        try await ended(asks, session)
        asks.ask(other, question: "Why?")
        try await until("the other session to be asked") { asker.asked.count == 3 }
        asks.openField(for: session)

        asks.forgetSessions { $0 != task }
        try await until("what's asked to stop") { asker.cancelled == 1 }
        #expect(asks.question(for: session) == nil)
        #expect(asks.question(for: other) == nil)
        #expect(asks.field == nil)
        #expect(asks.question(for: task)?.state == .answered("Fixed the comments."))
        #expect(asks.canAsk)
        // A task's field stays open.
        asks.openField(for: task)
        asks.forgetSessions { $0 != task }
        #expect(asks.isFieldOpen(for: task))
    }

    /// VoiceOver hears that a question ended once, though its session shows in more than one place; and so for the next.
    @Test func announcesEachEndOnce() async throws {
        let (asks, asker) = asks()
        #expect(!asks.announcesOnce(session))
        asks.ask(session, question: nil)
        #expect(!asks.announcesOnce(session))
        asker.answer(.success("Done."))
        try await ended(asks, session)
        #expect(asks.announcesOnce(session))
        #expect(!asks.announcesOnce(session))
        asks.ask(session, question: "Why?")
        asker.answer(.success("Because."))
        try await ended(asks, session)
        #expect(asks.announcesOnce(session))
        #expect(!asks.announcesOnce(session))
    }
}

/// What a session answered, read as the Markdown a model writes, block by block.
@Suite struct AnswerMarkdownTests {
    @Test func readsParagraphsHeadingsPointsAndRules() {
        let text = """
            ## Where it stands

            **Done:** the backoff,
            with tests.

            - Left: Sam's comment
              on the cap
            - Waiting on: you
              * nested
            1. First
            12) Twelfth
            ***
            Last line ###
            """
        #expect(AnswerMarkdown.blocks(text) == [
            .heading("Where it stands"),
            .paragraph("**Done:** the backoff, with tests."),
            .point(marker: "•", text: "Left: Sam's comment on the cap", depth: 0),
            .point(marker: "•", text: "Waiting on: you", depth: 0),
            .point(marker: "•", text: "nested", depth: 1),
            .point(marker: "1.", text: "First", depth: 0),
            .point(marker: "12.", text: "Twelfth", depth: 0),
            .rule,
            .paragraph("Last line ###"),
        ])
    }

    /// Code keeps its lines as written, without as many spaces as its fence is indented by; a fence that never closes holds
    /// the rest; quotes and tables go on with their next lines.
    @Test func readsCodeQuotesAndTables() {
        let text = """
            > Sam: cap it
            > at 30 s.

              ```swift
              let delay = min(base * 2, 30)
                return delay
              ```
            | File | Change |
            |------|:------:|
            | `Client.swift` | backoff |
            ~~~
            # not a heading
            """
        #expect(AnswerMarkdown.blocks(text) == [
            .quote("Sam: cap it at 30 s."),
            .code("let delay = min(base * 2, 30)\n  return delay"),
            .table([["File", "Change"], ["`Client.swift`", "backoff"]]),
            .code("# not a heading"),
        ])
    }

    /// A fence indented by four spaces or more is the code's own: it doesn't close it, though one indented by three does.
    @Test func aFenceIndentedFurtherIsTheCodesOwn() {
        let text = """
            ```
                ```
            still code
               ```
            After the code.
            """
        #expect(AnswerMarkdown.blocks(text) == [.code("    ```\nstill code"), .paragraph("After the code.")])
    }

    /// Only the line right under a table's header is its rule: a row of dashes after it is one of its rows.
    @Test func keepsATablesRowsOfDashes() {
        let text = """
            | Done | Waiting |
            | --- | --- |
            | - | - |
            | backoff | - |
            """
        #expect(AnswerMarkdown.blocks(text) == [.table([["Done", "Waiting"], ["-", "-"], ["backoff", "-"]])])
    }

    /// Closing hashes go, after a space; a word's own stay.
    @Test func keepsAWordsOwnHashesInAHeading() {
        let text = """
            ## C#
            ### F# and C# ##
            # Done #
            """
        #expect(AnswerMarkdown.blocks(text) == [.heading("C#"), .heading("F# and C#"), .heading("Done")])
    }

    /// A pipe after a backslash is a cell's own, in its words or its code, and shows without the backslash, as on GitHub;
    /// one after a backslash that's itself escaped ends the cell.
    @Test func keepsEscapedPipesInATablesCells() {
        let text = #"""
            | Type | Meaning |
            |------|---------|
            | A\|B | union |
            | `a \| b` | either, as code |
            | `C:\\` | a drive |
            """#
        #expect(AnswerMarkdown.blocks(text) == [
            .table([["Type", "Meaning"], ["A|B", "union"], ["`a | b`", "either, as code"], [#"`C:\\`"#, "a drive"]]),
        ])
    }
}

/// How Ask… names a session in its sentences.
@Suite struct SessionAskNamesTests {
    @Test func quotesASessionOrATaskAndCutsALongName() {
        #expect(SessionAskViews.quoted("Retry backoff", isTask: false) == "‘Retry backoff’")
        #expect(SessionAskViews.quoted("Fix the build", isTask: true) == "the ‘Fix the build’ task")
        #expect(SessionAskViews.quoted("  ", isTask: false) == "the session")
        let long = String(repeating: "a", count: 30) + String(repeating: "b", count: 30)
        let cut = SessionAskViews.short(long)
        #expect(cut.count <= SessionAskViews.nameLimit)
        #expect(cut.hasPrefix("aaaa") && cut.hasSuffix("bbbb") && cut.contains("…"))
        #expect(SessionAskViews.short("Retry backoff") == "Retry backoff")
    }

    /// A long answer shows the blocks that start in what shows, at least the first.
    @Test func showsTheBlocksThatStartInWhatShows() {
        #expect(SessionAskViews.shown(of: [0: 0, 1: 40, 2: 95, 3: 200], in: 96) == 3)
        #expect(SessionAskViews.shown(of: [0: 120], in: 96) == 1)
    }
}
