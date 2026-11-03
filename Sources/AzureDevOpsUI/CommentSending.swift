import AzureDevOpsCore
import BriefBarCore
import CopilotTasks
import Foundation

/// What a composer in place asks Copilot about a pull request's comments.
enum CommentAsk: Equatable, Hashable, Sendable {
    /// Why a thread was written, what it wants, and ways to address it: asked aside of a session that knows the change.
    case explain
    /// Address one thread, as you say, or by applying a suggested change.
    case fix
    /// Address the threads that wait on you, as Fix Comments does.
    case fixAll

    /// "Explain", "Fix", "Fix All".
    var title: String {
        switch self {
        case .explain: "Explain"
        case .fix: "Fix"
        case .fixAll: "Fix All"
        }
    }

    var symbol: String {
        switch self {
        case .explain: "sparkles"
        case .fix, .fixAll: "wrench.and.screwdriver"
        }
    }

    /// What its field asks for: what a question follows up on is shown above it.
    func placeholder(followingUp: Bool = false) -> String {
        switch self {
        case .explain: followingUp ? "What else do you want to know? (optional)" : "What do you want to know? (optional)"
        case .fix, .fixAll: "Tell Copilot how (optional)"
        }
    }

    /// Its button: "Ask", "Fix", "Fix All".
    var sendTitle: String {
        switch self {
        case .explain: "Ask"
        case .fix: "Fix"
        case .fixAll: "Fix All"
        }
    }

    /// Fix All's title, which says what it takes on: "Fix All" while every open thread waits on you, else how many do,
    /// "Fix 1 Comment", which leaves the others.
    static func fixAllTitle(waiting: Int, open: Int) -> String {
        if waiting >= open { return "Fix All" }
        return waiting == 1 ? "Fix 1 Comment" : "Fix \(waiting) Comments"
    }
}

/// Where a composer's prompt goes.
enum CommentDestination: Hashable, Sendable {
    /// A session that's there already, by its ID.
    case session(String)
    /// A fork of one, with its history, which works on it while the session stays as it is.
    case fork(String)
    /// A new session, in a worktree at the pull request's latest commit.
    case newSession

    /// The session it goes to, or forks.
    var sessionID: String? {
        switch self {
        case .session(let id), .fork(let id): id
        case .newSession: nil
        }
    }
}

/// The sessions a composer's ▾ offers, in its order: the session that worked on the thread, if one did, else the pull
/// request's (`PullRequestSession`), first; for a fix, a fork of it and a new session; then the other sessions that go with
/// the pull request, as its line ranks them, and the one whose log only mentions it; then the Copilot app's other sessions.
struct CommentDestinations {
    struct Entry: Identifiable {
        var destination: CommentDestination
        var choice: SessionChoice?
        var id: CommentDestination { destination }
    }

    /// The session that worked on it, or the pull request's, and, for a fix, a fork of it and a new session.
    var first: [Entry]
    /// The other sessions that go with the pull request.
    var more: [Entry]
    /// The Copilot app's other sessions.
    var others: [Entry]
    /// Where it goes unless you choose: nil while the pull request's sessions ask which is its, or none is there to ask.
    var preselected: CommentDestination?

    var all: [Entry] { first + more + others }

    /// - Parameters:
    ///   - worked: the session that worked on the thread, by its ID.
    static func make(_ session: PullRequestSession?, worked: String?, ask: CommentAsk) -> CommentDestinations {
        var known: [SessionChoice] = []
        for choice in (session?.candidates ?? []) + [session?.guess].compactMap({ $0 }) + (session?.others ?? [])
        where !known.contains(where: { $0.id == choice.id }) {
            known.append(choice)
        }
        let picked = session?.session
        let lead = worked.flatMap { id in known.first { $0.id == id } } ?? picked
        var first: [Entry] = []
        if let lead {
            first.append(Entry(destination: .session(lead.id), choice: lead))
            if ask != .explain, canFork(lead) { first.append(Entry(destination: .fork(lead.id), choice: lead)) }
        }
        if ask != .explain, session?.canChoose != false { first.append(Entry(destination: .newSession, choice: nil)) }
        let listed = Set(first.compactMap(\.destination.sessionID))
        let likely = Set(((session?.candidates ?? []) + [session?.guess].compactMap { $0 }).map(\.id))
        let more = known.filter { likely.contains($0.id) && !listed.contains($0.id) }.map { Entry(destination: .session($0.id), choice: $0) }
        let others = known.filter { !likely.contains($0.id) && !listed.contains($0.id) }.map { Entry(destination: .session($0.id), choice: $0) }
        var preselected: CommentDestination?
        if let lead {
            // A fork of one of BriefBar's tasks works in a worktree of its own, so a busy one's goes instead.
            preselected = ask != .explain && lead.isUnavailable && forksWithTheCLI(lead) ? .fork(lead.id) : .session(lead.id)
        } else if ask != .explain, case .newSession? = session?.pick {
            preselected = .newSession
        }
        return CommentDestinations(first: first, more: more, others: others, preselected: preselected)
    }

    func choice(for destination: CommentDestination?) -> SessionChoice? {
        guard let destination else { return nil }
        return all.first { $0.destination == destination }?.choice
    }

    /// Whether a fix can go to a fork of a session: one of the Copilot app's, which the app forks, or one of BriefBar's own
    /// tasks, which the Copilot CLI forks. Not a chat.
    static func canFork(_ choice: SessionChoice) -> Bool {
        choice.canFork || (choice.run.map { $0.isAppSession != true } ?? false)
    }

    /// One of BriefBar's own tasks, which the Copilot CLI forks; the Copilot app forks its own sessions.
    static func forksWithTheCLI(_ choice: SessionChoice) -> Bool {
        choice.run.map { $0.isAppSession != true } ?? false
    }
}

/// Sends what a composer in place asks to where you chose: a fix, of one thread or of those that wait on you, to a session
/// that's there already, as the Send to Copilot window would send it (`PullRequestSession.Delivery`), to a fork of it, or to
/// a new session; or an explanation, as a prompt, when it can't be asked aside. Each prompt it sends takes what it hands to
/// Copilot off Needs You, and is kept with the threads it took on, for each to say what became of it.
@MainActor
struct CommentSending {
    let item: PRSnapshot
    let record: PRRecord
    let store: PRStore
    let copilot: CopilotTasksStore
    /// The pull request's session, as its details show it.
    let session: PullRequestSession?

    /// What became of it.
    enum Outcome: Equatable {
        /// Copilot has it: a task of BriefBar's is starting, or BriefBar sent it to the session.
        case sent
        /// BriefBar copied it for you to paste, and opened the session to paste it in: what it says about that.
        case copied(String)
        /// Nothing went: why.
        case notSent(String)
        /// It needs the Send to Copilot window, such as to choose a new session's local clone.
        case needsWindow
    }

    var task: TaskPullRequest { PullRequestTasks.task(for: record) }

    /// A fix's prompts, for a worktree of BriefBar's, detached at the pull request's latest commit, and for a session that
    /// works wherever it is: of one thread, building on what a session answered of it with Explain, or of those that wait
    /// on you without one.
    func fixPrompts(
        _ thread: ReviewThread?, how: String?, suggestion: CommentSuggestion?, answer: ThreadAnswer? = nil, excerpt: ThreadExcerpt?
    ) -> (worktree: String, session: String) {
        guard let thread else {
            return (PullRequestPrompt.fixComments(record, workplace: .worktree, note: how), PullRequestPrompt.fixComments(record, workplace: .agent, note: how))
        }
        return (
            PullRequestPrompt.fixThread(record, thread: thread, code: excerpt, how: how, applying: suggestion, answer: answer, workplace: .worktree),
            PullRequestPrompt.fixThread(record, thread: thread, code: excerpt, how: how, applying: suggestion, answer: answer, workplace: .agent)
        )
    }

    /// The threads a fix takes on: one, or those Fix Comments lists.
    func threads(of thread: ReviewThread?) -> [Int] {
        if let thread { return [thread.id] }
        return PullRequestPrompt.waitingThreads(record).prefix(PullRequestPrompt.threadLimit).map(\.id)
    }

    /// What a fix takes off Needs You once it's sent, as its prompt is written now: on your own pull request only.
    func handOff(of thread: ReviewThread?) -> CommentHandOff? {
        guard let thread else { return store.commentHandOff(.fixComments, for: record) }
        guard record.role == .author else { return nil }
        return CommentHandOff(record, thread: thread.id, dismissedCutoff: store.dismissedCutoff(for: record.id), account: store.settings.account)
    }

    /// Sends a fix where you chose: to a task's session with the Copilot CLI, or to one of the Copilot app's sessions through
    /// BriefBar's extension in it, or copied for you to paste there, as the Send to Copilot window would; to a fork of
    /// either; or to a new session in a worktree of the local clone BriefBar knows, or else the window, to choose one.
    func fix(
        _ thread: ReviewThread?, how: String?, suggestion: CommentSuggestion?, answer: ThreadAnswer? = nil, excerpt: ThreadExcerpt?,
        to destination: CommentDestination, choice: SessionChoice?
    ) async -> Outcome {
        guard copilot.canSend, copilot.isOn else { return .notSent(CopilotTasksStore.cantSendNow) }
        let prompts = fixPrompts(thread, how: how, suggestion: suggestion, answer: answer, excerpt: excerpt)
        let threads = threads(of: thread)
        let handOff = handOff(of: thread)
        let about = SentPrompt.About(pullRequest: item.key, purpose: .fix, threads: threads)
        let subject = TaskSubject.pullRequest(task, .fixComments)
        let options = copilot.settings.copilotOptions
        switch destination {
        case .session(let id):
            guard let choice else { return .notSent(Self.gone) }
            let known = session?.session?.id == id ? session?.delivery : nil
            let delivery: PullRequestSession.Delivery
            if let known {
                delivery = known
            } else {
                delivery = await copilot.delivery(to: choice, for: task, checksRepository: true)
            }
            switch delivery {
            case .cli:
                guard let run = choice.run ?? choice.appSession.flatMap({ copilot.appRun(for: $0, subject: subject, options: options) }) else {
                    return .notSent("BriefBar can't tell which folder it works in.")
                }
                if let busy = copilot.busyReason(for: choice) { return .notSent(busy) }
                copilot.send(
                    subject, prompt: run.worksInPullRequestWorktree ? prompts.worktree : prompts.session, options: options,
                    repository: run.repository, continuing: run, threads: threads, handOff: handOff
                )
                return .sent
            case .app:
                return Self.outcome(await copilot.deliver(prompts.session, to: choice, handOff: handOff, about: about))
            case .busy(let why), .unavailable(let why):
                return .notSent(why)
            }
        case .fork:
            guard let choice else { return .notSent(Self.gone) }
            if CommentDestinations.forksWithTheCLI(choice), let run = choice.run {
                copilot.send(subject, prompt: prompts.session, options: options, repository: run.repository, forking: run, threads: threads, handOff: handOff)
                return .sent
            }
            return Self.outcome(await copilot.deliver(prompts.session, to: choice, forking: true, handOff: handOff, about: about))
        case .newSession:
            guard let repository = try? await copilot.repository(for: task, using: copilot.git()) else { return .needsWindow }
            copilot.send(subject, prompt: prompts.worktree, options: options, repository: repository.root, threads: threads, handOff: handOff)
            return .sent
        }
    }

    /// Asks a session about a thread as a prompt it takes up itself, as a fix goes, for when it can't be asked aside: in its
    /// own history, where it reads the code too, but changes nothing.
    func explainAsPrompt(
        _ thread: ReviewThread, question: String?, earlier: ThreadAnswer? = nil, excerpt: ThreadExcerpt?, to choice: SessionChoice
    ) async -> Outcome {
        guard copilot.canSend, copilot.isOn else { return .notSent(CopilotTasksStore.cantSendNow) }
        let prompt = PullRequestPrompt.askAboutThread(record, thread: thread, code: excerpt, question: question, earlier: earlier)
        let about = SentPrompt.About(pullRequest: item.key, purpose: .explain, threads: [thread.id])
        return Self.outcome(await copilot.deliver(prompt, to: choice, about: about))
    }

    /// Opens the Send to Copilot window with a fix's prompts, going where you chose, for the whole prompt, the model, and
    /// more places it can go.
    func openWindow(
        _ thread: ReviewThread?, how: String?, suggestion: CommentSuggestion?, answer: ThreadAnswer? = nil, excerpt: ThreadExcerpt?,
        destination: CommentDestination?, choice: SessionChoice?
    ) {
        let prompts = fixPrompts(thread, how: how, suggestion: suggestion, answer: answer, excerpt: excerpt)
        var forking = false
        if case .fork? = destination { forking = true }
        CopilotComposer.shared.show(
            subject: .pullRequest(task, .fixComments), prompt: prompts.worktree, sessionPrompt: prompts.session,
            createdAt: record.pullRequest.createdAt, options: copilot.settings.copilotOptions,
            continuing: copilot.continuable(forPullRequest: item.key), handOff: handOff(of: thread),
            session: destination == .newSession ? .newSession : choice.map { .session($0, forking: forking) },
            threads: threads(of: thread), store: copilot
        )
    }

    static let gone = "BriefBar can't find that session now. Choose another."

    static func outcome(_ delivery: SessionDelivery) -> Outcome {
        switch delivery {
        case .sent, .forkedAndSent: .sent
        case .fellBack(let fallback): .copied(CopilotComposerView.fallbackNote(fallback))
        case .notSent(let why): .notSent(why)
        }
    }
}
