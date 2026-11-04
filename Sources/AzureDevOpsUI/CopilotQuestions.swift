import AzureDevOpsCore
import BriefBarCore
import Combine
import CopilotTasks
import Foundation

/// What you ask Copilot sessions about pull requests with Explain, about a comment thread, a failed build or conflicts, and
/// what they answer: each asked aside, of a throwaway fork of the session with no tools, which the Copilot CLI deletes after
/// (`SessionQuestions`), so it changes no file and the session's history stays as it was. Each question sends the session's
/// conversation, with what it's about, such as a thread and its code or a build's errors, failed tests and the end of its
/// log, to GitHub Copilot, as one premium request. What's asked and answered stays in memory only, until you dismiss it,
/// BriefBar quits, or Send Work to Copilot or Azure DevOps is turned off, which stops what's being asked. The demo makes its
/// answers up, and never runs the Copilot CLI.
@MainActor
final class CopilotQuestions: ObservableObject {
    /// Something of a pull request.
    struct Key: Hashable {
        var pullRequest: PRKey
        var part: PullRequestPart
    }

    /// A question, and how it stands.
    struct Question: Equatable {
        enum State: Equatable {
            case asking
            case answered(String)
            case failed(SessionQuestions.Failure)
        }

        /// The session asked.
        var session: String
        /// What you asked, in your words; nil for why: why you got a comment, or why a build failed.
        var asked: String?
        var askedAt: Date
        var state: State
        /// When it was answered, or failed.
        var endedAt: Date?
        /// What the session answered before, which it follows up on: asked in the session instead, it goes along.
        var earlier: CopilotAnswer?
        /// For a build, the run it's about: another run of it, as it runs again or after a push, isn't what it answered.
        var run: Int?
        /// For a build, when the attempt of its run it's about finished, as its check said: rerunning its failed jobs makes
        /// another attempt, under the same ID, which isn't what it answered either.
        var attempt: Date?

        var isAsking: Bool { state == .asking }

        /// Whether it's about a build's run as it is now: the run it asked about, by its ID, and the attempt of it, by when
        /// its check said it finished. One asked without them, or of a run whose ID isn't known, is.
        func isAbout(run: Int?, attempt: Date?) -> Bool {
            if let asked = self.run, let run, asked != run { return false }
            if let asked = self.attempt, asked != attempt { return false }
            return true
        }
    }

    @Published private(set) var questions: [Key: Question] = [:]

    let copilot: CopilotTasksStore
    /// Stands in for the Copilot CLI, in tests.
    var askForTests: ((_ prompt: String, _ session: String) async -> Result<String, SessionQuestions.Failure>)?
    /// How long the demo takes to answer.
    var demoDelay: Duration = .seconds(1.5)
    private lazy var sessions = SessionQuestions(
        leftovers: copilot.settings, loadEnvironment: { [weak copilot] in await copilot?.environment() ?? [:] }
    )
    private var asking: [Key: Task<Void, Never>] = [:]
    private var hasStopped = false
    private var subscriptions: Set<AnyCancellable> = []

    init(copilot: CopilotTasksStore) {
        self.copilot = copilot
        // Turned off, what's being asked stops, and what was answered goes.
        copilot.settings.$copilotEnabled.removeDuplicates().dropFirst()
            .sink { [weak self] isOn in
                guard !isOn else { return }
                MainActor.assumeIsolated { self?.forgetAll() }
            }
            .store(in: &subscriptions)
    }

    /// Whether Explain can ask a session now: Send Work to Copilot is on, outside the demo, or in it, with its made-up
    /// answers.
    var canAsk: Bool {
        !hasStopped && copilot.isOn && (copilot.canSend || copilot.mode == .demo)
    }

    func question(about part: PullRequestPart, of key: PRKey) -> Question? {
        questions[Key(pullRequest: key, part: part)]
    }

    /// Asks a session about something of a pull request, in place of what was asked about it before, which stops if it's
    /// still being asked.
    /// - Parameters:
    ///   - prompt: the question in full, such as `PullRequestPrompt.explainThread`'s.
    ///   - asked: what you asked, in your words, to show with the answer.
    ///   - earlier: what the session answered before, which it follows up on.
    ///   - run: for a build, the run it's about.
    ///   - attempt: for a build, when the attempt of its run it's about finished, as its check said.
    func ask(
        _ prompt: String, asked: String?, earlier: CopilotAnswer? = nil, session: String, about part: PullRequestPart, run: Int? = nil,
        attempt: Date? = nil, of key: PRKey
    ) {
        guard canAsk else { return }
        let id = Key(pullRequest: key, part: part)
        asking.removeValue(forKey: id)?.cancel()
        let words = asked?.trimmingCharacters(in: .whitespacesAndNewlines)
        let question = Question(
            session: session, asked: words?.isEmpty == false ? words : nil, askedAt: Date(), state: .asking, earlier: earlier, run: run,
            attempt: attempt
        )
        questions[id] = question
        Log.app.info("Asked a Copilot session about a pull request")
        asking[id] = Task { [weak self] in
            guard let self else { return }
            let result = await self.answer(prompt, session: session, about: part, of: key)
            // Stopped, or asked again, meanwhile: this answer isn't wanted.
            guard !Task.isCancelled, self.questions[id] == question else { return }
            self.asking[id] = nil
            var answered = question
            answered.endedAt = Date()
            switch result {
            case .success(let text): answered.state = .answered(text)
            case .failure(let failure):
                answered.state = .failed(failure)
                Log.app.error("A Copilot session couldn't answer a question about a pull request")
            }
            self.questions[id] = answered
        }
    }

    private func answer(_ prompt: String, session: String, about part: PullRequestPart, of key: PRKey) async -> Result<String, SessionQuestions.Failure> {
        if let askForTests { return await askForTests(prompt, session) }
        if copilot.mode == .demo {
            do {
                try await Task.sleep(for: demoDelay)
            } catch {
                return .failure(.cancelled)
            }
            return .success(Self.demoAnswer(about: part, of: key))
        }
        let sessions = sessions
        let work = Task.detached { await sessions.ask(prompt, session: session) }
        // Stopping it stops Copilot, and deletes its fork.
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    /// What the demo says a session answers, made up.
    static func demoAnswer(about part: PullRequestPart, of key: PRKey) -> String {
        switch part {
        case .thread(let thread): DemoData.explanation(ofThread: thread, pullRequest: key.number)
        case .build: DemoData.buildExplanation(pullRequest: key.number)
        case .conflicts: DemoData.conflictsExplanation(pullRequest: key.number)
        }
    }

    /// Stops what's being asked about something; its fork is deleted.
    func stop(about part: PullRequestPart, of key: PRKey) {
        let id = Key(pullRequest: key, part: part)
        asking.removeValue(forKey: id)?.cancel()
        questions[id] = nil
    }

    /// Forgets what was asked and answered about something.
    func dismiss(about part: PullRequestPart, of key: PRKey) {
        stop(about: part, of: key)
    }

    private func forgetAll() {
        asking.values.forEach { $0.cancel() }
        asking = [:]
        questions = [:]
    }

    /// Stops for good, when Azure DevOps stops: what's being asked stops too.
    func stopAll() {
        hasStopped = true
        subscriptions = []
        forgetAll()
    }
}
