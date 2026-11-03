import AzureDevOpsCore
import BriefBarCore
import Combine
import CopilotTasks
import Foundation

/// What you ask Copilot sessions about pull requests' comment threads with Explain, and what they answer: each asked aside,
/// of a throwaway fork of the session with no tools, which the Copilot CLI deletes after (`SessionQuestions`), so it changes
/// no file and the session's history stays as it was. Each question sends the session's conversation, with the thread and
/// its code, to GitHub Copilot, as one premium request. What's asked and answered stays in memory only, until you dismiss
/// it, BriefBar quits, or Send Work to Copilot or Azure DevOps is turned off, which stops what's being asked. The demo
/// makes its answers up, and never runs the Copilot CLI.
@MainActor
final class CommentQuestions: ObservableObject {
    /// A thread of a pull request.
    struct Key: Hashable {
        var pullRequest: PRKey
        var thread: Int
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
        /// What you asked, in your words; nil for why you got it.
        var asked: String?
        var askedAt: Date
        var state: State
        /// When it was answered, or failed.
        var endedAt: Date?

        var isAsking: Bool { state == .asking }
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

    func question(on thread: Int, of key: PRKey) -> Question? {
        questions[Key(pullRequest: key, thread: thread)]
    }

    /// Asks a session about a thread, in place of what was asked about it before, which stops if it's still being asked.
    /// - Parameters:
    ///   - prompt: the question in full (`PullRequestPrompt.explainThread`).
    ///   - asked: what you asked, in your words, to show with the answer.
    func ask(_ prompt: String, asked: String?, session: String, on thread: Int, of key: PRKey) {
        guard canAsk else { return }
        let id = Key(pullRequest: key, thread: thread)
        asking.removeValue(forKey: id)?.cancel()
        let words = asked?.trimmingCharacters(in: .whitespacesAndNewlines)
        let question = Question(session: session, asked: words?.isEmpty == false ? words : nil, askedAt: Date(), state: .asking)
        questions[id] = question
        Log.app.info("Asked a Copilot session about a comment thread")
        asking[id] = Task { [weak self] in
            guard let self else { return }
            let result = await self.answer(prompt, session: session, thread: thread, of: key)
            // Stopped, or asked again, meanwhile: this answer isn't wanted.
            guard !Task.isCancelled, self.questions[id] == question else { return }
            self.asking[id] = nil
            var answered = question
            answered.endedAt = Date()
            switch result {
            case .success(let text): answered.state = .answered(text)
            case .failure(let failure):
                answered.state = .failed(failure)
                Log.app.error("A Copilot session couldn't answer a question about a comment thread")
            }
            self.questions[id] = answered
        }
    }

    private func answer(_ prompt: String, session: String, thread: Int, of key: PRKey) async -> Result<String, SessionQuestions.Failure> {
        if let askForTests { return await askForTests(prompt, session) }
        if copilot.mode == .demo {
            do {
                try await Task.sleep(for: demoDelay)
            } catch {
                return .failure(.cancelled)
            }
            return .success(DemoData.explanation(ofThread: thread, pullRequest: key.number))
        }
        let sessions = sessions
        let work = Task.detached { await sessions.ask(prompt, session: session) }
        // Stopping it stops Copilot, and deletes its fork.
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    /// Stops what's being asked about a thread; its fork is deleted.
    func stop(on thread: Int, of key: PRKey) {
        let id = Key(pullRequest: key, thread: thread)
        asking.removeValue(forKey: id)?.cancel()
        questions[id] = nil
    }

    /// Forgets what a thread was asked and answered.
    func dismiss(on thread: Int, of key: PRKey) {
        stop(on: thread, of: key)
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
