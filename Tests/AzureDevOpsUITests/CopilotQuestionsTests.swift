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
