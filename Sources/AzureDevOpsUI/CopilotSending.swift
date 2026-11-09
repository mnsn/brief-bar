import AzureDevOpsCore
import BriefBarCore
import CopilotTasks
import Foundation

/// What a composer in place asks Copilot about something of a pull request: a comment thread, a build, its conflicts.
enum CopilotAsk: Equatable, Hashable, Sendable {
    /// Why it's there, what it wants, and ways to address it: asked aside of a session that knows the change.
    case explain
    /// Address it, as you say: fix a thread or a build, or resolve the conflicts.
    case fix
    /// Address the comment threads that wait on you, as Fix Comments does.
    case fixAll

    /// Its title, for what it's about: "Explain", "Explain the Failure", "Fix", "Resolve", "Fix All".
    func title(about part: PullRequestPart?) -> String {
        switch (self, part) {
        case (.explain, .build?): "Explain the Failure"
        case (.explain, .conflicts?): "Explain the Conflicts"
        case (.explain, _): "Explain"
        case (.fix, .conflicts?): "Resolve"
        case (.fix, _): "Fix"
        case (.fixAll, _): "Fix All"
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

    /// Its button, for what it's about: "Ask", "Fix", "Resolve", "Fix All".
    func sendTitle(about part: PullRequestPart?) -> String {
        switch self {
        case .explain: "Ask"
        case .fix, .fixAll: title(about: part)
        }
    }

    /// Fix All's title, which says what it takes on: "Fix All" while every open thread waits on you, else how many do,
    /// "Fix 1 Comment", which leaves the others.
    static func fixAllTitle(waiting: Int, open: Int) -> String {
        if waiting >= open { return "Fix All" }
        return waiting == 1 ? "Fix 1 Comment" : "Fix \(waiting) Comments"
    }

    /// Fix All's title for a pull request: of all its unresolved threads, as Fix Comments takes them on, whichever its
    /// details show, Active or All.
    static func fixAllTitle(_ record: PRRecord) -> String {
        let open = (record.details?.threads ?? []).filter { !$0.isResolved }.count
        return fixAllTitle(waiting: PullRequestPrompt.waitingThreads(record).count, open: open)
    }
}

/// Where a composer's prompt goes.
enum CopilotDestination: Hashable, Sendable {
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

/// The sessions a composer's ▾ offers, in its order: the session that worked on what it's about, if one did, else the pull
/// request's (`PullRequestSession`), first; for a fix, a fork of it and a new session; then the other sessions that go with
/// the pull request, as its line ranks them, and the one whose log only mentions it; then the Copilot app's other sessions.
struct CopilotDestinations {
    struct Entry: Identifiable {
        var destination: CopilotDestination
        var choice: SessionChoice?
        var id: CopilotDestination { destination }
    }

    /// The session that worked on it, or the pull request's, and, for a fix, a fork of it and a new session.
    var first: [Entry]
    /// The other sessions that go with the pull request.
    var more: [Entry]
    /// The Copilot app's other sessions.
    var others: [Entry]
    /// Where it goes unless you choose: nil while the pull request's sessions ask which is its, or none is there to ask.
    var preselected: CopilotDestination?

    var all: [Entry] { first + more + others }

    /// - Parameters:
    ///   - worked: the session that worked on what it's about, by its ID.
    static func make(_ session: PullRequestSession?, worked: String?, ask: CopilotAsk) -> CopilotDestinations {
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
        var preselected: CopilotDestination?
        if let lead {
            // A fork of one of BriefBar's tasks works in a worktree of its own, so a busy one's goes instead.
            preselected = ask != .explain && lead.isUnavailable && forksWithTheCLI(lead) ? .fork(lead.id) : .session(lead.id)
        } else if ask != .explain, case .newSession? = session?.pick {
            preselected = .newSession
        }
        return CopilotDestinations(first: first, more: more, others: others, preselected: preselected)
    }

    func choice(for destination: CopilotDestination?) -> SessionChoice? {
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

/// Sends what a composer in place asks about something of a pull request to where you chose: a fix, of a thread, of those
/// that wait on you, of a build or of its conflicts, to a session that's there already, as the Send to Copilot window would
/// send it (`PullRequestSession.Delivery`), to a fork of it, or to a new session; or an explanation, as a prompt, when it
/// can't be asked aside. Each prompt it sends takes what it hands to Copilot off Needs You, and is kept with what it took on,
/// for each to say what became of it.
@MainActor
struct CopilotSending {
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

    /// What a fix sends: its prompts, for a worktree of BriefBar's, detached at the pull request's latest commit, and for a
    /// session that works wherever it is; what it asks Copilot to do, which says what it may, such as Fix the Build, which
    /// doesn't commit or push, or a comment's fix sent with Push and Reply on, a Push & Reply that fixes them first
    /// (`fixes`); what it takes on; and what it takes off Needs You once it's sent.
    struct Fix {
        var prompts: (worktree: String, session: String)
        var action: PullRequestAction
        var parts: [PullRequestPart]
        var handOff: CommentHandOff?
        /// The pull request as its prompts quote it, when they're written after a wait, as for the files its conflicts are in,
        /// or the code a comment is on, pushed to or retargeted meanwhile or not: what's kept with what it takes on, such as
        /// the branch its conflicts are with, and the task it starts, go by it too, as do the checks of a push, against the
        /// branch its prompt names, though its sender read the pull request again since, as Edit the Whole Prompt… does.
        /// Nil for the pull request as the fix was asked for.
        var record: PRRecord?
        /// For a thread's fix, the change suggested in it that it applies as written, for Try Again to apply it again.
        var suggestion: CommentSuggestion?
        /// A Push & Reply that fixes the threads it takes on first, then commits, pushes and replies on them: a comment's
        /// fix sent with Push and Reply on (`TakenPart.fixes`). It goes as Push & Reply goes, with its checks.
        var fixes = false

        /// It pushes: Push & Reply, or a fix sent to push and reply, which goes only once what it would push is checked.
        var pushes: Bool { action == .pushAndReply }

        /// Its prompts as they're sent: ending asking the session to tell BriefBar the pull request's stage once it pushed,
        /// while Pull Request Order is on (`asksForStage`), unless it's a review.
        func sent(asksForStage: Bool) -> (worktree: String, session: String) {
            let asks = asksForStage && action.asksForStage
            return (
                PromptTemplate.ending(prompts.worktree, asksForStage: asks), PromptTemplate.ending(prompts.session, asksForStage: asks)
            )
        }
    }

    var task: TaskPullRequest { PullRequestTasks.task(for: record) }

    /// Sends a fix where you chose: to a task's session with the Copilot CLI, or to one of the Copilot app's sessions through
    /// BriefBar's extension in it, or copied for you to paste there, as the Send to Copilot window would; to a fork of
    /// either; or to a new session in a worktree of the local clone BriefBar knows, or else the window, to choose one.
    /// - Returns: what became of it; and, once it went, or was copied, when what it takes on was taken on, by the task it
    ///   starts or the prompt it sent, for what's kept of the fix to go with that attempt alone (`CopilotTasksStore.FixWords`).
    func fix(_ fix: Fix, to destination: CopilotDestination, choice: SessionChoice?) async -> (outcome: Outcome, takenAt: Date?) {
        guard copilot.canSend, copilot.isOn else { return (.notSent(CopilotTasksStore.cantSendNow), nil) }
        guard !Task.isCancelled else { return (.notSent(Self.calledOff), nil) }
        // Gone from your lists, completed or abandoned while it waited for what its prompts quote: nothing goes.
        guard isOpen else { return (.notSent(Self.pullRequestGone), nil) }
        let record = fix.record ?? self.record
        let task = PullRequestTasks.task(for: record)
        let prompts = fix.sent(asksForStage: copilot.asksForStage)
        let about = SentPrompt.About(
            pullRequest: item.key, purpose: fix.pushes ? .pushAndReply : .fix, parts: fix.parts, target: record.pullRequest.targetBranch,
            fixes: fix.fixes
        )
        let subject = TaskSubject.pullRequest(task, fix.action)
        let options = copilot.settings.copilotOptions
        // A task it starts: when, or, once nothing starts, that it can't send now.
        func started(_ at: Date?) -> (outcome: Outcome, takenAt: Date?) {
            at.map { (.sent, $0) } ?? (.notSent(CopilotTasksStore.cantSendNow), nil)
        }
        // A prompt it delivers, as delivering it starts: one that pushes, only once what the session's folder would push is
        // checked, as Push & Reply's.
        func delivered(forking: Bool = false, to choice: SessionChoice) async -> (outcome: Outcome, takenAt: Date?) {
            let at = Date()
            let outcome = Self.outcome(await copilot.deliver(
                prompts.session, to: choice, forking: forking, handOff: fix.handOff, about: about, at: at, checkingPush: fix.pushes ? task : nil
            ))
            switch outcome {
            case .sent, .copied: return (outcome, at)
            case .notSent, .needsWindow: return (outcome, nil)
            }
        }
        switch destination {
        case .session(let id):
            guard let choice else { return (.notSent(Self.gone), nil) }
            let known = session?.session?.id == id ? session?.delivery : nil
            let delivery: PullRequestSession.Delivery
            if let known {
                delivery = known
            } else {
                delivery = await copilot.delivery(to: choice, for: task, checksRepository: true)
            }
            // Called off while it looked, as its composer closed: nothing starts.
            guard !Task.isCancelled else { return (.notSent(Self.calledOff), nil) }
            switch delivery {
            case .cli:
                guard let run = choice.run ?? choice.appSession.flatMap({ copilot.appRun(for: $0, subject: subject, options: options) }) else {
                    return (.notSent("BriefBar can't tell which folder it works in."), nil)
                }
                if let busy = copilot.busyReason(for: choice) { return (.notSent(busy), nil) }
                return started(copilot.send(
                    subject, prompt: run.worksInPullRequestWorktree ? prompts.worktree : prompts.session, options: options,
                    repository: run.repository, continuing: run, parts: fix.parts, handOff: fix.handOff, fixing: fix.fixes
                ))
            case .app:
                return await delivered(to: choice)
            case .busy(let why), .unavailable(let why):
                return (.notSent(why), nil)
            }
        case .fork:
            guard let choice else { return (.notSent(Self.gone), nil) }
            if CopilotDestinations.forksWithTheCLI(choice), let run = choice.run {
                return started(copilot.send(
                    subject, prompt: prompts.session, options: options, repository: run.repository, forking: run, parts: fix.parts,
                    handOff: fix.handOff, fixing: fix.fixes
                ))
            }
            return await delivered(forking: true, to: choice)
        case .newSession:
            let repository = try? await copilot.repository(for: task, using: copilot.git())
            guard !Task.isCancelled else { return (.notSent(Self.calledOff), nil) }
            guard let repository else { return (.needsWindow, nil) }
            return started(copilot.send(
                subject, prompt: prompts.worktree, options: options, repository: repository.root, parts: fix.parts, handOff: fix.handOff,
                fixing: fix.fixes
            ))
        }
    }

    /// Asks a session about something as a prompt it takes up itself, as a fix goes, for when it can't be asked aside: in its
    /// own history, where it reads the code too, but changes nothing.
    func explainAsPrompt(_ prompt: String, about part: PullRequestPart, to choice: SessionChoice) async -> Outcome {
        guard copilot.canSend, copilot.isOn else { return .notSent(CopilotTasksStore.cantSendNow) }
        guard isOpen else { return .notSent(Self.pullRequestGone) }
        let about = SentPrompt.About(pullRequest: item.key, purpose: .explain, parts: [part], target: record.pullRequest.targetBranch)
        return Self.outcome(await copilot.deliver(prompt, to: choice, about: about))
    }

    /// Opens the Send to Copilot window with a fix's prompts, going where you chose, for the whole prompt, the model, and
    /// more places it can go.
    func openWindow(_ fix: Fix, destination: CopilotDestination?, choice: SessionChoice?) {
        var forking = false
        if case .fork? = destination { forking = true }
        let record = fix.record ?? self.record
        CopilotComposer.shared.show(
            subject: .pullRequest(PullRequestTasks.task(for: record), fix.action), prompt: fix.prompts.worktree,
            sessionPrompt: fix.prompts.session, createdAt: record.pullRequest.createdAt, options: copilot.settings.copilotOptions,
            continuing: copilot.continuable(forPullRequest: item.key), handOff: fix.handOff,
            session: destination == .newSession ? .newSession : choice.map { .session($0, forking: forking) },
            parts: fix.parts, fixes: fix.fixes, store: copilot
        )
    }

    /// Whether the pull request is still open in your lists: one that left them, or was completed or abandoned, gets
    /// nothing more.
    var isOpen: Bool { Self.isOpen(item.key, in: store) }

    static func isOpen(_ key: PRKey, in store: PRStore) -> Bool {
        store.record(for: key)?.pullRequest.status == .active
    }

    static let pullRequestGone = "This pull request isn't open in your lists anymore, so nothing went."
    static let gone = "BriefBar can't find that session now. Choose another."
    /// Its composer closed before it went.
    static let calledOff = "It was called off before it went."

    static func outcome(_ delivery: SessionDelivery) -> Outcome {
        switch delivery {
        case .sent, .forkedAndSent: .sent
        case .fellBack(let fallback): .copied(CopilotComposerView.fallbackNote(fallback))
        case .notSent(let why): .notSent(why)
        }
    }
}

// MARK: - Comments

extension CopilotSending {
    /// A comment's fix: of one thread, as you say, by applying a suggested change, building on what a session answered of it
    /// with Explain; or, without one, of those that wait on you, as Fix Comments does. It takes on the thread, or those Fix
    /// Comments lists, and takes what waits on you in them off Needs You, as its prompt is written now, on your own pull
    /// request only. Sent with Push and Reply on (`ships`), it's a Push & Reply that fixes them first, which commits, pushes
    /// and replies on them once it's done, and goes as Push & Reply does, with its checks; else it leaves its changes for
    /// you to check, then push with Push & Reply.
    func commentFix(
        _ thread: ReviewThread?, how: String?, suggestion: CommentSuggestion?, answer: CopilotAnswer? = nil, excerpt: ThreadExcerpt?,
        ships: Bool = false
    ) -> Fix {
        let action: PullRequestAction = ships ? .pushAndReply : .fixComments
        guard let thread else {
            return Fix(
                prompts: (
                    PullRequestPrompt.fixComments(record, workplace: .worktree, note: how, ships: ships),
                    PullRequestPrompt.fixComments(record, workplace: .agent, note: how, ships: ships)
                ),
                action: action, parts: PullRequestTasks.parts(.fixComments, for: record), handOff: store.commentHandOff(.fixComments, for: record),
                record: record, fixes: ships
            )
        }
        var handOff: CommentHandOff?
        if record.role == .author {
            handOff = CommentHandOff(
                record, thread: thread.id, dismissedCutoff: store.dismissedCutoff(for: record.id),
                read: store.settings.readThreads(of: record.id), account: store.settings.account
            )
        }
        return Fix(
            prompts: (
                PullRequestPrompt.fixThread(
                    record, thread: thread, code: excerpt, how: how, applying: suggestion, answer: answer, workplace: .worktree, ships: ships
                ),
                PullRequestPrompt.fixThread(
                    record, thread: thread, code: excerpt, how: how, applying: suggestion, answer: answer, workplace: .agent, ships: ships
                )
            ),
            action: action, parts: [.thread(thread.id)], handOff: handOff, record: record, suggestion: suggestion, fixes: ships
        )
    }
}
