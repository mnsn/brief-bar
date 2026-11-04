import AzureDevOpsCore
import BriefBarCore
import Combine
import CryptoKit
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
    /// The threads whose replies may have gone though they failed, as one Azure DevOps didn't answer in time, each with a
    /// fingerprint of what it said (`Attempt`), however many said something else: until their threads, read again for the
    /// same reply, tell, it isn't sent there.
    private var unsure: [Key: [Attempt]] = [:]
    /// The changes on their way to Azure DevOps, by thread: called off as replies go, when the setting is turned off, Azure
    /// DevOps stops or someone else signs in, so that one that hasn't gone yet, as one waiting for a token, never does.
    private var inFlight: [Key: Task<ADOWrite.Answer, Error>] = [:]
    /// The changes on their way as the setting went off, which may have gone already, by thread, with when they were asked
    /// for (`generation`): they settle all the same (`ADOClient.send(_:as:)`), and until they have, their thread, on again,
    /// shows them on their way and takes no other change, so that none goes twice while it's unknown whether it went.
    private var settling: [Key: Int] = [:]
    /// How many times what was going on was called off (`forgetAll`): a change asked for before then does nothing more, as
    /// it comes back from what it waited for, though the setting is on again and another change on its thread is under way.
    private var generation = 0
    /// How many times what was going on ended, as someone else signed in or Azure DevOps stopped (`forgetAll`): a change sent
    /// before then does nothing more as it settles, whatever Azure DevOps answers, since it was the last one's; one called
    /// off only as the setting went off settles all the same.
    private var lifetime = 0

    /// A reply that may have gone: a fingerprint of what it said, as it went (`digest`), rather than what it said, so that it
    /// can outlast what you wrote, as the setting goes off; and the comments its thread had before it was sent, by their IDs.
    /// A comment of yours that came since, which says the same, is it, whatever came after it.
    struct Attempt: Equatable {
        var digest: SHA256.Digest
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
    /// Reads a pull request again, after a change that may have been made though Azure DevOps didn't say how: the list's
    /// (`PRStore.mayHaveChanged`); a test's stand-in.
    var readAgain: @MainActor (PRKey) -> Void
    /// For the demo's made-up comments, and when you resolved a thread.
    var now: () -> Date = Date.init

    init(store: PRStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        grammar = GrammarFixer(isDemo: store.mode == .demo)
        let client = store.client
        send = { try await client.send($0, as: $1) }
        readThreads = { [weak store] key in await store?.threadsReadAgain(key) }
        readAgain = { [weak store] key in store?.mayHaveChanged(key) }
        // The demo shows them: they change only its made-up data.
        if store.mode == .demo { settings.makesChanges = true }
        // Turned off, threads show none of it, what you wrote goes, and a change that hasn't gone yet is called off. One that
        // may have goes on, since Azure DevOps may make it all the same: its thread takes no other change until it settles,
        // and then says what happened; and a reply that may have gone is still checked before the same goes again
        // (`forgetAll(turnedOff:)`).
        settings.$makesChanges.removeDuplicates().dropFirst()
            .sink { [weak self] on in
                MainActor.assumeIsolated {
                    self?.objectWillChange.send()
                    if !on { self?.forgetAll(turnedOff: true) }
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

    /// Sends your reply to a thread, as you wrote it (`posted(_:)`), then, with `status`, sets the thread's status, as Reply &
    /// Resolve does. Returns whether the reply went, and was still yours to finish: then what you wrote is forgotten;
    /// otherwise it's kept, and the thread says why. After one that may have gone, as one Azure DevOps didn't answer in
    /// time, the same reply goes only once the thread, read again first, says it didn't, whatever came after it. Called off
    /// meanwhile (`forgetAll`), it does nothing more, though it's turned back on: but one that had gone as the setting went
    /// off keeps its thread until it settles, then shows what Azure DevOps answered, or, when it may have been made without
    /// saying so, its pull request is read again, and it's checked before the same goes again; one that had gone as someone
    /// else signed in, or Azure DevOps stopped, was the last one's, and does nothing at all.
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
        let generation = generation, lifetime = lifetime, account = account
        // As the list read it last, which may have more than the view had; or, after a reply that may have gone, as Azure
        // DevOps has it now.
        var thread = record.details?.threads.first { $0.id == thread.id } ?? thread
        let digest = Self.digest(markdown)
        if let attempt = unsure[key]?.first(where: { $0.digest == digest }) {
            states[key] = .sending(.reply(then: status))
            let threads = await readThreads(pullRequest)
            // Turned off meanwhile, or someone else signed in: what you wrote is gone, and nothing goes, though it's on again.
            guard generation == self.generation, settings.makesChanges else { return false }
            guard let read = threads?.first(where: { $0.id == thread.id }) else {
                states[key] = .failed(.unconfirmed, .reply(then: status))
                SpokenText.announce(ADOWriteProblem.unconfirmed.sentence(.reply))
                return false
            }
            forget(attempt, on: key)
            states[key] = nil
            thread = read
            // It went: it's there already.
            if Self.went(attempt, in: read, me: record.me) {
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
                // Someone else signed in, or Azure DevOps stopped, as it went: it was the last one's, and does nothing more.
                guard lifetime == self.lifetime else { return false }
                if let change = ThreadChange(answer, to: write, pullRequest: record.pullRequest, known: thread) {
                    store.changed(pullRequest, by: change)
                } else {
                    readAgain(pullRequest)
                }
            }
        } catch is CancellationError {
            // Called off before it went, as the setting was turned off or someone else signed in while it waited for a token:
            // it didn't go, so there's nothing to say or to check.
            settled(key, sentIn: generation)
            return false
        } catch {
            guard lifetime == self.lifetime else { return false }
            let problem = ADOWriteProblem(error, now: now())
            // One that may have gone is checked before the same goes again.
            if problem.mayHaveGone {
                remember(Attempt(digest: digest, before: Set(thread.comments.map(\.id))), on: key)
            }
            // Called off as it went, as the setting was turned off: the thread says nothing, but once it's settled, its pull
            // request is read again, to show it if it was made.
            guard generation == self.generation else {
                if problem.mayHaveGone { readAgain(pullRequest) }
                settled(key, sentIn: generation)
                return false
            }
            fail(key, problem, .reply(then: status), pullRequest: pullRequest)
            return false
        }
        // It went, but was called off as it did: the thread shows it, and nothing more happens.
        guard generation == self.generation else {
            settled(key, sentIn: generation)
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
        guard !isSending(key), let store, settings.makesChanges else { return }
        if let problem = refusal(pullRequest, in: store) {
            fail(key, problem, .status(status), pullRequest: pullRequest)
            return
        }
        guard let record = store.record(for: pullRequest) else { return }
        let generation = generation, lifetime = lifetime, account = account
        states[key] = .sending(.status(status))
        let write = ADOWrite.setStatus(ThreadAddress(record.pullRequest, thread: thread.id), status)
        do {
            switch store.mode {
            case .demo:
                store.changed(pullRequest, by: DemoThreadChanges.status(status, of: thread))
            case .live:
                let answer = try await dispatch(write, for: key, as: account, in: generation)
                guard lifetime == self.lifetime else { return }
                if let change = ThreadChange(answer, to: write, pullRequest: record.pullRequest, known: thread) {
                    store.changed(pullRequest, by: change)
                } else {
                    readAgain(pullRequest)
                }
            }
        } catch is CancellationError {
            settled(key, sentIn: generation)
            return
        } catch {
            guard lifetime == self.lifetime else { return }
            let problem = ADOWriteProblem(error, now: now())
            guard generation == self.generation else {
                if problem.mayHaveGone { readAgain(pullRequest) }
                settled(key, sentIn: generation)
                return
            }
            fail(key, problem, .status(status), pullRequest: pullRequest)
            return
        }
        guard generation == self.generation else {
            settled(key, sentIn: generation)
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

    /// Sends a change, while you can make changes and nothing called it off since it was asked for (`generation`), as whom
    /// it was asked for as, in a task that's called off as replies go (`forgetAll`): before it goes, as while it waits for a
    /// token, it never does, and throws `CancellationError`; once it's gone, it settles all the same, with Azure DevOps'
    /// answer or why it failed (`ADOClient.send(_:as:)`).
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
        return try await task.value
    }

    /// Whether a reply that may have gone did: a comment of yours in the thread, which came since it was sent, says it, as
    /// Azure DevOps keeps it, mentions as their IDs, or as the details show it, mentions as names.
    static func went(_ attempt: Attempt, in thread: ReviewThread, me: String) -> Bool {
        thread.comments.contains { comment in
            guard !attempt.before.contains(comment.id), comment.author.id == me.lowercased() else { return false }
            return comment.content.map { digest($0) == attempt.digest } == true || digest(comment.markdown) == attempt.digest
        }
    }

    /// Keeps a reply that may have gone, until its thread, read again for the same reply, tells: beside the others on the
    /// thread that may have, each saying something else, and in place of one that said the same.
    private func remember(_ attempt: Attempt, on key: Key) {
        unsure[key, default: []].removeAll { $0.digest == attempt.digest }
        unsure[key, default: []].append(attempt)
    }

    /// A reply that may have gone is known now, as its thread, read again, tells.
    private func forget(_ attempt: Attempt, on key: Key) {
        unsure[key]?.removeAll { $0.digest == attempt.digest }
        if unsure[key]?.isEmpty == true { unsure[key] = nil }
    }

    /// A fingerprint of a reply as it would go (`posted(_:)`): two say the same when theirs are, but for the lines that say
    /// nothing before them, the spaces after them and how their lines end, and with their first line's indent.
    static func digest(_ text: String) -> SHA256.Digest {
        SHA256.hash(data: Data(posted(text).utf8))
    }

    /// A change that didn't happen, or may not have: the thread says why, and when it may have happened all the same, its
    /// pull request is read again, to show it.
    private func fail(_ key: Key, _ problem: ADOWriteProblem, _ sending: Sending, pullRequest: PRKey) {
        states[key] = .failed(problem, sending)
        if problem.mayHaveGone { readAgain(pullRequest) }
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

    /// Forgets what you wrote, and what was going on, and calls off the changes on their way that haven't gone yet, as the
    /// setting goes off, Azure DevOps stops or someone else signs in. As the setting goes off (`turnedOff`), the changes on
    /// their way, which may have gone already, keep their threads until they settle (`settling`), and a reply that may have
    /// gone is still checked before the same goes again, by its fingerprint, not what it said; otherwise what was going on
    /// was the last one's, or ends, and does nothing more as it settles (`lifetime`).
    func forgetAll(turnedOff: Bool = false) {
        if turnedOff {
            for key in inFlight.keys { settling[key] = generation }
        } else {
            settling = [:]
            lifetime += 1
        }
        generation += 1
        for task in inFlight.values { task.cancel() }
        inFlight = [:]
        drafts = [:]
        // What's left of a change still settling: a reply's status after it doesn't go.
        states = states.filter { settling[$0.key] != nil }.mapValues { state in
            if case .sending(.reply) = state { return .sending(.reply(then: nil)) }
            return state
        }
        resolved = [:]
        if !turnedOff { unsure = [:] }
        focusing = nil
    }

    /// A change on its way as the setting went off has settled, and said what it could: its thread takes changes again.
    private func settled(_ key: Key, sentIn generation: Int) {
        guard settling[key] == generation else { return }
        settling[key] = nil
        states[key] = nil
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
