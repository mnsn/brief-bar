import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Combine
import CopilotTasks
import Foundation

/// The Copilot session of each pull request whose details show (`PullRequestSession`), kept up to date while they show it:
/// as BriefBar's tasks start and end, as you choose another, as Show Links' links change, and every ten seconds, as the
/// Copilot app's sessions start and stop, open and close. With Send Work to Copilot on, from the sessions its work could go
/// to, read as the details show (`CopilotTasksStore.sessionChoices`), and how work would reach its own
/// (`CopilotTasksStore.delivery(to:for:checksRepository:)`); with it off, only the sessions Show Links links to it, with
/// nothing to choose; with neither, none. The demo makes them up from its own tasks and the sessions Show Links links to
/// it, and reads nothing.
@MainActor
final class PullRequestSessions: ObservableObject {
    /// The session of each pull request followed, as found last.
    @Published private(set) var sessions: [PRKey: PullRequestSession] = [:]

    let copilot: CopilotTasksStore
    let links: Links
    /// What the list read of a pull request it has: the source's.
    var record: (PRKey) -> PRRecord? = { _ in nil }
    /// How often the Copilot app's sessions are read again while a pull request's details show: shorter in tests.
    var refreshEvery: Duration = .seconds(10)
    /// Hears of each session whose way there is checked, in tests.
    var deliveryCheckedForTests: ((_ sessionId: String) -> Void)?

    /// How long what the search for mentions found is kept: it reads up to 40 sessions' logs, so opening the same details
    /// again doesn't read them again.
    static let mentionsFreshFor: TimeInterval = 15 * 60

    /// A pull request that's followed, and what was read for it.
    private struct Followed {
        var record: PRRecord?
        var createdAt: Date?
        /// How many follow it: the details that show it, and pictures being drawn, which don't stop.
        var followers = 0
        /// The sessions its work could go to, as read last; nil until they're read.
        var found: [SessionChoice]?
        /// Which of the Copilot app's sessions mention it, once read: only when no session goes with it.
        var mentioned: Set<String>?
        /// How work would reach its session, as checked last, by the session's ID.
        var delivery: (id: String, value: PullRequestSession.Delivery)?
    }

    private var followed: [PRKey: Followed] = [:]
    /// The pull requests no longer followed whose sessions are kept, the latest last, to show at once as their details show
    /// again, such as when you come back from a page over them, until they're read again.
    private var kept: [PRKey] = []
    /// The most of those kept.
    static let keptLimit = 8
    /// Which of the Copilot app's sessions mention each pull request, and when that was read (`mentionsFreshFor`).
    private var mentionsRead: [PRKey: (at: Date, ids: Set<String>)] = [:]
    /// What's read or checked for each pull request outside the task that follows it, as things change, to stop it with
    /// that task (`stop(following:)`, `stopAll`).
    private var spawned: [PRKey: [UUID: Task<Void, Never>]] = [:]
    /// Stopped for good: nothing more is read.
    private var hasStopped = false
    /// For pictures (`prepare`): read once, without the search for mentions or how work would reach a session.
    private var isForPictures = false
    /// The pull requests read for now, and the sessions whose way there is checked now: one at a time, each.
    private var reading: Set<PRKey> = []
    private var checking: Set<String> = []
    private var isScheduled = false
    private var subscriptions: Set<AnyCancellable> = []

    init(copilot: CopilotTasksStore, links: Links) {
        self.copilot = copilot
        self.links = links
        // BriefBar's tasks, Send Work to Copilot, the sessions you choose, and Show Links: once they've changed.
        copilot.objectWillChange
            .merge(with: copilot.settings.$copilotPullRequestSessions.map { _ in () })
            .merge(with: links.$graph.map { _ in () }, links.$isOn.map { _ in () })
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.scheduleUpdate() } }
            .store(in: &subscriptions)
    }

    /// A pull request's session, while it's followed, as its details show: as found last, or, for a while after, as it was
    /// when they last showed (`keptLimit`).
    func session(for key: PRKey) -> PullRequestSession? {
        sessions[key]
    }

    // MARK: Following

    /// Follows a pull request's session while its details show it: reads the sessions its work could go to now, then
    /// every ten seconds, until the task that follows it is cancelled, as when its details close or show another.
    func follow(_ item: PRSnapshot, record: PRRecord?) async {
        let key = item.key
        start(following: key, record: record, createdAt: item.createdAt)
        defer { stop(following: key) }
        let pause = refreshEvery
        while !Task.isCancelled, !hasStopped {
            // Each as a task of its own, which stopping cancels too, such as a search of the logs that's under way.
            await awaitSpawned(for: key) { [weak self] in await self?.read(key) }
            await awaitSpawned(for: key) { try? await Task.sleep(for: pause) }
        }
    }

    /// Does `work` in a task that stops with the pull request's following, or with everything (`spawn`), and with the
    /// task that waits for it.
    private func awaitSpawned(for key: PRKey, _ work: @escaping @MainActor () async -> Void) async {
        guard let task = spawn(for: key, work) else { return }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// Reads these pull requests' sessions once, for pictures, as they stand now: pictures follow nothing, and show neither
    /// the guess nor how work would reach a session, so neither the logs are searched for mentions nor that is checked.
    func prepare(_ items: [PRSnapshot]) async {
        isForPictures = true
        for item in items {
            start(following: item.key, record: record(item.key), createdAt: item.createdAt)
            await read(item.key)
        }
    }

    private func start(following key: PRKey, record: PRRecord?, createdAt: Date?) {
        kept.removeAll { $0 == key }
        var state = followed[key] ?? Followed()
        state.followers += 1
        state.record = record ?? state.record
        state.createdAt = createdAt ?? record?.pullRequest.createdAt ?? state.createdAt
        followed[key] = state
        update(key)
    }

    private func stop(following key: PRKey) {
        guard var state = followed[key] else { return }
        state.followers -= 1
        if state.followers > 0 {
            followed[key] = state
        } else {
            followed[key] = nil
            spawned.removeValue(forKey: key)?.values.forEach { $0.cancel() }
            // Its session stays a while, for its details to show it at once when they show again.
            kept.append(key)
            while kept.count > Self.keptLimit {
                sessions[kept.removeFirst()] = nil
            }
        }
    }

    /// Stops for good, when Azure DevOps stops: what's being read stops too, such as a search of the logs for mentions.
    func stopAll() {
        hasStopped = true
        subscriptions = []
        spawned.values.flatMap(\.values).forEach { $0.cancel() }
        spawned = [:]
        followed = [:]
        kept = []
        sessions = [:]
        mentionsRead = [:]
    }

    /// Reads or checks for a followed pull request, until it's no longer followed or everything stops.
    @discardableResult
    private func spawn(for key: PRKey, _ work: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        guard !hasStopped else { return nil }
        let id = UUID()
        // On the main actor, after it's kept: done, it goes.
        let task = Task { [weak self] in
            await work()
            self?.spawned[key]?[id] = nil
        }
        spawned[key, default: [:]][id] = task
        return task
    }

    // MARK: Choosing

    /// Sends a pull request's work to a session from now on, or to a new session for nil, as you choose it in its menu or
    /// answer its question: only while Send Work to Copilot is on.
    func use(_ choice: SessionChoice?, for key: PRKey) {
        guard copilot.isOn else { return }
        copilot.settings.choose(session: choice?.id, for: key)
    }

    /// Forgets what you chose for a pull request's work: BriefBar suggests a session again.
    func letBriefBarChoose(for key: PRKey) {
        copilot.settings.forgetChosenSession(for: key)
    }

    // MARK: Finding it

    /// A pull request's session, found now, for one whose details don't show it, and checked to the end: how work would
    /// reach it, the folder it works in being a clone of its repository too, which runs git there. Nil while Send Work to
    /// Copilot and Show Links are off, and while it's closed and Show Links is off.
    func find(_ record: PRRecord) async -> PullRequestSession? {
        let key = record.id
        guard copilot.isOn, record.pullRequest.status == .active else {
            return linked(key, chosen: copilot.settings.chosenSession(for: key))
        }
        let pullRequest = PullRequestTasks.task(for: record)
        switch copilot.mode {
        case .demo:
            var session = PullRequestSession.make(
                demoChoices(for: key, pullRequest: pullRequest), chosen: copilot.settings.chosenSession(for: key),
                lastTask: copilot.lastTask(forPullRequest: key), createdAt: record.pullRequest.createdAt, canChoose: true
            )
            session.delivery = session.session.map(demoDelivery)
            return session
        case .live:
            guard var session = await copilot.pullRequestSession(for: pullRequest, createdAt: record.pullRequest.createdAt) else {
                return nil
            }
            if let choice = session.session {
                session.delivery = await copilot.delivery(to: choice, for: pullRequest, checksRepository: true)
            }
            return session
        }
    }

    // MARK: Reading

    /// Whether a followed pull request's sessions can be read now: Send Work to Copilot is on, outside the demo, and it's
    /// open.
    private func isReadable(_ key: PRKey) -> Bool {
        guard !hasStopped, !Task.isCancelled, copilot.mode == .live, copilot.canSend, copilot.isOn, let state = followed[key],
              let record = current(state, key)
        else { return false }
        return record.pullRequest.status == .active
    }

    /// Reads the sessions a followed pull request's work could go to, the Copilot app's database and the sessions' state,
    /// off the main thread; which of the app's sessions mention it, once, and only when none goes with it; and how work
    /// would reach its session. Only while Send Work to Copilot is on and it's open, never in the demo; for pictures, only
    /// its sessions.
    private func read(_ key: PRKey) async {
        guard !reading.contains(key) else { return }
        guard isReadable(key), let state = followed[key], let record = current(state, key) else {
            update(key)
            return
        }
        reading.insert(key)
        defer { reading.remove(key) }
        let subject = TaskSubject.pullRequest(PullRequestTasks.task(for: record), .fixComments)
        let found = await copilot.sessionChoices(for: subject)
        // Cancelled meanwhile, as when its details closed, what was read is left out: whatever still follows it reads again.
        guard !Task.isCancelled, followed[key] != nil, copilot.isOn else { return }
        followed[key]?.found = found
        update(key)
        guard !isForPictures else { return }
        if case .newSession(chosenByYou: false)? = sessions[key]?.pick, followed[key]?.mentioned == nil {
            if let known = mentionsRead[key], Date().timeIntervalSince(known.at) < Self.mentionsFreshFor {
                followed[key]?.mentioned = known.ids
            } else {
                let mentioned = await copilot.sessionsMentioning(subject, among: found, since: state.createdAt)
                // A search cut short isn't kept.
                guard !Task.isCancelled, followed[key] != nil, copilot.isOn else { return }
                mentionsRead[key] = (Date(), mentioned)
                followed[key]?.mentioned = mentioned
            }
            update(key)
        }
        await checkDelivery(key)
    }

    /// How work would reach a followed pull request's session now, but for its repository, which doesn't change while its
    /// details show and is checked as work goes there: only for one whose work can go there, once its sessions were read.
    /// - Parameter unlessKnown: only if it isn't known yet for that session, as when it changed; a read checks it again.
    private func checkDelivery(_ key: PRKey, unlessKnown: Bool = false) async {
        guard isReadable(key), let state = followed[key], state.found != nil, let record = current(state, key),
              let session = sessions[key], session.canChoose, let choice = session.session, !choice.isUnavailable,
              !checking.contains(choice.id), !unlessKnown || session.delivery == nil
        else { return }
        checking.insert(choice.id)
        defer { checking.remove(choice.id) }
        deliveryCheckedForTests?(choice.id)
        let value = await copilot.delivery(to: choice, for: PullRequestTasks.task(for: record), checksRepository: false)
        // Busy says itself as it changes (`update`).
        guard !Task.isCancelled, followed[key] != nil, copilot.isOn else { return }
        if case .busy = value { return }
        followed[key]?.delivery = (choice.id, value)
        update(key)
    }

    // MARK: Keeping up

    /// Once what changed has: every followed pull request's session as things are now.
    private func scheduleUpdate() {
        guard !isScheduled else { return }
        isScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isScheduled = false
                self.updateAll()
            }
        }
    }

    /// Every followed pull request's session as things are now, without reading anything more: for tests, and as things
    /// change.
    func updateAll() {
        for key in followed.keys { update(key) }
    }

    /// A followed pull request's session as things are now, from what was read last, BriefBar's tasks as they are, the
    /// session you chose and Show Links' links; reading its sessions once Send Work to Copilot is on, and how work would
    /// reach its session once that changed. What was read goes once Send Work to Copilot is off.
    private func update(_ key: PRKey) {
        guard var state = followed[key] else { return }
        if !copilot.isOn, state.found != nil || state.mentioned != nil || state.delivery != nil {
            state.found = nil
            state.mentioned = nil
            state.delivery = nil
            followed[key] = state
            mentionsRead = [:]
        }
        let session = make(state, key)
        if sessions[key] != session { sessions[key] = session }
        guard isReadable(key), !isForPictures else { return }
        if state.found == nil {
            if !reading.contains(key) { spawn(for: key) { [weak self] in await self?.read(key) } }
        } else if let session, session.canChoose, session.delivery == nil, let choice = session.session, !choice.isUnavailable,
                  !checking.contains(choice.id) {
            spawn(for: key) { [weak self] in await self?.checkDelivery(key, unlessKnown: true) }
        }
    }

    /// What the list read of it now, or else as it was followed.
    private func current(_ state: Followed, _ key: PRKey) -> PRRecord? {
        record(key) ?? state.record
    }

    private func make(_ state: Followed, _ key: PRKey) -> PullRequestSession? {
        let chosen = copilot.settings.chosenSession(for: key)
        guard copilot.isOn, let record = current(state, key), record.pullRequest.status == .active else {
            return linked(key, chosen: chosen)
        }
        let pullRequest = PullRequestTasks.task(for: record)
        let choices: [SessionChoice]
        switch copilot.mode {
        case .demo:
            choices = demoChoices(for: key, pullRequest: pullRequest)
        case .live:
            // Until they're read, as they were, rather than nothing in between.
            guard copilot.canSend, let found = state.found else { return copilot.canSend ? sessions[key] : nil }
            choices = currentChoices(found, pullRequest: pullRequest, mentioned: state.mentioned, createdAt: state.createdAt)
        }
        var session = PullRequestSession.make(
            choices, chosen: chosen, lastTask: copilot.lastTask(forPullRequest: key), createdAt: state.createdAt, canChoose: true
        )
        if let choice = session.session {
            if choice.isUnavailable {
                session.delivery = PullRequestSession.delivery(for: choice, cliProblem: nil, reach: nil, canOpenInApp: copilot.canOpenInApp)
            } else if copilot.mode == .demo {
                session.delivery = demoDelivery(choice)
            } else if let known = state.delivery, known.id == choice.id {
                session.delivery = known.value
            }
        }
        return session
    }

    /// The sessions as they stand now: BriefBar's tasks as they are; the Copilot app's as they were read last, with why
    /// Show Links links them as it does now; whose logs mention it, as read; each as available as it is now
    /// (`CopilotTasksStore.availability`).
    private func currentChoices(
        _ found: [SessionChoice], pullRequest: TaskPullRequest, mentioned: Set<String>?, createdAt: Date?
    ) -> [SessionChoice] {
        let subject = TaskSubject.pullRequest(pullRequest, .fixComments)
        let open = Set(found.filter(\.isOpenInApp).map(\.id))
        var tasks = copilot.taskChoices(for: subject)
        for index in tasks.indices {
            tasks[index].isOpenInApp = open.contains(tasks[index].id)
        }
        let taskIDs = Set(tasks.map(\.id))
        let linked = copilot.linkedReasons(for: subject)
        let apps = found.compactMap { choice -> SessionChoice? in
            guard let session = choice.appSession, !taskIDs.contains(choice.id) else { return nil }
            var choice = choice
            choice.reasons = CopilotTasksStore.reasons(for: session, subject: subject, linked: linked[session.id] ?? [])
            return choice
        }
        let all = tasks + CopilotTasksStore.sorted(apps, createdAt: createdAt)
        guard let mentioned, !mentioned.isEmpty else { return copilot.availability(of: all) }
        return copilot.marking(mentioned, in: all, createdAt: createdAt)
    }

    // MARK: Show Links' sessions

    /// What Show Links knows, for a pull request without Send Work to Copilot, or that's closed: the sessions it links to
    /// it, the one you chose for it if it's one of them, and nothing to choose. Nil while it's off, or links none.
    private func linked(_ key: PRKey, chosen: PullRequestSessionChoice?) -> PullRequestSession? {
        let choices = linkedChoices(key)
        guard !choices.isEmpty else { return nil }
        return PullRequestSession.make(choices, chosen: chosen?.session == nil ? nil : chosen, lastTask: nil, createdAt: nil, canChoose: false)
    }

    /// The sessions Show Links links to a pull request, each as the Copilot app's, with why, the likeliest first: what the
    /// source that lists each says of it is all that's known.
    private func linkedChoices(_ key: PRKey) -> [SessionChoice] {
        guard links.isOn else { return [] }
        let choices = links.connections(of: key.linkRef).filter { $0.item.ref.kind == .session }.map { connection in
            let item = connection.item
            var reasons: Set<SessionChoice.Reason> = []
            for origin in connection.origins {
                switch origin {
                case .copilot: reasons.insert(.recordedByCopilot)
                case .branch: reasons.insert(.onItsBranch)
                case .you: reasons.insert(.linkedByYou)
                case .azureDevOps: reasons.insert(.linked)
                }
            }
            if connection.via != nil || reasons.isEmpty { reasons.insert(.linked) }
            let session = AppSession(
                id: item.ref.id, name: item.label, branch: item.hint?.branch,
                isRunning: item.state == .running || item.state == .needsYou, lastActive: item.date
            )
            return SessionChoice(kind: .app(session), name: item.label, place: item.place, lastActive: item.date, reasons: reasons.sorted())
        }
        return CopilotTasksStore.sorted(choices, createdAt: nil)
    }

    // MARK: The demo

    /// The demo's: its made-up tasks on the pull request, or the one that opened it, each as a task in a worktree of its
    /// own; and the sessions Show Links links to it, from the Copilot demo. Nothing's read.
    private func demoChoices(for key: PRKey, pullRequest: TaskPullRequest) -> [SessionChoice] {
        let link = key.linkRef
        let repository = CopilotTasksStore.demoRepository(for: .pullRequest(pullRequest, .fixComments)).root
        var tasks: [SessionChoice] = []
        for entry in copilot.entries {
            let reason: SessionChoice.Reason
            if entry.isOn(key) {
                reason = .earlierTask
            } else if entry.workItem != nil, entry.pullRequest.flatMap({ ItemRef.from(link: $0.absoluteString) }) == link {
                reason = .openedIt
            } else {
                continue
            }
            let folder = entry.onPullRequest.map { "pr-\($0.id)" } ?? entry.workItem.map { "wi-\($0.id)" } ?? entry.id
            let run = CopilotRun(
                id: entry.id, workItem: entry.workItem, onPullRequest: entry.onPullRequest, action: entry.action, options: entry.options,
                repository: repository,
                worktree: repository.deletingLastPathComponent().appendingPathComponent("copilot-worktrees/\(repository.lastPathComponent)/\(folder)"),
                startedAt: entry.startedAt, process: DetachedProgram.Handle(pid: 0, startedAt: nil),
                ended: entry.status.phase.isActive ? nil : entry.status.phase, pullRequest: entry.pullRequest
            )
            tasks.append(SessionChoice(
                kind: .task(run), name: copilot.name(of: entry), place: entry.onPullRequest?.repository ?? pullRequest.repository,
                lastActive: entry.status.since ?? entry.startedAt, reasons: [reason], isBusy: entry.status.phase.isActive
            ))
        }
        let ids = Set(tasks.map(\.id))
        return copilot.availability(of: tasks + linkedChoices(key).filter { !ids.contains($0.id) })
    }

    /// How the demo says work would reach a session: in the Copilot app for one of its sessions, with the CLI for a task of
    /// BriefBar's, unless Copilot works in it, as for one that isn't made up. It sends nothing, and reads nothing.
    private func demoDelivery(_ choice: SessionChoice) -> PullRequestSession.Delivery {
        PullRequestSession.delivery(for: choice, cliProblem: nil, reach: nil, canOpenInApp: true)
    }
}
