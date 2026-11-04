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

    let settings: AppSettings
    /// Fix Grammar's models, for what you write in a reply.
    let grammar: GrammarFixer
    private weak var store: PRStore?
    /// Sends a change to Azure DevOps: the client's; a test's stand-in. Never in the demo.
    var send: (ADOWrite) async throws -> ADOWrite.Answer
    /// For the demo's made-up comments, and when you resolved a thread.
    var now: () -> Date = Date.init

    init(store: PRStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        grammar = GrammarFixer(isDemo: store.mode == .demo)
        let client = store.client
        send = { try await client.send($0) }
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

    /// Whether you can change a pull request's threads: Make Changes in Azure DevOps is on, and it's open. In the demo too,
    /// which changes only its made-up data.
    func canChange(_ pullRequest: PullRequest?) -> Bool {
        guard settings.makesChanges, let pullRequest else { return false }
        return pullRequest.status == .active
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

    /// The thread whose Reply the keyboard's focus goes back to as its buttons show again, once your reply on it is sent or
    /// closed (`ThreadReplyButtons`).
    private var focusing: Key?

    func focusAfter(_ key: Key) {
        focusing = key
    }

    /// Whether the keyboard's focus goes back to a thread's Reply now: once.
    func takeFocus(_ key: Key) -> Bool {
        guard focusing == key else { return false }
        focusing = nil
        return true
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

    /// Sends your reply to a thread, then, with `status`, sets the thread's status, as Reply & Resolve does. Returns whether
    /// the reply went: then what you wrote is forgotten; otherwise it's kept, and the thread says why. The same reply as your
    /// last word there, as after one that went though Azure DevOps didn't answer in time, isn't sent again.
    @discardableResult
    func reply(_ text: String, then status: ThreadStatus? = nil, to thread: ReviewThread, of pullRequest: PRKey) async -> Bool {
        let key = Key(pullRequest: pullRequest, thread: thread.id)
        let markdown = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markdown.isEmpty, !isSending(key), let store else { return false }
        let record = store.record(for: pullRequest)
        guard let record, canChange(record.pullRequest) else { return false }
        // As the list read it last, which may have more than the view had.
        let thread = record.details?.threads.first { $0.id == thread.id } ?? thread
        if let last = thread.comments.last, last.author.id == record.me.lowercased(), Self.same(last.markdown, markdown) {
            drafts[key] = nil
            states[key] = nil
            if let status, thread.threadStatus != status { await setStatus(status, of: thread, in: pullRequest) }
            return true
        }
        states[key] = .sending(.reply(then: status))
        let write = ADOWrite.reply(ThreadAddress(record.pullRequest, thread: thread.id), markdown: markdown, parentCommentId: thread.comments.first?.id ?? 0)
        do {
            switch store.mode {
            case .demo:
                store.changed(pullRequest, by: DemoThreadChanges.reply(markdown, to: thread, at: now()))
            case .live:
                let answer = try await send(write)
                if let change = ThreadChange(answer, to: write, pullRequest: record.pullRequest, known: thread) {
                    store.changed(pullRequest, by: change)
                } else {
                    store.readAgain(pullRequest)
                }
            }
        } catch {
            fail(key, ADOWriteProblem(error), .reply(then: status), pullRequest: pullRequest)
            return false
        }
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
        guard !isSending(key), let store, let record = store.record(for: pullRequest), canChange(record.pullRequest) else { return }
        states[key] = .sending(.status(status))
        let write = ADOWrite.setStatus(ThreadAddress(record.pullRequest, thread: thread.id), status)
        do {
            switch store.mode {
            case .demo:
                store.changed(pullRequest, by: DemoThreadChanges.status(status, of: thread))
            case .live:
                let answer = try await send(write)
                if let change = ThreadChange(answer, to: write, pullRequest: record.pullRequest, known: thread) {
                    store.changed(pullRequest, by: change)
                } else {
                    store.readAgain(pullRequest)
                }
            }
        } catch {
            fail(key, ADOWriteProblem(error), .status(status), pullRequest: pullRequest)
            return
        }
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

    /// A change that didn't happen, or may not have: the thread says why, and when it may have happened all the same, its
    /// pull request is read again, to show it.
    private func fail(_ key: Key, _ problem: ADOWriteProblem, _ sending: Sending, pullRequest: PRKey) {
        states[key] = .failed(problem, sending)
        if problem.mayHaveGone { store?.readAgain(pullRequest) }
        SpokenText.announce(problem.sentence(sending.kind))
    }

    /// Whether two replies say the same, but for the spaces around them.
    static func same(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines) == rhs.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Forgets what you wrote, and what was going on, as Azure DevOps stops or someone else signs in.
    func forgetAll() {
        drafts = [:]
        states = [:]
        resolved = [:]
        focusing = nil
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
