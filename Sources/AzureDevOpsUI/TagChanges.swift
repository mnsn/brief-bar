import AzureDevOpsCore
import BriefBarCore
import Combine
import Foundation

/// A pull request's tags as you change them in its details, with **Make Changes in Azure DevOps** on: a tag you add, and one
/// you take off (`ADOWrite.addTag`, `removeTag`), each when you click it, while the pull request is open. What Azure DevOps
/// answers shows at once, and the tags are read again (`PRStore.changedTags`); a change that didn't happen says why, by the
/// tags. It reads, with one request, the tags of a pull request whose lists don't carry them, such as one sent to you, once
/// its details show on a window's page on screen, and again ten minutes later (`follow`); and remembers the tags you add, for
/// each project, to suggest them (`AppSettings.usedTags`), until you turn the setting off. The demo changes only its made-up
/// data, and reads nothing.
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
    /// After a change Azure DevOps answered: the tags it left kept, then read again (`PRStore.readTags(afterChanging:to:)`):
    /// the list's; a test's stand-in. Nil in the demo.
    var readAfterChange: @MainActor (PRKey, [PullRequestTag]) async -> Result<[PullRequestTag], ADOError>?
    var now: () -> Date = Date.init
    private var cancellables: Set<AnyCancellable> = []

    init(store: PRStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        let client = store.client
        send = { try await client.send($0, as: $1) }
        readTags = { [weak store] key in await store?.readTags(key) }
        readAfterChange = { [weak store] key, tags in await store?.readTags(afterChanging: key, to: tags) }
        // Turned off, the tags show neither Add Tag nor ✕, a change on its way is called off, what went wrong goes, and so do the
        // tags you added, which nothing suggests anymore. A change called off may have gone all the same: its tags are read
        // again, as for one that failed so.
        settings.$makesChanges.removeDuplicates().dropFirst()
            .sink { [weak self] on in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.objectWillChange.send()
                    if !on {
                        let calledOff = Array(self.inFlight.keys)
                        self.forgetAll()
                        self.settings.usedTags = UsedTags()
                        for key in calledOff {
                            Task { [weak self] in await self?.readAgain(key) }
                        }
                    }
                }
            }
            .store(in: &cancellables)
        // Undo goes once the tags have the tag again, as when someone else added it back, for good: not back for a later
        // removal of it, which isn't yours.
        store.refreshed
            .sink { [weak self] in MainActor.assumeIsolated { self?.forgetRestored() } }
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

    /// Why a change can't go to a pull request's tags now, as the list has it: nil when it can. One it doesn't have anymore,
    /// or that's completed or abandoned, says so by the tags, rather than nothing, as a thread does (`ThreadChanges`).
    private func refusal(_ key: PRKey, in store: PRStore) -> ADOWriteProblem? {
        guard let record = store.record(for: key) else { return .notListed }
        return record.pullRequest.status == .active ? nil : .closed
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

    /// The tag you took off a pull request last, which Undo adds back, while its tags don't have it again, as when someone
    /// else added it back, which the tags read since show.
    func undoable(on key: PRKey, tags: [PullRequestTag]?) -> PullRequestTag? {
        guard let tag = removed[key], tags?.contains(where: { $0.key == tag.key }) != true else { return nil }
        return tag
    }

    /// Forgets the tags you took off that pull requests have again, as the list has them now (`undoable`).
    private func forgetRestored() {
        guard let store, !removed.isEmpty else { return }
        for (key, tag) in removed where store.record(for: key)?.tags?.contains(where: { $0.key == tag.key }) == true {
            removed[key] = nil
        }
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
        guard let name = PullRequestTag.name(typed), !isStopped, !isSending(key), let store, settings.makesChanges else {
            return false
        }
        if let problem = refusal(key, in: store) {
            fail(key, problem, .add(name))
            return false
        }
        guard let record = store.record(for: key), canChange(record), let current = record.tags else { return false }
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
                    let tags = PullRequestTag.adding(tag, to: store.record(for: key)?.tags ?? current)
                    store.changedTags(key, to: tags)
                    readAgain(afterChanging: key, to: tags)
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
        guard !isStopped, !isSending(key), let store, settings.makesChanges else { return }
        if let problem = refusal(key, in: store) {
            fail(key, problem, .remove(tag))
            return
        }
        guard let record = store.record(for: key), canChange(record), let current = record.tags,
              current.contains(where: { $0.key == tag.key })
        else { return }
        let change = Change.remove(tag)
        let generation = generation, account = account
        // Undo is for the details that show it as you click: not once they've closed, though they show it again.
        let closing = closings[key, default: 0]
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
                let tags = PullRequestTag.removing(tag, from: store.record(for: key)?.tags ?? current)
                store.changedTags(key, to: tags)
                readAgain(afterChanging: key, to: tags)
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == self.generation else { return }
            let problem = ADOWriteProblem(error)
            // Not on the pull request, as far as Azure DevOps knows: its tags, read again, tell whether that's so, and then
            // it's as you wanted.
            if problem == .gone, case .success(let read)? = await readCounting(key), !read.contains(where: { $0.key == tag.key }) {
                guard generation == self.generation else { return }
                states[key] = nil
                if closings[key, default: 0] == closing { removed[key] = tag }
                SpokenText.announce("Removed the tag \(tag.name)")
                return
            }
            guard generation == self.generation else { return }
            fail(key, problem, change)
            return
        }
        guard generation == self.generation else { return }
        states[key] = nil
        guard closings[key, default: 0] == closing else {
            SpokenText.announce("Removed the tag \(tag.name)")
            return
        }
        removed[key] = tag
        SpokenText.announce("Removed the tag \(tag.name). Undo adds it back.")
    }

    /// Sends a change, while you can make changes and nothing called it off since it was asked for (`generation`), as whom
    /// it was asked for as, in a task that's called off as they go (`forgetAll`): before it goes, as while it waits for a
    /// token, it never does.
    private func dispatch(_ write: ADOWrite, for key: PRKey, as account: String?, in generation: Int) async throws -> ADOWrite.Answer {
        guard generation == self.generation, !isStopped else { throw CancellationError() }
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

    /// Reads a pull request's tags again, which show as they're read, after a change that may have changed them though Azure
    /// DevOps didn't say how. When they can't be read now, as when it asked BriefBar to wait, after a 503, or you're offline,
    /// they're read as soon as they can be, while its details show (`unsure`).
    private func readAgain(_ key: PRKey) async {
        guard !isStopped else { return }
        let started = now()
        unsure[key] = started
        switch await readCounting(key) {
        case .success?:
            read(key, startedAt: started)
        case .failure?:
            failedAt[key] = now()
        case nil:
            // The demo, which reads nothing; or Azure DevOps stopped.
            unsure[key] = nil
        }
    }

    /// A pull request's tags were read, by a read that started at `startedAt`: they're sure, unless a change may have
    /// changed them since it started; and reading them works again, unless one that failed since it started says otherwise.
    private func read(_ key: PRKey, startedAt: Date) {
        if let failed = failedAt[key], failed <= startedAt { failedAt[key] = nil }
        if let since = unsure[key], since <= startedAt { unsure[key] = nil }
    }

    /// Reads a pull request's tags (`readNow`), counted while it's under way (`reading`), so its details don't read them too
    /// meanwhile.
    private func readCounting(_ key: PRKey) async -> Result<[PullRequestTag], ADOError>? {
        reading[key, default: 0] += 1
        let result = await readNow(key)
        doneReading(key)
        return result
    }

    private func doneReading(_ key: PRKey) {
        let left = reading[key, default: 0] - 1
        reading[key] = left > 0 ? left : nil
    }

    /// Whether a pull request's tags are being read now, which tests wait for: what it read is done with once they aren't.
    func isReading(_ key: PRKey) -> Bool { reading[key] != nil }

    /// After a change Azure DevOps answered, which shows already: the engine keeps the tags it left, then reads them again,
    /// for anyone else's change meanwhile (`readAfterChange`), in a task that stopping calls off, counted as a read of them.
    private func readAgain(afterChanging key: PRKey, to tags: [PullRequestTag]) {
        reading[key, default: 0] += 1
        let readAfterChange = readAfterChange
        Task { [weak self] in
            _ = await self?.tracked { await readAfterChange(key, tags) }
            self?.doneReading(key)
        }
    }

    /// Reads a pull request's tags (`readTags`), in a task that stopping calls off (`tracked`).
    private func readNow(_ key: PRKey) async -> Result<[PullRequestTag], ADOError>? {
        let readTags = readTags
        return await tracked { await readTags(key) }
    }

    /// A read of tags, in a task that stopping calls off, as Azure DevOps is turned off, as one that waits for the Azure CLI's
    /// sign-in: none starts once it's stopped, and one that answers after says nothing (nil), as in the demo, which reads
    /// nothing. Turning Make Changes in Azure DevOps off doesn't call them off: those it reads after a change called off
    /// show how the tags stand.
    private func tracked(
        _ read: @escaping @MainActor () async -> Result<[PullRequestTag], ADOError>?
    ) async -> Result<[PullRequestTag], ADOError>? {
        guard !isStopped else { return nil }
        let id = UUID()
        let task = Task { await read() }
        readTasks[id] = task
        let result = await task.value
        readTasks[id] = nil
        return isStopped || task.isCancelled ? nil : result
    }

    // MARK: Tags lists don't carry

    /// How long the tags of a pull request whose lists don't carry them stay as they were read (`PRRecord.tagsReadAt`): its
    /// details read them again after that, as they show, or while they stay on screen.
    static let readAgainAfter: TimeInterval = 600
    /// How long after a read here failed it's tried again.
    static let retryAfter: TimeInterval = 30
    /// How often details that stay on screen look whether their tags are due to be read again: shorter in tests.
    var checkEvery: Duration = .seconds(30)

    /// The pages windows show on screen (`PullRequestCodeStore.page`).
    private var visiblePages: Set<String> = []
    /// The pull requests whose details show, by what shows them, with the window's page they're on.
    private var followers: [UUID: (key: PRKey, page: String?)] = [:]
    /// How many times nothing showed each pull request anymore: a removal that answers after offers no Undo (`remove`).
    private var closings: [PRKey: Int] = [:]
    /// How many reads of each pull request's tags are under way: the details' own (`readIfNeeded`), and those after a change
    /// (`readCounting`, `readAgain(afterChanging:to:)`). The details don't start another while one is.
    private var reading: [PRKey: Int] = [:]
    /// When a read here of a pull request's tags failed last: it's tried again half a minute later.
    private var failedAt: [PRKey: Date] = [:]
    /// The pull requests whose tags a change may have changed though Azure DevOps didn't say how, with when, until a read
    /// that started since goes: due whatever their lists carry (`readAgain`).
    private var unsure: [PRKey: Date] = [:]
    /// The reads of tags under way, which stopping calls off (`tracked`).
    private var readTasks: [UUID: Task<Result<[PullRequestTag], ADOError>?, Never>] = [:]
    /// Azure DevOps stopped: nothing more is read or changed (`stop`).
    private var isStopped = false

    /// Follows a pull request's tags while its details show it on a window's page, until the task that follows it is
    /// cancelled, as when they close or show another: tags its lists don't carry are read, one request, while a window shows
    /// that page on screen, as it does, or once it does, and again ten minutes later while it stays there (`isDue`). Nothing
    /// for one whose lists carry them, which every refresh reads.
    /// - Parameter page: the window's page they're on (`PullRequestCodeStore.page`); nil outside one, where nothing's read.
    func follow(_ key: PRKey, on page: String?) async {
        let follower = UUID()
        followers[follower] = (key, page)
        defer {
            followers[follower] = nil
            // Nothing shows it anymore: Undo goes with its details, and one for a removal that answers after doesn't come.
            if !followers.values.contains(where: { $0.key == key }) {
                removed[key] = nil
                closings[key, default: 0] += 1
            }
        }
        readIfNeeded(key, on: page)
        let pause = checkEvery
        while !Task.isCancelled, !isStopped {
            try? await Task.sleep(for: pause)
            guard !Task.isCancelled else { break }
            readIfNeeded(key, on: page)
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

    /// Copilot sessions say they just changed these pull requests in Azure DevOps (`AgentRereads`): the tags their lists
    /// don't carry are read again, once, as their details show on screen, though they were read less than ten minutes ago,
    /// and a read that started before doesn't count (`unsure`). Those their lists carry, the refresh the sessions asked for
    /// reads; unknown ones are due anyway (`isDue`).
    func changedElsewhere(_ keys: Set<PRKey>) {
        guard !isStopped, let store else { return }
        let date = now()
        for key in keys {
            guard let record = store.record(for: key), record.tags != nil, record.tagsReadAt != nil else { continue }
            unsure[key] = date
        }
        for follower in followers.values where keys.contains(follower.key) {
            readIfNeeded(follower.key, on: follower.page)
        }
    }

    /// Whether a pull request's tags are due to be read on their own (`PulseEngine.readTags`), as the list has it: they're
    /// unknown, or the latest refresh's lists didn't carry them and they were read ten minutes ago or more
    /// (`PRRecord.tagsReadAt`), however long ago its details showed, or Make Changes in Azure DevOps went off and on.
    static func isDue(_ record: PRRecord, at now: Date) -> Bool {
        guard record.tags != nil else { return true }
        guard let readAt = record.tagsReadAt else { return false }
        return now.timeIntervalSince(readAt) >= readAgainAfter
    }

    /// Reads a pull request's tags when they're due (`isDue`), or a change may have changed them (`unsure`). Not on a page
    /// that isn't on screen, while they're being read, within half a minute of a read here that failed, or in the demo.
    private func readIfNeeded(_ key: PRKey, on page: String?) {
        guard !isStopped, let page, visiblePages.contains(page), reading[key] == nil, let store, store.mode == .live,
              let record = store.record(for: key)
        else { return }
        let now = now()
        if let failed = failedAt[key], now.timeIntervalSince(failed) < Self.retryAfter { return }
        guard unsure[key] != nil || Self.isDue(record, at: now) else { return }
        // Counted now, so that another look doesn't start one too before this one does.
        reading[key, default: 0] += 1
        Task { [weak self] in
            guard let self else { return }
            let result = await readNow(key)
            doneReading(key)
            switch result {
            case .success?:
                read(key, startedAt: now)
            case .failure?:
                failedAt[key] = self.now()
            case nil:
                break
            }
        }
    }

    // MARK: Forgetting

    /// Forgets what was going on, and calls off a change on its way, as the setting goes off, Azure DevOps stops or someone
    /// else signs in. Not what's read: the tags of a pull request whose lists don't carry them are read again as they're
    /// due (`isDue`), as the list has them.
    func forgetAll() {
        generation += 1
        for task in inFlight.values { task.cancel() }
        inFlight = [:]
        states = [:]
        removed = [:]
    }

    /// Stops for good, when Azure DevOps stops: the reads of tags under way are called off, and nothing more is read or
    /// changed.
    func stop() {
        isStopped = true
        forgetAll()
        for task in readTasks.values { task.cancel() }
        readTasks = [:]
        visiblePages = []
        followers = [:]
        reading = [:]
        failedAt = [:]
        unsure = [:]
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
