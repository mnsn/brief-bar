import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import Foundation
import Synchronization
import Testing
@testable import AzureDevOpsUI

/// Explain asks a session about a thread aside, through the Copilot CLI, and shows its answer under the thread: in memory
/// only, until you dismiss it or Send Work to Copilot is turned off. The demo makes its answers up.
@MainActor
@Suite struct CopilotQuestionsTests {
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
        // Its builds not read: kept.
        var unread = record
        unread.details = nil
        questions.dismissStale(of: [unread])
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
