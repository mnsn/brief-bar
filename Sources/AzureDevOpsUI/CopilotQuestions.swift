import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Combine
import CopilotTasks
import Foundation

/// What you ask Copilot sessions about pull requests with Explain, about a comment thread, a failed build or conflicts, and
/// what they answer: each asked aside, of a throwaway fork of the session with no tools, which the Copilot CLI deletes after
/// (`SessionQuestions`), so it changes no file and the session's history stays as it was. Each question sends the session's
/// conversation, with what it's about, such as a thread and its code or a build's errors, failed tests and the end of its
/// log, to GitHub Copilot, as one premium request. What's asked and answered stays in memory only, until you dismiss it,
/// BriefBar quits, or Send Work to Copilot or Azure DevOps is turned off, which stops what's being asked. The demo makes its
/// answers up, and never runs the Copilot CLI. It asks for Ask… on any of your Copilot sessions too (`SessionAsks`), the
/// same way, while Send Work to Copilot is on.
@MainActor
final class CopilotQuestions: ObservableObject {
    /// Something of a pull request: for a build, a run of it, since two of a pull request's policies can run the same
    /// pipeline, and each run is asked about on its own row.
    struct Key: Hashable {
        var pullRequest: PRKey
        var part: PullRequestPart
        var run: Int?
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
        /// For conflicts, the pull request's branches as it was asked about them: after a push or a retarget they conflict
        /// otherwise, so what it answered isn't about them as they are.
        var head: PullRequestFilesStore.Head?

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
    /// Ask… on any of your Copilot sessions, which it gives a way to ask while Send Work to Copilot is on.
    private weak var asks: SessionAsks?
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

    /// - Parameter asks: Ask… on any of your Copilot sessions, which it asks for too, while Send Work to Copilot is on.
    init(copilot: CopilotTasksStore, asks: SessionAsks? = nil) {
        self.copilot = copilot
        self.asks = asks
        offerAsks(copilot.isOn)
        // Turned off, what's being asked stops, and what was answered goes, and Ask… with it. Published before it's set.
        copilot.settings.$copilotEnabled.removeDuplicates().dropFirst()
            .sink { [weak self] isOn in
                MainActor.assumeIsolated {
                    if !isOn { self?.forgetAll() }
                    self?.offerAsks(isOn)
                }
            }
            .store(in: &subscriptions)
    }

    /// Whether Explain can ask a session now: Send Work to Copilot is on, outside the demo, or in it, with its made-up
    /// answers.
    var canAsk: Bool {
        !hasStopped && copilot.isOn && (copilot.canSend || copilot.mode == .demo)
    }

    /// What was asked about something of a pull request: for a build, about that run of it.
    func question(about part: PullRequestPart, run: Int? = nil, of key: PRKey) -> Question? {
        questions[Key(pullRequest: key, part: part, run: run)]
    }

    /// Asks a session about something of a pull request, in place of what was asked about it before, which stops if it's
    /// still being asked.
    /// - Parameters:
    ///   - prompt: the question in full, such as `PullRequestPrompt.explainThread`'s.
    ///   - asked: what you asked, in your words, to show with the answer.
    ///   - earlier: what the session answered before, which it follows up on.
    ///   - run: for a build, the run it's about.
    ///   - attempt: for a build, when the attempt of its run it's about finished, as its check said.
    ///   - head: for conflicts, the pull request's branches as the question is written for them.
    func ask(
        _ prompt: String, asked: String?, earlier: CopilotAnswer? = nil, session: String, about part: PullRequestPart, run: Int? = nil,
        attempt: Date? = nil, head: PullRequestFilesStore.Head? = nil, of key: PRKey
    ) {
        guard canAsk else { return }
        let id = Key(pullRequest: key, part: part, run: run)
        asking.removeValue(forKey: id)?.cancel()
        let words = asked?.trimmingCharacters(in: .whitespacesAndNewlines)
        let question = Question(
            session: session, asked: words?.isEmpty == false ? words : nil, askedAt: Date(), state: .asking, earlier: earlier, run: run,
            attempt: attempt, head: head
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

    /// Dismisses what was asked about pull requests' builds that's no longer about one of their runs as the list read them
    /// last: a run a newer one replaced, as after a push, or another attempt of one, as when its failed jobs ran again under
    /// the same ID. What it answered isn't about the build as it is, and Ask More and Fix would build on it; what's still
    /// being asked stops. A pull request whose builds weren't read, or whose policies couldn't be, keeps them. So goes what
    /// was asked about a pull request's conflicts once someone pushed to it or retargeted it since: they conflict otherwise
    /// now, and Ask More and Resolve would build on it.
    /// - Parameter records: the pull requests as the list read them last.
    func dismissStale(of records: [PRRecord]) {
        let listed = Dictionary(records.map { ($0.pullRequest.key, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, question) in questions {
            if case .conflicts = id.part {
                guard let asked = question.head, let record = listed[id.pullRequest] else { continue }
                if PullRequestFilesStore.Head(record.pullRequest) != asked { stop(about: id.part, run: id.run, of: id.pullRequest) }
                continue
            }
            guard case .build = id.part, let details = listed[id.pullRequest]?.details, details.checksKnown else { continue }
            let checks = details.checks
            let current = checks.contains { check in
                check.part == id.part && check.buildId == id.run && question.isAbout(run: check.buildId, attempt: check.completedAt)
            }
            if !current { stop(about: id.part, run: id.run, of: id.pullRequest) }
        }
    }

    /// Stops what's being asked about something, for a build about that run of it; its fork is deleted.
    func stop(about part: PullRequestPart, run: Int? = nil, of key: PRKey) {
        let id = Key(pullRequest: key, part: part, run: run)
        asking.removeValue(forKey: id)?.cancel()
        questions[id] = nil
    }

    /// Forgets what was asked and answered about something, for a build about that run of it.
    func dismiss(about part: PullRequestPart, run: Int? = nil, of key: PRKey) {
        stop(about: part, run: run, of: key)
    }

    private func forgetAll() {
        asking.values.forEach { $0.cancel() }
        asking = [:]
        questions = [:]
    }

    /// Stops for good, when Azure DevOps stops: what's being asked stops too, and Ask… goes.
    func stopAll() {
        hasStopped = true
        subscriptions = []
        forgetAll()
        asks?.setAsker(nil)
    }

    // MARK: Ask…

    /// Gives Ask… a way to ask while Send Work to Copilot is on, outside the demo, or in it, with its made-up answers; takes
    /// it away while it's off, which stops what Ask… asks and forgets what it was answered.
    /// - Parameter isOn: whether Send Work to Copilot is on, as it is now, or is about to be.
    private func offerAsks(_ isOn: Bool) {
        guard let asks else { return }
        guard isOn, !hasStopped, copilot.canSend || copilot.mode == .demo else {
            asks.setAsker(nil)
            return
        }
        asks.setAsker { [weak self] request in
            guard let self else { return .failure(SessionAsks.Problem(SessionQuestions.Failure.cancelled.message(model: nil))) }
            return await answer(request)
        }
    }

    /// What a session answers Ask… (`SessionAsks`), asked as Explain asks: aside, of a throwaway fork of the session with no
    /// tools, through the same Copilot CLI, with your shell's environment and the forks still to delete, with the session's
    /// own model; or, in the demo, made up, running nothing. Why there's none, in `SessionQuestions.Failure`'s words.
    /// Cancelled, it stops, and the fork is deleted.
    func answer(_ request: SessionAsks.Request) async -> Result<String, SessionAsks.Problem> {
        let result: Result<String, SessionQuestions.Failure>
        if !canAsk {
            result = .failure(.cancelled)
        } else if let askForTests {
            result = await askForTests(request.prompt, request.session)
        } else if copilot.mode == .demo {
            do {
                try await Task.sleep(for: demoDelay)
                result = .success(DemoData.sessionAnswer(session: request.session, question: request.question))
            } catch {
                result = .failure(.cancelled)
            }
        } else {
            let sessions = sessions
            let prompt = request.prompt, id = request.session
            let work = Task.detached { await sessions.ask(prompt, session: id) }
            // Stopping it stops Copilot, and deletes its fork.
            result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        }
        return result.mapError { SessionAsks.Problem($0.message(model: nil), detail: $0.detail) }
    }
}
