import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import Foundation
import Synchronization
import Testing
@testable import AzureDevOpsUI

/// Explain asks a session about a thread aside, through the Copilot CLI, and shows its answer under the thread: in memory
/// only, until you dismiss it or Send Work to Copilot is turned off. Ask… asks any of your sessions the same way, while
/// that's on. The demo makes its answers up.
@MainActor
@Suite(.opensNothing) struct CopilotQuestionsTests {
    private let key = PRKey("contoso", 4102)
    private let session = "2f8a4c6e-1b3d-4e5f-8a7b-9c0d1e2f3a14"

    private func questions(mode: PRStore.Mode = .live) -> (CopilotQuestions, AppSettings) {
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.copilotEnabled = true
        let copilot = CopilotTasksStore(settings: settings, mode: mode, notifier: nil)
        copilot.useEnvironment(["COPILOT_HOME": "/nonexistent"])
        copilot.appHomeForTests = URL(fileURLWithPath: "/nonexistent/copilot-app", isDirectory: true)
        return (CopilotQuestions(copilot: copilot), settings)
    }

    @Test func asksTheSessionAndShowsItsAnswer() async throws {
        let (questions, _) = questions()
        let (go, letItGo) = AsyncStream<Void>.makeStream()
        let asked = Mutex<[(String, String)]>([])
        questions.askForTests = { prompt, session in
            asked.withLock { $0.append((prompt, session)) }
            for await _ in go { break }
            return .success("Sam wants the delay capped.")
        }
        questions.ask("Why?", asked: "  Why 30 s?\n", session: session, about: .thread(11), of: key)
        let asking = try #require(questions.question(about: .thread(11), of: key))
        #expect(asking.isAsking)
        #expect(asking.asked == "Why 30 s?")
        #expect(asking.session == session)
        letItGo.yield()
        try await settle { questions.question(about: .thread(11), of: key)?.isAsking == false }
        #expect(questions.question(about: .thread(11), of: key)?.state == .answered("Sam wants the delay capped."))
        #expect(questions.question(about: .thread(11), of: key)?.endedAt != nil)
        #expect(asked.withLock { $0.map(\.1) } == [session])
        #expect(questions.question(about: .thread(12), of: key) == nil)
        questions.dismiss(about: .thread(11), of: key)
        #expect(questions.question(about: .thread(11), of: key) == nil)
    }

    /// What a session said of a build is about the run it asked about, and the attempt of it: another run, as after a
    /// push, or another attempt of the same one, as when its failed jobs ran again under the same ID, isn't what it answered.
    @Test func aBuildsAnswerIsAboutItsRunAndAttempt() async throws {
        let (questions, _) = questions()
        questions.askForTests = { _, _ in .success("main broke it.") }
        let finished = Date().addingTimeInterval(-600)
        questions.ask("Why?", asked: nil, session: session, about: .build(31), run: 204_417, attempt: finished, of: key)
        try await settle { questions.question(about: .build(31), run: 204_417, of: key)?.isAsking == false }
        let answer = try #require(questions.question(about: .build(31), run: 204_417, of: key))
        #expect(answer.run == 204_417)
        #expect(answer.attempt == finished)
        #expect(answer.isAbout(run: 204_417, attempt: finished))
        // Another run, or another attempt: running again, then finished again.
        #expect(!answer.isAbout(run: 204_418, attempt: finished))
        #expect(!answer.isAbout(run: 204_417, attempt: nil))
        #expect(!answer.isAbout(run: 204_417, attempt: finished.addingTimeInterval(300)))
        // Another policy's run of the same pipeline, on its own row, is asked about on its own.
        #expect(questions.question(about: .build(31), run: 204_418, of: key) == nil)
        questions.ask("Why?", asked: "And this one?", session: session, about: .build(31), run: 204_418, of: key)
        try await settle { questions.question(about: .build(31), run: 204_418, of: key)?.isAsking == false }
        #expect(questions.question(about: .build(31), run: 204_417, of: key) == answer)
        questions.dismiss(about: .build(31), run: 204_418, of: key)
        #expect(questions.question(about: .build(31), run: 204_418, of: key) == nil)
        #expect(questions.question(about: .build(31), run: 204_417, of: key) == answer)
        // Asked without knowing them, it's about any.
        let unknown = CopilotQuestions.Question(session: session, asked: nil, askedAt: finished, state: .answered("main broke it."))
        #expect(unknown.isAbout(run: 204_418, attempt: nil))
    }

    /// As the pull requests are read again, what was asked about a build's run that its details don't list any more, or about
    /// another attempt of it, goes, as Ask More and Fix would build on it: not what's about a run as it is now, a thread, or
    /// a pull request whose builds weren't read.
    /// What was asked about a pull request's conflicts goes once someone pushes to it or retargets it, as the pull requests
    /// are read again: they conflict otherwise then, and Ask More and Resolve would build on it. Not while its branches stay.
    @Test func anAnswerAboutConflictsGoesOnceEitherBranchMoves() async throws {
        let (questions, _) = questions()
        questions.askForTests = { _, _ in .success("Both renamed the enum.") }
        var record = try #require(DemoData.records(now: Date()).first { $0.id == key })
        let asked = PullRequestFilesStore.Head(record.pullRequest)
        questions.ask("Why?", asked: nil, session: session, about: .conflicts, head: asked, of: key)
        try await settle { questions.question(about: .conflicts, of: key)?.isAsking == false }
        #expect(questions.question(about: .conflicts, of: key)?.head == asked)
        questions.dismissStale(of: [record])
        #expect(questions.question(about: .conflicts, of: key) != nil)
        // Pushed to.
        record.pullRequest.sourceCommit = "pushed"
        questions.dismissStale(of: [record])
        #expect(questions.question(about: .conflicts, of: key) == nil)
        // Retargeted, while it's still being asked: it stops.
        questions.askForTests = { _, _ in
            try? await Task.sleep(for: .seconds(30))
            return .success("Too late.")
        }
        questions.ask("Why?", asked: nil, session: session, about: .conflicts, head: PullRequestFilesStore.Head(record.pullRequest), of: key)
        record.pullRequest.targetBranch = "release"
        questions.dismissStale(of: [record])
        #expect(questions.question(about: .conflicts, of: key) == nil)
    }

    @Test func anAnswerAboutAnotherRunOrAttemptGoes() async throws {
        let (questions, _) = questions()
        questions.askForTests = { _, _ in .success("main broke it.") }
        let finished = Date().addingTimeInterval(-600)
        var record = try #require(DemoData.records(now: Date()).first { $0.id == key })
        record.details?.checks = [Check(name: "payments-api CI", kind: .build, state: .failed, completedAt: finished, buildId: 7, definitionId: 31)]
        func ask(run: Int) async throws {
            questions.ask("Why?", asked: nil, session: session, about: .build(31), run: run, attempt: finished, of: key)
            try await settle { questions.question(about: .build(31), run: run, of: key)?.isAsking == false }
        }
        try await ask(run: 7)
        questions.ask("Why?", asked: nil, session: session, about: .thread(11), of: key)
        try await settle { questions.question(about: .thread(11), of: key)?.isAsking == false }
        questions.dismissStale(of: [record])
        #expect(questions.question(about: .build(31), run: 7, of: key) != nil)
        // Its builds not read, or its policies, as when they're forbidden: kept.
        var unread = record
        unread.details = nil
        questions.dismissStale(of: [unread])
        #expect(questions.question(about: .build(31), run: 7, of: key) != nil)
        var forbidden = record
        forbidden.details?.checks = []
        forbidden.details?.checksKnown = false
        questions.dismissStale(of: [forbidden])
        #expect(questions.question(about: .build(31), run: 7, of: key) != nil)
        // Its failed jobs ran again under the same ID.
        record.details?.checks[0].completedAt = finished.addingTimeInterval(300)
        questions.dismissStale(of: [record])
        #expect(questions.question(about: .build(31), run: 7, of: key) == nil)
        // A newer run replaced it, as after a push.
        record.details?.checks[0].completedAt = finished
        try await ask(run: 7)
        record.details?.checks[0].buildId = 8
        questions.dismissStale(of: [record])
        #expect(questions.question(about: .build(31), run: 7, of: key) == nil)
        // A thread's stays.
        #expect(questions.question(about: .thread(11), of: key) != nil)
    }

    @Test func saysWhyItCouldntAnswer() async throws {
        let (questions, _) = questions()
        questions.askForTests = { _, _ in .failure(.unsupported(version: "1.0.80")) }
        questions.ask("Why?", asked: nil, session: session, about: .thread(11), of: key)
        try await settle { questions.question(about: .thread(11), of: key)?.isAsking == false }
        #expect(questions.question(about: .thread(11), of: key)?.state == .failed(.unsupported(version: "1.0.80")))
        #expect(questions.question(about: .thread(11), of: key)?.asked == nil)
        // A follow-up keeps what it followed up on, for the session to have it when it's asked there instead.
        let earlier = CopilotAnswer(question: "Why 30 s?", answer: "Sam wants a ceiling.")
        questions.ask("Which?", asked: "Which is smallest?", earlier: earlier, session: session, about: .thread(11), of: key)
        try await settle { questions.question(about: .thread(11), of: key)?.isAsking == false }
        #expect(questions.question(about: .thread(11), of: key)?.earlier == earlier)
    }

    /// Stopping it, asking again, or turning Send Work to Copilot off, stops what's being asked: its answer isn't wanted.
    @Test func stopsWhatsAskedWhenYouStopItOrTurnItOff() async throws {
        let (questions, settings) = questions()
        let started = Mutex(0)
        questions.askForTests = { _, _ in
            started.withLock { $0 += 1 }
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                return .failure(.cancelled)
            }
            return .success("Too late")
        }
        questions.ask("Why?", asked: nil, session: session, about: .thread(11), of: key)
        questions.stop(about: .thread(11), of: key)
        #expect(questions.question(about: .thread(11), of: key) == nil)
        questions.ask("Why?", asked: "First", session: session, about: .thread(11), of: key)
        questions.ask("Why?", asked: "Second", session: session, about: .thread(11), of: key)
        #expect(questions.question(about: .thread(11), of: key)?.asked == "Second")
        try await settle { started.withLock { $0 } == 3 }
        settings.copilotEnabled = false
        try await settle { questions.questions.isEmpty }
        #expect(questions.questions.isEmpty)
        #expect(!questions.canAsk)
        questions.ask("Why?", asked: nil, session: session, about: .thread(11), of: key)
        #expect(questions.question(about: .thread(11), of: key) == nil)
    }

    /// The demo answers with made-up answers, and never runs the Copilot CLI.
    @Test func theDemoMakesItsAnswersUp() async throws {
        let (questions, _) = questions(mode: .demo)
        questions.demoDelay = .milliseconds(10)
        #expect(questions.canAsk)
        questions.ask("Why?", asked: nil, session: session, about: .thread(11), of: key)
        try await settle { questions.question(about: .thread(11), of: key)?.isAsking == false }
        guard case .answered(let answer)? = questions.question(about: .thread(11), of: key)?.state else {
            Issue.record("No answer")
            return
        }
        #expect(answer == DemoData.explanation(ofThread: 11, pullRequest: 4102))
        #expect(answer.contains("Sam wants a ceiling"))
    }

    // MARK: Ask…

    /// The questions, giving Ask… (`SessionAsks`) its way to ask while Send Work to Copilot is on.
    private func asking(mode: PRStore.Mode = .live, on: Bool = true) -> (CopilotQuestions, SessionAsks, AppSettings) {
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.copilotEnabled = on
        let copilot = CopilotTasksStore(settings: settings, mode: mode, notifier: nil)
        copilot.useEnvironment(["COPILOT_HOME": "/nonexistent"])
        copilot.appHomeForTests = URL(fileURLWithPath: "/nonexistent/copilot-app", isDirectory: true)
        let asks = SessionAsks()
        return (CopilotQuestions(copilot: copilot, asks: asks), asks, settings)
    }

    /// Ask… asks only while Send Work to Copilot is on: turned off, it doesn't show, and what it asked stops and goes; turned
    /// on again, it's back. Stopped for good, as Azure DevOps stops, it goes, whatever the setting.
    @Test func offersAskOnlyWithSendWorkToCopilot() async throws {
        let (questions, asks, settings) = asking(on: false)
        #expect(!asks.canAsk)
        settings.copilotEnabled = true
        #expect(asks.canAsk)
        let started = Mutex(0)
        questions.askForTests = { _, _ in
            started.withLock { $0 += 1 }
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                return .failure(.cancelled)
            }
            return .success("Too late")
        }
        let ref = try #require(ItemRef.session(session))
        asks.ask(ref, question: nil)
        #expect(asks.question(for: ref)?.isAsking == true)
        try await settle { started.withLock { $0 } == 1 }
        settings.copilotEnabled = false
        #expect(!asks.canAsk)
        #expect(asks.questions.isEmpty)
        settings.copilotEnabled = true
        #expect(asks.canAsk)
        #expect(asks.questions.isEmpty)
        questions.stopAll()
        #expect(!asks.canAsk)
        settings.copilotEnabled = false
        settings.copilotEnabled = true
        #expect(!asks.canAsk)
    }

    /// Ask… asks as Explain does, through the same Copilot CLI: the question in full, of the session; and why it couldn't,
    /// in `SessionQuestions.Failure`'s words, with what the Copilot CLI said.
    @Test func asksForAskThroughTheCopilotCLI() async throws {
        let (questions, asks, _) = asking()
        let asked = Mutex<[(prompt: String, session: String)]>([])
        questions.askForTests = { prompt, session in
            let count = asked.withLock {
                $0.append((prompt, session))
                return $0.count
            }
            return count == 1 ? .success("Done: the backoff.") : .failure(.outOfRequests("402: quota exceeded"))
        }
        let ref = try #require(ItemRef.session(session))
        asks.ask(ref, question: "Is Sam's comment done?")
        try await settle { asks.question(for: ref)?.isAsking == false }
        #expect(asks.question(for: ref)?.state == .answered("Done: the backoff."))
        #expect(asked.withLock { $0.first?.prompt } == SessionAskPrompt.prompt(question: "Is Sam's comment done?"))
        #expect(asked.withLock { $0.first?.session } == session)

        asks.ask(ref, question: nil)
        try await settle { asks.question(for: ref)?.isAsking == false }
        #expect(asks.question(for: ref)?.state == .failed(
            SessionAsks.Problem("You're out of premium requests this month.", detail: "402: quota exceeded")
        ))
        #expect(asked.withLock { $0.last?.prompt } == SessionAskPrompt.prompt(
            question: nil, earlier: SessionAnswer(question: "Is Sam's comment done?", answer: "Done: the backoff.")
        ))
        // Explain's questions are its own.
        #expect(questions.questions.isEmpty)
    }

    /// The demo makes Ask…'s answers up too, and never runs the Copilot CLI: where its sessions stand, or why they did
    /// what they did; any other session's in general.
    @Test func theDemoMakesAskAnswersUp() async throws {
        let (questions, asks, _) = asking(mode: .demo)
        questions.demoDelay = .milliseconds(10)
        #expect(asks.canAsk)
        let ref = try #require(ItemRef.session(session))
        asks.ask(ref, question: nil)
        try await settle { asks.question(for: ref)?.isAsking == false }
        let stands = DemoData.sessionAnswer(session: session, question: nil)
        #expect(asks.question(for: ref)?.state == .answered(stands))
        #expect(stands.contains("Sam's comment"))

        asks.ask(ref, question: "Why no cap?")
        try await settle { asks.question(for: ref)?.isAsking == false }
        let why = DemoData.sessionAnswer(session: session, question: "Why no cap?")
        #expect(asks.question(for: ref)?.state == .answered(why))
        #expect(why != stands)
        #expect(DemoData.sessionAnswer(session: session.uppercased(), question: nil) == stands)
        let unknown = UUID().uuidString
        #expect(!DemoData.sessionAnswer(session: unknown, question: nil).isEmpty)
        #expect(DemoData.sessionAnswer(session: unknown, question: nil) != stands)
    }

    /// Azure DevOps gives Ask… its way to ask as it starts, in the demo with its made-up answers, and takes it away as it
    /// stops.
    @Test func azureDevOpsOffersAskWhileItRuns() {
        let services = AppServices(defaults: MemoryDefaults(), isDemo: true)
        let source = AzureDevOpsSource(services: services, summarizer: .withoutModel)
        #expect(!services.sessionAsks.canAsk)
        source.start()
        #expect(services.sessionAsks.canAsk)
        source.stop()
        #expect(!services.sessionAsks.canAsk)
    }

    /// Waits for the store's work, which runs on the main actor between this test's awaits, for as long as a busy machine
    /// could need (`waitLimit`), failing the test if it doesn't happen.
    private func settle(until done: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now.advanced(by: waitLimit)
        while !done() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting", sourceLocation: sourceLocation)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
