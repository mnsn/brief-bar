import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Combine
import CopilotTasks
import Foundation

/// The Copilot session of each pull request whose details show (`PullRequestSession`), kept up to date while they show it:
/// as BriefBar's tasks start and end, as you choose another, as Show Links' links change, and every ten seconds, as the
/// Copilot app's sessions start and stop, open and close. With Send Work to Copilot on, from the sessions its work could go
/// to, read only while a window shows their details' page on screen (`setVisible`), as it does and every ten seconds while
/// it does (`CopilotTasksStore.sessionChoices`), and how work would reach its own
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
    /// Hears of each read of a pull request's sessions as it starts, before it looks for one under way, in tests, which may
    /// hold it up there, as a busy Mac may start it only once another is done.
    var readStartsForTests: (@MainActor (PRKey) async -> Void)?
    /// Hears of each read of a pull request's sessions, once they're read and before they're kept, in tests, which may hold
    /// it up there, as a slow read would be.
    var sessionsReadForTests: (@MainActor (PRKey) async -> Void)?

    /// How long what the search for mentions found is kept: it reads up to 40 sessions' logs, so opening the same details
    /// again doesn't read them again.
    static let mentionsFreshFor: TimeInterval = 15 * 60

    /// A pull request that's followed, and what was read for it.
    private struct Followed {
        var record: PRRecord?
        var createdAt: Date?
        /// The window's page each of what follows it is on (`PullRequestCodeStore.page`): the details that show it, nil
        /// outside a window's page, and pictures being drawn, which don't stop.
        var followers: [UUID: String?] = [:]
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
    /// The pages where a pull request's details can show that windows show on screen (`PullRequestCodeStore.page`).
    private var visiblePages: Set<String> = []
    /// The pull requests read for now, and those whose session's way there is checked now: one at a time, each.
    private var reading: Set<PRKey> = []
    private var checking: Set<PRKey> = []
    /// The pull requests to read again once the read under way ends: their window showed them again meanwhile.
    private var readAgain: Set<PRKey> = []
    /// The pull requests whose session to check again once the check under way ends: a read asked for one meanwhile.
    private var checkAgain: Set<PRKey> = []
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

    /// Follows a pull request's session while its details show it on a window's page: reads the sessions its work could go
    /// to while a window shows that page on screen, as it does, then every ten seconds, until the task that follows it is
    /// cancelled, as when its details close or show another.
    /// - Parameter page: the window's page its details are on (`PullRequestCodeStore.page`); nil outside one, where
    ///   nothing's read for it.
    func follow(_ item: PRSnapshot, record: PRRecord?, on page: String?) async {
        let key = item.key
        let follower = UUID()
        // Until its sessions have been read, starting to follow it reads them (`update`), and while no window shows its page
        // on screen, the first to show it does (`setVisible`). Then not here too: on a busy Mac, a read here could start only
        // once theirs was done, which would read them again, and check again how work would reach its session.
        var readsNow = !start(following: key, record: record, createdAt: item.createdAt, by: follower, on: page) && isOnScreen(key)
        defer { stop(following: key, by: follower) }
        let pause = refreshEvery
        while !Task.isCancelled, !hasStopped {
            // Each as a task of its own, which stopping cancels too, such as a search of the logs that's under way.
            if readsNow { await awaitSpawned(for: key) { [weak self] in await self?.read(key) } }
            // Again after each pause, if a window shows its page on screen then, which keeps up with it too once it can't be
            // read, such as once it's completed; not after a pause cut short as it went off screen (`callOff`), since a
            // window that shows it again reads them, for the same reason.
            readsNow = await awaitSpawned(for: key) { try? await Task.sleep(for: pause) } && isOnScreen(key)
        }
    }

    /// Does `work` in a task that stops with the pull request's following, or with everything (`spawn`), and with the
    /// task that waits for it.
    /// - Returns: whether it ran without being called off.
    @discardableResult
    private func awaitSpawned(for key: PRKey, _ work: @escaping @MainActor () async -> Void) async -> Bool {
        guard let task = spawn(for: key, work) else { return false }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        return !task.isCancelled
    }

    /// Reads these pull requests' sessions once, for pictures, as they stand now: pictures follow nothing, and show neither
    /// the guess nor how work would reach a session, so neither the logs are searched for mentions nor that is checked. What
    /// follows them meanwhile, as on no window's page, reads nothing.
    func prepare(_ items: [PRSnapshot]) async {
        var prepared: Set<PRKey> = []
        for item in items where prepared.insert(item.key).inserted {
            start(following: item.key, record: record(item.key), createdAt: item.createdAt, by: UUID(), on: nil)
            await read(item.key, forPictures: true)
        }
    }

    /// - Returns: whether its sessions are read, now or once the read under way ends (`update`).
    @discardableResult
    private func start(following key: PRKey, record: PRRecord?, createdAt: Date?, by follower: UUID, on page: String?) -> Bool {
        kept.removeAll { $0 == key }
        var state = followed[key] ?? Followed()
        state.followers.updateValue(page, forKey: follower)
        state.record = record ?? state.record
        state.createdAt = createdAt ?? record?.pullRequest.createdAt ?? state.createdAt
        followed[key] = state
        return update(key)
    }

    private func stop(following key: PRKey, by follower: UUID) {
        guard var state = followed[key] else { return }
        state.followers.removeValue(forKey: follower)
        if !state.followers.isEmpty {
            followed[key] = state
            // What still follows it is on pages no window shows on screen: what's being read or checked for it is called
            // off, as when they went off screen (`setVisible`).
            if !isOnScreen(state) { callOff(key) }
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

    /// A window started or stopped showing, on screen, a page where a pull request's details can show
    /// (`PullRequestCodeStore.page`), as for the code their comments are on: its pull requests' sessions are read only
    /// while one does. As it shows them, they're read again at once, with how work would reach their sessions; once none
    /// of their pages shows on screen, minimized, hidden or covered, what's being read or checked for them, such as a
    /// search of the logs for mentions, is called off.
    func setVisible(_ visible: Bool, for page: String) {
        if visible {
            guard visiblePages.insert(page).inserted else { return }
            for (key, state) in followed where state.followers.values.contains(page) {
                // One under way may have been called off as it went off screen: then once it ends.
                if reading.contains(key) {
                    readAgain.insert(key)
                } else {
                    spawn(for: key) { [weak self] in await self?.read(key) }
                }
            }
        } else {
            guard visiblePages.remove(page) != nil else { return }
            for (key, state) in followed where state.followers.values.contains(page) && !isOnScreen(state) {
                callOff(key)
            }
        }
    }

    /// Calls off what's being read or checked for a followed pull request, as nothing that follows it is on screen
    /// anymore. A read under way is read again as it ends, which reads only if something on screen follows it by then:
    /// as when its details open again on a page a window shows, whose sessions, read before, would otherwise wait for
    /// the next turn.
    private func callOff(_ key: PRKey) {
        spawned[key]?.values.forEach { $0.cancel() }
        if reading.contains(key) { readAgain.insert(key) }
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

    /// Whether a followed pull request's sessions can be read now: Send Work to Copilot is on, outside the demo, it's open,
    /// and a window shows its details on screen, unless it's read for pictures (`prepare`).
    private func isReadable(_ key: PRKey, forPictures: Bool = false) -> Bool {
        guard !hasStopped, !Task.isCancelled, copilot.mode == .live, copilot.canSend, copilot.isOn, let state = followed[key],
              forPictures || isOnScreen(state), let record = current(state, key)
        else { return false }
        return record.pullRequest.status == .active
    }

    /// Whether a window shows on screen the page that something following it is on.
    private func isOnScreen(_ state: Followed) -> Bool {
        state.followers.values.contains { $0.map(visiblePages.contains) ?? false }
    }

    /// Whether a window shows on screen the page that something following this pull request is on.
    private func isOnScreen(_ key: PRKey) -> Bool {
        followed[key].map(isOnScreen) ?? false
    }

    /// Reads the sessions a followed pull request's work could go to, the Copilot app's database and the sessions' state,
    /// off the main thread; which of the app's sessions mention it, once, and only when none goes with it; and how work
    /// would reach its session. Only while Send Work to Copilot is on and it's open, never in the demo; for pictures, only
    /// its sessions.
    private func read(_ key: PRKey, forPictures: Bool = false) async {
        await readStartsForTests?(key)
        guard !reading.contains(key) else { return }
        guard isReadable(key, forPictures: forPictures), let state = followed[key], let record = current(state, key) else {
            update(key)
            return
        }
        reading.insert(key)
        defer {
            reading.remove(key)
            if readAgain.remove(key) != nil { spawn(for: key) { [weak self] in await self?.read(key) } }
        }
        let subject = TaskSubject.pullRequest(PullRequestTasks.task(for: record), .fixComments)
        let found = await copilot.sessionChoices(for: subject)
        await sessionsReadForTests?(key)
        // Cancelled meanwhile, as when its details closed, what was read is left out: whatever still follows it reads again.
        guard !Task.isCancelled, followed[key] != nil, copilot.isOn else { return }
        followed[key]?.found = found
        update(key)
        guard !forPictures else { return }
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
              !unlessKnown || session.delivery == nil
        else { return }
        // One under way may have been called off, as its page went off screen and came back: a read's check follows it.
        guard !checking.contains(key) else {
            if !unlessKnown { checkAgain.insert(key) }
            return
        }
        checking.insert(key)
        deliveryCheckedForTests?(choice.id)
        let value = await copilot.delivery(to: choice, for: PullRequestTasks.task(for: record), checksRepository: false)
        checking.remove(key)
        if checkAgain.remove(key) != nil { spawn(for: key) { [weak self] in await self?.checkDelivery(key) } }
        guard !Task.isCancelled, followed[key] != nil, copilot.isOn else { return }
        if case .busy = value {
            // Busy says itself as it changes (`update`); but another session you chose meanwhile is checked now.
            if sessions[key]?.session?.id != choice.id { update(key) }
            return
        }
        followed[key]?.delivery = (choice.id, value)
        // And another session you chose meanwhile is checked now.
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
    /// - Returns: whether its sessions are read, now or once the read under way ends, since they haven't been read yet.
    @discardableResult
    private func update(_ key: PRKey) -> Bool {
        guard var state = followed[key] else { return false }
        if !copilot.isOn, state.found != nil || state.mentioned != nil || state.delivery != nil {
            state.found = nil
            state.mentioned = nil
            state.delivery = nil
            followed[key] = state
            mentionsRead = [:]
        }
        let session = make(state, key)
        if sessions[key] != session { sessions[key] = session }
        guard isReadable(key) else { return false }
        if state.found == nil {
            // One under way may be one called off, as its details closed and showed again: then once it ends.
            if reading.contains(key) {
                readAgain.insert(key)
            } else {
                spawn(for: key) { [weak self] in await self?.read(key) }
            }
            return true
        } else if let session, session.canChoose, session.delivery == nil, let choice = session.session, !choice.isUnavailable,
                  !checking.contains(key) {
            spawn(for: key) { [weak self] in await self?.checkDelivery(key, unlessKnown: true) }
        }
        return false
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
        let links = copilot.linkedSessions(CopilotTasksStore.ref(of: subject))
        let linked = CopilotTasksStore.reasons(of: links)
        let told = copilot.toldSince(of: links)
        let apps = found.compactMap { choice -> SessionChoice? in
            guard let session = choice.appSession, !taskIDs.contains(choice.id) else { return nil }
            var choice = choice
            choice.reasons = CopilotTasksStore.reasons(for: session, subject: subject, linked: linked[session.id] ?? [])
            choice.toldSince = told[session.id]
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
        let told = copilot.toldSince(key.linkRef)
        let choices = links.connections(of: key.linkRef).filter { $0.item.ref.kind == .session }.map { connection in
            let item = connection.item
            var reasons: Set<SessionChoice.Reason> = []
            for origin in connection.origins {
                switch origin {
                case .copilot: reasons.insert(.recordedByCopilot)
                case .session: reasons.insert(.toldBriefBar)
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
            return SessionChoice(
                kind: .app(session), name: item.label, place: item.place, lastActive: item.date, reasons: reasons.sorted(),
                toldSince: told[item.ref.id]
            )
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
