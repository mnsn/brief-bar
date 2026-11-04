import AzureDevOpsCore
import BriefBarCore
import Combine
import Foundation

/// A pull request's tags as you change them in its details, with **Make Changes in Azure DevOps** on: a tag you add, and one
/// you take off (`ADOWrite.addTag`, `removeTag`), each when you click it, while the pull request is open. What Azure DevOps
/// answers shows at once, and the tags are read again (`PRStore.changedTags`); a change that didn't happen says why, by the
/// tags. It reads, with one request, the tags of a pull request whose list doesn't carry them, such as one sent to you, once
/// its details show on a window's page on screen (`follow`); and remembers the tags you add, for each project, to suggest
/// them (`AppSettings.usedTags`), until you turn the setting off. The demo changes only its made-up data, and reads nothing.
@MainActor
final class TagChanges: ObservableObject {
    /// A change to a pull request's tags.
    enum Change: Equatable {
        case add(String)
        case remove(PullRequestTag)

        var kind: ADOWrite.Kind {
            switch self {
            case .add: .addTag
            case .remove: .removeTag
            }
        }
    }

    /// What a change to a pull request's tags is doing, or why it didn't happen.
    enum State: Equatable {
        case sending(Change)
        /// It didn't happen, or may not have: what went wrong, and what it was.
        case failed(ADOWriteProblem, Change)
    }

    @Published private(set) var states: [PRKey: State] = [:]
    /// The tag you took off each pull request last, which Undo adds back: until its tags change again, you dismiss it, or
    /// its details stop showing it.
    @Published private(set) var removed: [PRKey: PullRequestTag] = [:]
    /// The changes on their way, by pull request, which turning the setting off, Azure DevOps stopping or someone else
    /// signing in calls off (`forgetAll`): one that hasn't gone never does.
    private var inFlight: [PRKey: Task<ADOWrite.Answer, Error>] = [:]
    /// How many times what was going on was called off (`forgetAll`): a change asked for before then does nothing more as
    /// it comes back from what it waited for, though the setting is on again.
    private var generation = 0

    let settings: AppSettings
    private weak var store: PRStore?
    /// Sends a change to Azure DevOps, as whom it was asked for as, when that's known: the client's; a test's stand-in.
    /// Never in the demo.
    var send: (ADOWrite, String?) async throws -> ADOWrite.Answer
    /// A pull request's tags read on their own, as Azure DevOps has them now, which show from then on: the list's; a test's
    /// stand-in. Nil in the demo, which reads nothing.
    var readTags: @MainActor (PRKey) async -> Result<[PullRequestTag], ADOError>?
    var now: () -> Date = Date.init
    private var cancellables: Set<AnyCancellable> = []

    init(store: PRStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        let client = store.client
        send = { try await client.send($0, as: $1) }
        readTags = { [weak store] key in await store?.readTags(key) }
        // Turned off, the tags show neither Add Tag nor ✕, a change on its way is called off, what went wrong goes, and so do the
        // tags you added, which nothing suggests anymore.
        settings.$makesChanges.removeDuplicates().dropFirst()
            .sink { [weak self] on in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.objectWillChange.send()
                    if !on {
                        self.forgetAll()
                        self.settings.usedTags = UsedTags()
                    }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: What you can do

    /// Whether you can change a pull request's tags, as its threads (`ThreadChanges.canChange`): Make Changes in Azure DevOps
    /// is on, and it's open in your lists as they are now (`CopilotSending.isOpen`), not only as its details last saw it;
    /// and its tags are known. In the demo too, which changes only its made-up data.
    func canChange(_ record: PRRecord?) -> Bool {
        guard settings.makesChanges, let record, record.tags != nil, let store else { return false }
        return CopilotSending.isOpen(record.id, in: store)
    }

    func state(of key: PRKey) -> State? { states[key] }

    func isSending(_ key: PRKey) -> Bool {
        if case .sending? = states[key] { return true }
        return false
    }

    /// Dismisses what the tags say went wrong.
    func dismiss(_ key: PRKey) {
        if case .failed? = states[key] { states[key] = nil }
    }

    /// Dismisses the tag you took off, which Undo would add back.
    func dismissRemoval(on key: PRKey) {
        removed[key] = nil
    }

    /// Adds back the tag you took off last, as Undo does.
    func undoRemoval(on key: PRKey) async {
        guard let tag = removed[key] else { return }
        await add(tag.name, to: key)
    }

    /// What adding a tag to a pull request offers as you type (`TagChoices`): the tags you added in its project, then those of
    /// the pull requests BriefBar read there, but its own.
    func choices(for typed: String, on record: PRRecord) -> TagChoices {
        let pullRequest = record.pullRequest
        let used = settings.usedTags.tags(organization: pullRequest.key.organization, projectId: pullRequest.projectId)
        return TagChoices(typed: typed, used: used, seen: store?.tags(inProjectOf: pullRequest) ?? [], current: record.tags ?? [])
    }

    // MARK: Changing

    /// Adds a tag to a pull request, as you typed or chose it, but for one it has already, ignoring letter case. Returns
    /// whether it has it now: then what you typed is done with; otherwise the tags say why.
    @discardableResult
    func add(_ typed: String, to key: PRKey) async -> Bool {
        guard let name = PullRequestTag.name(typed), !isSending(key), let store, let record = store.record(for: key),
              canChange(record), let current = record.tags
        else { return false }
        removed[key] = nil
        if let had = current.first(where: { $0.key == name.lowercased() }) {
            states[key] = nil
            SpokenText.announce("It has the tag \(had.name) already")
            return true
        }
        let change = Change.add(name)
        let generation = generation, account = account
        states[key] = .sending(change)
        var added = name
        do {
            switch store.mode {
            case .demo:
                store.changedTags(key, to: PullRequestTag.adding(DemoTags.tag(name), to: current))
            case .live:
                let write = ADOWrite.addTag(PullRequestAddress(record.pullRequest), name: name)
                let answer = try await dispatch(write, for: key, as: account, in: generation)
                // Called off as it went: the tags show what was made, when they're read, and nothing more happens.
                guard generation == self.generation else { return false }
                if case .tag(let answered) = answer, let tag = PullRequestTag.tags([answered]).first {
                    // As Azure DevOps spells it, with the tags as they are now, which a refresh may have read meanwhile.
                    added = tag.name
                    store.changedTags(key, to: PullRequestTag.adding(tag, to: store.record(for: key)?.tags ?? current))
                } else {
                    await readAgain(key)
                }
            }
        } catch is CancellationError {
            // Called off, as the setting was turned off or someone else signed in: nothing to say.
            return false
        } catch {
            guard generation == self.generation else { return false }
            fail(key, ADOWriteProblem(error), change)
            return false
        }
        guard generation == self.generation else { return false }
        states[key] = nil
        // Suggested first from now on, in its project, while the setting's on.
        if settings.makesChanges {
            settings.usedTags.add(added, organization: key.organization, projectId: record.pullRequest.projectId)
        }
        SpokenText.announce("Added the tag \(added)")
        return true
    }

    /// Takes a tag off a pull request, by the project's tag's ID, as its ✕ does: it can be added back the same way, so
    /// nothing asks first.
    func remove(_ tag: PullRequestTag, from key: PRKey) async {
        guard !isSending(key), let store, let record = store.record(for: key), canChange(record), let current = record.tags,
              current.contains(where: { $0.key == tag.key })
        else { return }
        let change = Change.remove(tag)
        let generation = generation, account = account
        removed[key] = nil
        states[key] = .sending(change)
        do {
            switch store.mode {
            case .demo:
                store.changedTags(key, to: PullRequestTag.removing(tag, from: current))
            case .live:
                let write = ADOWrite.removeTag(PullRequestAddress(record.pullRequest), tag: tag.tagId ?? tag.name)
                _ = try await dispatch(write, for: key, as: account, in: generation)
                guard generation == self.generation else { return }
                store.changedTags(key, to: PullRequestTag.removing(tag, from: store.record(for: key)?.tags ?? current))
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == self.generation else { return }
            let problem = ADOWriteProblem(error)
            // Not on the pull request, as far as Azure DevOps knows: its tags, read again, tell whether that's so, and then
            // it's as you wanted.
            if problem == .gone, case .success(let read)? = await readTags(key), !read.contains(where: { $0.key == tag.key }) {
                guard generation == self.generation else { return }
                states[key] = nil
                removed[key] = tag
                SpokenText.announce("Removed the tag \(tag.name)")
                return
            }
            guard generation == self.generation else { return }
            fail(key, problem, change)
            return
        }
        guard generation == self.generation else { return }
        states[key] = nil
        removed[key] = tag
        SpokenText.announce("Removed the tag \(tag.name). Undo adds it back.")
    }

    /// Sends a change, while you can make changes and nothing called it off since it was asked for (`generation`), as whom
    /// it was asked for as, in a task that's called off as they go (`forgetAll`): before it goes, as while it waits for a
    /// token, it never does.
    private func dispatch(_ write: ADOWrite, for key: PRKey, as account: String?, in generation: Int) async throws -> ADOWrite.Answer {
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

    /// Tries a change that didn't happen again.
    func retry(_ change: Change, on key: PRKey) async {
        dismiss(key)
        switch change {
        case .add(let name): await add(name, to: key)
        case .remove(let tag): await remove(tag, from: key)
        }
    }

    /// A change that didn't happen, or may not have: the tags say why, and, when it may have happened all the same, they're
    /// read again, to show how they stand.
    private func fail(_ key: PRKey, _ problem: ADOWriteProblem, _ change: Change) {
        states[key] = .failed(problem, change)
        if problem.mayHaveGone { Task { [weak self] in await self?.readAgain(key) } }
        SpokenText.announce(problem.sentence(change.kind))
    }

    /// Reads a pull request's tags again, which show as they're read.
    private func readAgain(_ key: PRKey) async {
        _ = await readTags(key)
    }

    // MARK: Tags lists don't carry

    /// How long the tags read here for a pull request whose list doesn't carry them stay as they are: they're read again as
    /// its details show after that.
    static let readAgainAfter: TimeInterval = 600
    /// How long after a read here failed it's tried again.
    static let retryAfter: TimeInterval = 30

    /// The pages windows show on screen (`PullRequestCodeStore.page`).
    private var visiblePages: Set<String> = []
    /// The pull requests whose details show, by what shows them, with the window's page they're on.
    private var followers: [UUID: (key: PRKey, page: String?)] = [:]
    private var reading: Set<PRKey> = []
    /// When the tags of a pull request were read here, or couldn't be, last.
    private var readAt: [PRKey: Date] = [:]
    private var failedAt: [PRKey: Date] = [:]

    /// Follows a pull request's tags while its details show it on a window's page, until the task that follows it is
    /// cancelled, as when they close or show another: tags its lists don't carry are read, one request, while a window shows
    /// that page on screen, as it does, or once it does. Nothing for one whose lists carry them, which keep them current.
    /// - Parameter page: the window's page they're on (`PullRequestCodeStore.page`); nil outside one, where nothing's read.
    func follow(_ key: PRKey, on page: String?) async {
        let follower = UUID()
        followers[follower] = (key, page)
        defer {
            followers[follower] = nil
            // Nothing shows it anymore: Undo goes with its details.
            if !followers.values.contains(where: { $0.key == key }) { removed[key] = nil }
        }
        readIfNeeded(key, on: page)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3_600))
        }
    }

    /// A window started or stopped showing, on screen, a page where a pull request's details can show: as it shows them,
    /// the tags of those that need reading are read.
    func setVisible(_ visible: Bool, for page: String) {
        if visible {
            guard visiblePages.insert(page).inserted else { return }
            for follower in followers.values where follower.page == page {
                readIfNeeded(follower.key, on: page)
            }
        } else {
            visiblePages.remove(page)
        }
    }

    /// Reads a pull request's tags, unless they're known: from its lists, or read here less than ten minutes ago. Not on a
    /// page that isn't on screen, while they're being read, within half a minute of a read that failed, or in the demo.
    private func readIfNeeded(_ key: PRKey, on page: String?) {
        guard let page, visiblePages.contains(page), !reading.contains(key), let store, store.mode == .live,
              let record = store.record(for: key)
        else { return }
        let now = now()
        if let failed = failedAt[key], now.timeIntervalSince(failed) < Self.retryAfter { return }
        if record.tags != nil {
            guard let read = readAt[key], now.timeIntervalSince(read) >= Self.readAgainAfter else { return }
        }
        reading.insert(key)
        Task { [weak self] in
            guard let self else { return }
            let result = await readTags(key)
            reading.remove(key)
            switch result {
            case .success?:
                readAt[key] = self.now()
                failedAt[key] = nil
            case .failure?:
                failedAt[key] = self.now()
            case nil:
                break
            }
        }
    }

    // MARK: Forgetting

    /// Forgets what was going on, and calls off a change on its way, as the setting goes off, Azure DevOps stops or someone
    /// else signs in.
    func forgetAll() {
        generation += 1
        for task in inFlight.values { task.cancel() }
        inFlight = [:]
        states = [:]
        removed = [:]
        readAt = [:]
        failedAt = [:]
    }

    /// Stops for good, when Azure DevOps stops.
    func stop() {
        forgetAll()
        visiblePages = []
        followers = [:]
    }

    /// Who's signed in to the Azure CLI, as the list last told.
    private var account: String?

    /// Someone signed in to the Azure CLI, as the list tells: when it's someone else than before, what was going on was the
    /// last one's, and goes.
    func accountChanged(_ account: String?) {
        guard let account else { return }
        defer { self.account = account }
        guard let known = self.account, known != account else { return }
        forgetAll()
    }
}
