import AzureDevOpsCore
import BriefBarCore
import Combine
import Foundation

/// What you change in Azure DevOps from BriefBar, with **Make Changes in Azure DevOps** on: your replies in pull requests'
/// comment threads and their statuses (`ADOWrite`), each when you click it, in their details. What Azure DevOps answers
/// shows at once, and the pull request is read again (`PRStore.changed`). Nothing goes there otherwise, and the demo changes
/// only its own made-up data. What you write in a reply is kept here, in memory only, until it's sent or BriefBar stops
/// reading Azure DevOps: one that fails stays.
@MainActor
final class ThreadChanges: ObservableObject {
    /// A thread of a pull request.
    struct Key: Hashable {
        var pullRequest: PRKey
        var thread: Int
    }

    /// What a change to a thread is doing, or why it didn't happen.
    enum State: Equatable {
        case sending(Sending)
        /// It didn't happen, or may not have: what went wrong, and what it was.
        case failed(ADOWriteProblem, Sending)
    }

    /// A change being sent.
    enum Sending: Equatable {
        /// Your reply; then, for Reply & Resolve or Reply & Reactivate, the thread's status.
        case reply(then: ThreadStatus?)
        case status(ThreadStatus)

        var kind: ADOWrite.Kind {
            switch self {
            case .reply: .reply
            case .status: .setStatus
            }
        }
    }

    @Published private(set) var states: [Key: State] = [:]
    /// The replies you're writing, by thread. Not published: what you type redraws its own field only.
    private var drafts: [Key: String] = [:]
    /// When you resolved each thread you did here: what waited on you in it until then doesn't anymore, though its details
    /// show what was new as it was when they showed it (`waiting(_:of:)`).
    private var resolved: [Key: Date] = [:]
    /// The threads whose reply may have gone though it failed, as one Azure DevOps didn't answer in time, with what it said:
    /// until their threads, read again for it, tell, none is sent there.
    private var unsure: [Key: Attempt] = [:]
    /// The changes on their way to Azure DevOps, by thread: called off as replies go, when the setting is turned off, Azure
    /// DevOps stops or someone else signs in, so that one that hasn't gone yet, as one waiting for a token, never does.
    private var inFlight: [Key: Task<ADOWrite.Answer, Error>] = [:]
    /// How many times what was going on was called off (`forgetAll`): a change asked for before then does nothing more, as
    /// it comes back from what it waited for, though the setting is on again and another change on its thread is under way.
    private var generation = 0

    /// A reply that may have gone: what it said, and the comments its thread had before it was sent, by their IDs. A comment
    /// of yours that came since, which says the same, is it, whatever came after it.
    struct Attempt: Equatable {
        var markdown: String
        var before: Set<Int>
    }

    let settings: AppSettings
    /// Fix Grammar's models, for what you write in a reply.
    let grammar: GrammarFixer
    private weak var store: PRStore?
    /// Sends a change to Azure DevOps, as whom it was asked for as, when that's known: the client's; a test's stand-in.
    /// Never in the demo.
    var send: (ADOWrite, String?) async throws -> ADOWrite.Answer
    /// A pull request's threads as Azure DevOps has them now, read again for it, or nil when they couldn't be: the list's; a
    /// test's stand-in.
    var readThreads: @MainActor (PRKey) async -> [ReviewThread]?
    /// For the demo's made-up comments, and when you resolved a thread.
    var now: () -> Date = Date.init

    init(store: PRStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        grammar = GrammarFixer(isDemo: store.mode == .demo)
        let client = store.client
        send = { try await client.send($0, as: $1) }
        readThreads = { [weak store] key in await store?.threadsReadAgain(key) }
        // The demo shows them: they change only its made-up data.
        if store.mode == .demo { settings.makesChanges = true }
        // Turned off, threads show none of it, and what you wrote goes.
        settings.$makesChanges.removeDuplicates().dropFirst()
            .sink { [weak self] on in
                MainActor.assumeIsolated {
                    self?.objectWillChange.send()
                    if !on { self?.forgetAll() }
                }
            }
            .store(in: &cancellables)
    }

    private var cancellables: Set<AnyCancellable> = []

    // MARK: What you can do

    /// Whether you can change a pull request's threads: Make Changes in Azure DevOps is on, and it's open in your lists as they
    /// are now (`CopilotSending.isOpen`), not only as its details last saw it, which keep one that left them as it was. In the
    /// demo too, which changes only its made-up data.
    func canChange(_ pullRequest: PullRequest?) -> Bool {
        guard settings.makesChanges, let pullRequest, let store else { return false }
        return CopilotSending.isOpen(pullRequest.key, in: store)
    }

    /// Why a pull request's threads can't be changed, though Make Changes in Azure DevOps is on, for the tooltip and VoiceOver
    /// of where Reply would be: nil when they can, and while it's off, when none of it shows.
    func readOnlyReason(_ pullRequest: PullRequest?) -> String? {
        guard settings.makesChanges, let pullRequest, !canChange(pullRequest) else { return nil }
        let listed = store?.record(for: pullRequest.key)?.pullRequest
        return (listed ?? pullRequest).status == .active ? Self.notListed : Self.closed
    }

    static let closed = "Azure DevOps takes no change to a completed or abandoned pull request."
    static let notListed = "This pull request is no longer in your lists, so its threads can't be changed here."

    /// Why a change can't go to a pull request now, as the list has it: nil when it can. One it doesn't have anymore says
    /// so, rather than nothing.
    private func refusal(_ pullRequest: PRKey, in store: PRStore) -> ADOWriteProblem? {
        guard let record = store.record(for: pullRequest) else { return .notListed }
        return record.pullRequest.status == .active ? nil : .closed
    }

    func state(of key: Key) -> State? { states[key] }

    func isSending(_ key: Key) -> Bool {
        if case .sending? = states[key] { return true }
        return false
    }

    /// What you wrote in a thread's reply, not sent yet.
    func draft(_ key: Key) -> String { drafts[key] ?? "" }

    func keep(_ draft: String, for key: Key) {
        drafts[key] = draft.isEmpty ? nil : draft
    }

    /// Dismisses what a thread says went wrong.
    func dismiss(_ key: Key) {
        if case .failed? = states[key] { states[key] = nil }
    }

    /// What waits on you in a pull request, as its details show it, without what was in a thread you resolved here, up to
    /// when you did: its details keep what was new as it was when they showed it (`PullRequestDetailsStore.pendingEvents`),
    /// and a new comment in a resolved thread waits on you only while it's new.
    func waiting(_ events: [PREvent], of pullRequest: PRKey) -> [PREvent] {
        guard resolved.keys.contains(where: { $0.pullRequest == pullRequest }) else { return events }
        return events.filter { event in
            guard let thread = event.threadId, let at = resolved[Key(pullRequest: pullRequest, thread: thread)] else { return true }
            return event.at > at
        }
    }

    // MARK: Changing

    /// Sends your reply to a thread, as you wrote it (`posted(_:)`), then, with `status`, sets the thread's status, as Reply &
    /// Resolve does. Returns whether the reply went, and was still yours to finish: then what you wrote is forgotten;
    /// otherwise it's kept, and the thread says why. After one that may have gone, as one Azure DevOps didn't answer in
    /// time, the thread is read again first, and nothing goes until it was: if it went, it isn't sent again, whatever came
    /// after it. Called off meanwhile (`forgetAll`), it does nothing more, though it's turned back on.
    @discardableResult
    func reply(_ text: String, then status: ThreadStatus? = nil, to thread: ReviewThread, of pullRequest: PRKey) async -> Bool {
        let key = Key(pullRequest: pullRequest, thread: thread.id)
        let markdown = Self.posted(text)
        guard !markdown.isEmpty, !isSending(key), let store, settings.makesChanges else { return false }
        if let problem = refusal(pullRequest, in: store) {
            fail(key, problem, .reply(then: status), pullRequest: pullRequest)
            return false
        }
        guard let record = store.record(for: pullRequest) else { return false }
        let generation = generation, account = account
        // As the list read it last, which may have more than the view had; or, after a reply that may have gone, as Azure
        // DevOps has it now.
        var thread = record.details?.threads.first { $0.id == thread.id } ?? thread
        if let attempt = unsure[key] {
            states[key] = .sending(.reply(then: status))
            let threads = await readThreads(pullRequest)
            // Turned off meanwhile, or someone else signed in: what you wrote is gone, and nothing goes, though it's on again.
            guard generation == self.generation, settings.makesChanges else { return false }
            guard let read = threads?.first(where: { $0.id == thread.id }) else {
                states[key] = .failed(.unconfirmed, .reply(then: status))
                SpokenText.announce(ADOWriteProblem.unconfirmed.sentence(.reply))
                return false
            }
            unsure[key] = nil
            states[key] = nil
            thread = read
            // It went, and says what you'd send: it's there already.
            if Self.went(attempt, in: read, me: record.me), Self.same(attempt.markdown, markdown) {
                drafts[key] = nil
                if let status, read.threadStatus != status {
                    await setStatus(status, of: read, in: pullRequest, afterReply: true)
                } else {
                    SpokenText.announce("Your reply is in the thread already")
                }
                return true
            }
        }
        states[key] = .sending(.reply(then: status))
        let write = ADOWrite.reply(ThreadAddress(record.pullRequest, thread: thread.id), markdown: markdown, parentCommentId: thread.comments.first?.id ?? 0)
        do {
            switch store.mode {
            case .demo:
                store.changed(pullRequest, by: DemoThreadChanges.reply(markdown, to: thread, at: now()))
            case .live:
                let answer = try await dispatch(write, for: key, as: account, in: generation)
                if let change = ThreadChange(answer, to: write, pullRequest: record.pullRequest, known: thread) {
                    store.changed(pullRequest, by: change)
                } else {
                    store.mayHaveChanged(pullRequest)
                }
            }
        } catch is CancellationError {
            // Called off, as the setting was turned off or someone else signed in, with what you wrote: nothing to say.
            return false
        } catch {
            // Called off meanwhile: what's on its thread now is someone else's to say.
            guard generation == self.generation else { return false }
            let problem = ADOWriteProblem(error)
            if problem.mayHaveGone { unsure[key] = Attempt(markdown: markdown, before: Set(thread.comments.map(\.id))) }
            fail(key, problem, .reply(then: status), pullRequest: pullRequest)
            return false
        }
        // It went, but was called off as it did: the thread shows it, and nothing more happens.
        guard generation == self.generation else { return false }
        drafts[key] = nil
        if let status {
            states[key] = nil
            await setStatus(status, of: thread, in: pullRequest, afterReply: true)
        } else {
            states[key] = nil
            SpokenText.announce("Replied")
        }
        return true
    }

    /// Sets a thread's status, as its menu does: it can be set back the same way, so nothing asks first.
    func setStatus(_ status: ThreadStatus, of thread: ReviewThread, in pullRequest: PRKey, afterReply: Bool = false) async {
        let key = Key(pullRequest: pullRequest, thread: thread.id)
        guard !isSending(key), let store, settings.makesChanges else { return }
        if let problem = refusal(pullRequest, in: store) {
            fail(key, problem, .status(status), pullRequest: pullRequest)
            return
        }
        guard let record = store.record(for: pullRequest) else { return }
        let generation = generation, account = account
        states[key] = .sending(.status(status))
        let write = ADOWrite.setStatus(ThreadAddress(record.pullRequest, thread: thread.id), status)
        do {
            switch store.mode {
            case .demo:
                store.changed(pullRequest, by: DemoThreadChanges.status(status, of: thread))
            case .live:
                let answer = try await dispatch(write, for: key, as: account, in: generation)
                if let change = ThreadChange(answer, to: write, pullRequest: record.pullRequest, known: thread) {
                    store.changed(pullRequest, by: change)
                } else {
                    store.mayHaveChanged(pullRequest)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == self.generation else { return }
            fail(key, ADOWriteProblem(error), .status(status), pullRequest: pullRequest)
            return
        }
        guard generation == self.generation else { return }
        states[key] = nil
        if status.isResolved {
            // Up to its latest comment, as Azure DevOps dates them: what comes after needs you again.
            let latest = store.record(for: pullRequest)?.details?.threads.first { $0.id == thread.id }?.comments.map(\.publishedAt).max()
            resolved[key] = latest ?? now()
            // Seen, as you are looking at it, so Needs You follows: a new comment in a resolved thread needs you only while
            // it's new.
            if let item = store.items.first(where: { $0.key == pullRequest }) { store.markSeen(item) }
        } else {
            resolved[key] = nil
        }
        SpokenText.announce(afterReply ? "Replied, and set to \(status.title)" : "Set to \(status.title)")
    }

    /// Sends a change, while you can make changes and nothing called it off since it was asked for (`generation`), as whom
    /// it was asked for as, in a task that's called off as replies go (`forgetAll`): before it goes, as while it waits for a
    /// token, it never does.
    private func dispatch(_ write: ADOWrite, for key: Key, as account: String?, in generation: Int) async throws -> ADOWrite.Answer {
        guard generation == self.generation else { throw CancellationError() }
        guard settings.makesChanges else {
            states[key] = nil
            throw CancellationError()
        }
        let send = send
        let task = Task { try await send(write, account) }
        inFlight[key] = task
        defer { if inFlight[key] == task { inFlight[key] = nil } }
        do {
            return try await task.value
        } catch where task.isCancelled {
            throw CancellationError()
        }
    }

    /// Whether a reply that may have gone did: a comment of yours in the thread, which came since it was sent, says it, as
    /// Azure DevOps keeps it, mentions as their IDs, or as the details show it, mentions as names.
    static func went(_ attempt: Attempt, in thread: ReviewThread, me: String) -> Bool {
        thread.comments.contains { comment in
            guard !attempt.before.contains(comment.id), comment.author.id == me.lowercased() else { return false }
            return comment.content.map { same($0, attempt.markdown) } == true || same(comment.markdown, attempt.markdown)
        }
    }

    /// A change that didn't happen, or may not have: the thread says why, and when it may have happened all the same, its
    /// pull request is read again, to show it.
    private func fail(_ key: Key, _ problem: ADOWriteProblem, _ sending: Sending, pullRequest: PRKey) {
        states[key] = .failed(problem, sending)
        if problem.mayHaveGone { store?.mayHaveChanged(pullRequest) }
        SpokenText.announce(problem.sentence(sending.kind))
    }

    /// What goes of what you wrote: without the lines that say nothing before it, or the spaces after it, but with its first
    /// line's indent, which can make it code.
    static func posted(_ text: String) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        while let first = lines.first, first.allSatisfy(\.isWhitespace) { lines.removeFirst() }
        var posted = lines.joined(separator: "\n")
        while let last = posted.last, last.isWhitespace { posted.removeLast() }
        return posted
    }

    /// Whether two replies say the same, as they'd go (`posted(_:)`): but for the lines that say nothing before them, the
    /// spaces after them and how their lines end, and with their first line's indent, which can make it code.
    static func same(_ lhs: String, _ rhs: String) -> Bool {
        posted(lhs) == posted(rhs)
    }

    /// Forgets what you wrote, and what was going on, as Azure DevOps stops or someone else signs in.
    func forgetAll() {
        generation += 1
        for task in inFlight.values { task.cancel() }
        inFlight = [:]
        drafts = [:]
        states = [:]
        resolved = [:]
        unsure = [:]
    }

    /// Who's signed in to the Azure CLI, as the list last told.
    private var account: String?

    /// Someone signed in to the Azure CLI, as the list tells: when it's someone else than before, what you wrote was as the
    /// last one, and goes.
    func accountChanged(_ account: String?) {
        guard let account else { return }
        defer { self.account = account }
        guard let known = self.account, known != account else { return }
        forgetAll()
    }
}
