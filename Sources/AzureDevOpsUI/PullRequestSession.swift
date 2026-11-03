import AzureDevOpsCore
import BriefBarCore
import CopilotTasks
import Foundation

/// The Copilot session you chose for a pull request's work, with **Use for This Pull Request** in the menu of the line under
/// its heading, or a new session: kept in the preferences (`ado.copilot.pullRequestSessions`) as references only, never
/// names, as Show Links keeps the links you make (`LinkEdits`), and forgotten after as long.
struct PullRequestSessionChoice: Codable, Equatable, Sendable {
    /// The pull request.
    let pullRequest: ItemRef
    /// The session; nil for a new session.
    let session: ItemRef?
    /// When you chose it: a task that BriefBar starts on the pull request afterwards, in whatever session, takes its place.
    let date: Date

    /// Nil when `id` isn't a session's.
    init?(pullRequest key: PRKey, session id: String?, date: Date) {
        var session: ItemRef?
        if let id {
            guard let ref = ItemRef.session(id) else { return nil }
            session = ref
        }
        pullRequest = key.linkRef
        self.session = session
        self.date = date
    }

    /// Checked as when it was made: any program running as you can write the preferences.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pullRequest = try container.decode(ItemRef.self, forKey: .pullRequest)
        session = try container.decodeIfPresent(ItemRef.self, forKey: .session)
        date = try container.decode(Date.self, forKey: .date)
        guard pullRequest.kind == .pullRequest, session.map({ $0.kind == .session }) ?? true else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a pull request's session"))
        }
    }

    func isFor(_ key: PRKey) -> Bool {
        pullRequest == key.linkRef
    }

    /// How long a choice is kept: as long as a link you make, by when you made it.
    static let lifetime = LinkEdits.lifetime

    /// The choices kept in the preferences: the latest for each pull request, without what can't be read, such as what
    /// another program wrote there, and those older than `lifetime`.
    static func load(from defaults: UserDefaults, now: Date = Date()) -> [PullRequestSessionChoice] {
        guard let data = defaults.data(forKey: SettingsKey.copilotPullRequestSessions),
              let records = try? JSONDecoder().decode([Lossy].self, from: data)
        else { return [] }
        return kept(records.compactMap(\.value), now: now)
    }

    /// Leaves in the preferences only what `load` kept of them, when they hold more or other, such as choices that expired:
    /// as Show Links forgets the links you made. Compared as read, since writing the same choices again needn't give the
    /// same bytes.
    static func prune(to kept: [PullRequestSessionChoice], in defaults: UserDefaults) {
        guard defaults.object(forKey: SettingsKey.copilotPullRequestSessions) != nil else { return }
        let records = defaults.data(forKey: SettingsKey.copilotPullRequestSessions)
            .flatMap { try? JSONDecoder().decode([Lossy].self, from: $0) }?.map(\.value)
        guard records != kept.map(Optional.some) else { return }
        if !kept.isEmpty, let data = try? JSONEncoder().encode(kept) {
            defaults.set(data, forKey: SettingsKey.copilotPullRequestSessions)
        } else {
            defaults.removeObject(forKey: SettingsKey.copilotPullRequestSessions)
        }
    }

    /// The latest choice for each pull request, made since `lifetime` ago, the oldest first.
    static func kept(_ choices: [PullRequestSessionChoice], now: Date) -> [PullRequestSessionChoice] {
        let cutoff = now.addingTimeInterval(-lifetime)
        var latest: [ItemRef: PullRequestSessionChoice] = [:]
        for choice in choices where choice.date >= cutoff && choice.date <= now.addingTimeInterval(60) {
            if let known = latest[choice.pullRequest], known.date >= choice.date { continue }
            latest[choice.pullRequest] = choice
        }
        return latest.values.sorted { ($0.date, $0.pullRequest) < ($1.date, $1.pullRequest) }
    }

    /// A choice that decodes to nil instead of failing, so one odd record doesn't lose the rest.
    private struct Lossy: Decodable {
        var value: PullRequestSessionChoice?

        init(from decoder: Decoder) throws {
            value = try? decoder.singleValueContainer().decode(PullRequestSessionChoice.self)
        }
    }
}

/// The Copilot session a pull request's work goes to, as BriefBar works it out, with the sessions it could go to instead
/// and how work would reach it now: for the line under its heading in its details (`PullRequestSessionLine`), for what
/// sends its work there, and for agents (`pull_request`). One session for each pull request: the one you chose, unless a
/// task started on it since; else its last task's; else the work item's task that opened it; else the Copilot app's
/// session that Copilot recorded with it, that you linked to it or that's on its branch. When two of those go with it as
/// well as each other, BriefBar asks which rather than guess; and a session whose log only mentions it is a guess, which
/// is offered, never picked.
struct PullRequestSession: Equatable, Sendable {
    /// Why a session is the pull request's.
    enum Basis: Equatable, Sendable {
        /// You chose it, with Use for This Pull Request.
        case chosenByYou
        /// Its last task's, which BriefBar sent.
        case lastTask
        /// The work item's task that opened it.
        case openedIt
        /// The Copilot app records that it started from it, or opened it.
        case recordedByCopilot
        /// It works on its branch, in its repository.
        case onItsBranch
        /// You linked them, with Show Links.
        case linkedByYou

        /// "on its branch", in the middle of a sentence.
        var phrase: String {
            switch self {
            case .chosenByYou: return "chosen by you"
            case .lastTask: return "its last task"
            case .openedIt: return "opened it"
            case .recordedByCopilot: return "recorded by Copilot"
            case .onItsBranch: return "on its branch"
            case .linkedByYou: return "linked by you"
            }
        }

        /// Why one of the Copilot app's sessions goes with it, as the best of its reasons says.
        init?(_ reason: SessionChoice.Reason) {
            switch reason {
            case .recordedByCopilot: self = .recordedByCopilot
            case .onItsBranch: self = .onItsBranch
            case .linkedByYou: self = .linkedByYou
            case .openedIt: self = .openedIt
            case .earlierTask: self = .lastTask
            case .linked, .mentionsIt: return nil
            }
        }
    }

    /// Where its work goes.
    enum Pick: Equatable, Sendable {
        /// A session that's there already, and why it's the pull request's.
        case session(SessionChoice, Basis)
        /// A new session: you chose one, or no session goes with it.
        case newSession(chosenByYou: Bool)
        /// Two or more sessions go with it as well as each other, the most recently active first: BriefBar asks which,
        /// rather than guess.
        case ask([SessionChoice])
    }

    /// How work would reach the session now, as the Send to Copilot window sends it unless you choose otherwise.
    enum Delivery: Equatable, Sendable {
        /// The Copilot CLI goes on with it now, on its own, in the folder it works in: a task of BriefBar's, while it can.
        case cli
        /// In the Copilot app, as Send to Session sends it: BriefBar's extension in the session sends it the prompt, now or
        /// once the app loads it, as `reach` says (`CopilotTasksStore.reach(of:)`); or, when it can't
        /// (`SessionReach.whyNot`), BriefBar copies the prompt and opens the session, for you to paste it there; nil while
        /// that isn't known. The Copilot app's sessions go there, and a task of BriefBar's that the app has open or that
        /// the CLI can't go on with, as `reason` says.
        case app(reach: SessionReach?, reason: String?)
        /// Nothing goes to it until Copilot is done working in it, or in its checkout: why.
        case busy(String)
        /// Nothing can go to it from here: why.
        case unavailable(String)

        /// BriefBar hands it the prompt itself: the CLI, or BriefBar's extension in the session.
        var sendsItself: Bool {
            switch self {
            case .cli: return true
            case .app(let reach, _): return reach?.sends(forking: false) == true
            case .busy, .unavailable: return false
            }
        }
    }

    var pick: Pick
    /// The sessions that go with it, with why: BriefBar's tasks on it and the work item's task that opened it, the newest
    /// first; then the Copilot app's, the likeliest first, those whose logs only mention it last; and the one you chose,
    /// wherever it's from.
    var candidates: [SessionChoice]
    /// The Copilot app's other sessions, the most recently active first, to choose one of them instead.
    var others: [SessionChoice]
    /// One of the app's sessions whose log has a link to it and that was there before it was created, when no session goes
    /// with it: it may have opened it, but that's a guess, which the menu offers and nothing picks.
    var guess: SessionChoice?
    /// How work would reach the session it goes to, once that's checked; nil otherwise, for a new session and while it asks.
    var delivery: Delivery?
    /// You can choose where its work goes: Send Work to Copilot is on, and it's open. Otherwise it only shows the sessions
    /// Show Links links to it, and does nothing with them.
    var canChoose: Bool

    /// The session its work goes to, when there's one.
    var session: SessionChoice? {
        if case .session(let choice, _) = pick { return choice }
        return nil
    }

    /// Why its session is its, when there's one.
    var basis: Basis? {
        if case .session(_, let basis) = pick { return basis }
        return nil
    }

    /// The most of the app's other sessions it lists, as the Send to Copilot window's menu does.
    static let otherLimit = 30

    /// What make one of the Copilot app's sessions the pull request's.
    static let likelyReasons: Set<SessionChoice.Reason> = [.recordedByCopilot, .onItsBranch, .linkedByYou]

    /// The latest task BriefBar started on a pull request (`CopilotTasksStore.lastTask`): its session's ID, and when.
    struct LastTask: Equatable, Sendable {
        var id: String
        var startedAt: Date
    }

    /// The pull request's session among the sessions its work could go to (`CopilotTasksStore.sessionChoices`, in their
    /// order: BriefBar's tasks, the newest first, then the Copilot app's), with the sessions it lists and its guess.
    static func make(
        _ choices: [SessionChoice], chosen: PullRequestSessionChoice?, lastTask: LastTask?, createdAt: Date?, canChoose: Bool
    ) -> PullRequestSession {
        let pick = pick(choices, chosen: chosen, lastTask: lastTask)
        var candidates = choices.filter { $0.run != nil || !$0.reasons.isEmpty }
        if case .session(let choice, _) = pick, !candidates.contains(where: { $0.id == choice.id }) {
            candidates.append(choice)
        }
        let listed = Set(candidates.map(\.id))
        let others = Array(choices.filter { !listed.contains($0.id) }.prefix(otherLimit))
        let guess: SessionChoice? = if case .newSession(chosenByYou: false) = pick { Self.guess(choices, createdAt: createdAt) } else { nil }
        return PullRequestSession(pick: pick, candidates: candidates, others: others, guess: guess, canChoose: canChoose)
    }

    /// Where its work goes: the session you chose, or a new one if you chose that, unless BriefBar started a task on it
    /// since (`chosen(_:after:)`); else the session of its last task, as the Send to Copilot window goes on with it, whether
    /// or not Copilot still works in it, while its worktree is there; else the session of the work item's task that opened
    /// it; else the Copilot app's session that Copilot recorded with it, that you linked to it or that's on its branch. Two
    /// of those go with it as well as each other unless one has every reason the other has and more: then BriefBar asks
    /// which. Else a new session: one whose log only mentions it is a guess (`guess`).
    static func pick(_ choices: [SessionChoice], chosen: PullRequestSessionChoice?, lastTask: LastTask?) -> Pick {
        if let chosen = Self.chosen(chosen, after: lastTask) {
            guard let id = chosen.session?.id else { return .newSession(chosenByYou: true) }
            // One that's gone, such as a task you cleared, or a session the app archived, leaves it to the rest.
            if let session = choices.first(where: { $0.id == id }) { return .session(session, .chosenByYou) }
        }
        let tasks = choices.filter { $0.run != nil }
        if let lastTask, let last = tasks.first(where: { $0.id == lastTask.id && $0.reasons.contains(.earlierTask) }) {
            return .session(last, .lastTask)
        }
        if let opener = tasks.first(where: { $0.reasons.contains(.openedIt) }) { return .session(opener, .openedIt) }
        let likely = choices.filter { $0.run == nil && !likelyReasons.isDisjoint(with: $0.reasons) }
        let best = likely.filter { choice in
            let reasons = likelyReasons.intersection(choice.reasons)
            return !likely.contains { other in
                other.id != choice.id && likelyReasons.intersection(other.reasons).isStrictSuperset(of: reasons)
            }
        }
        if best.count == 1, let only = best.first {
            let reason = likelyReasons.intersection(only.reasons).min() ?? .onItsBranch
            return .session(only, Basis(reason) ?? .onItsBranch)
        }
        if best.count > 1 {
            return .ask(best.sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) })
        }
        return .newSession(chosenByYou: false)
    }

    /// What you chose for its work, unless a task BriefBar started on it since, in whatever session, has taken its place.
    static func chosen(_ chosen: PullRequestSessionChoice?, after lastTask: LastTask?) -> PullRequestSessionChoice? {
        guard let chosen, (lastTask?.startedAt ?? .distantPast) <= chosen.date else { return nil }
        return chosen
    }

    /// Of the Copilot app's sessions whose logs only mention it, the oldest that was there before it was created, which may
    /// have opened it; nil without when it was created.
    static func guess(_ choices: [SessionChoice], createdAt: Date?) -> SessionChoice? {
        guard let createdAt else { return nil }
        return choices.filter { choice in
            guard let born = choice.appSession?.createdAt, choice.reasons.contains(.mentionsIt) else { return false }
            return likelyReasons.isDisjoint(with: choice.reasons) && born < createdAt
        }
        .min { ($0.appSession?.createdAt ?? .distantFuture) < ($1.appSession?.createdAt ?? .distantFuture) }
    }

    /// How work would reach a session, as the Send to Copilot window sends it unless you choose otherwise: not while Copilot
    /// works in it or in its checkout, for a task BriefBar sent; a task of BriefBar's with the Copilot CLI while it can go
    /// on with it (`cliProblem` is nil) and the app doesn't have it open; the rest in the Copilot app, as `reach` says,
    /// while an app opens the app's sessions; without one, with the CLI, while it can.
    @MainActor
    static func delivery(for choice: SessionChoice, cliProblem: String?, reach: SessionReach?, canOpenInApp: Bool) -> Delivery {
        if choice.isBusy { return .busy("Copilot is still working in it.") }
        if choice.isFolderBusy { return .busy("Copilot is working in its checkout for another task BriefBar sent.") }
        let isAppsOwn = isAppsOwn(choice)
        if !isAppsOwn, !choice.isOpenInApp, cliProblem == nil { return .cli }
        guard canOpenInApp else {
            guard let cliProblem else { return .cli }
            return .unavailable(isAppsOwn ? CopilotTasksStore.cantOpenInApp : cliProblem)
        }
        return .app(reach: reach, reason: isAppsOwn ? nil : cliProblem)
    }

    /// Whether it goes to the Copilot app as one of its own: one of the app's sessions, or a task of BriefBar's that went on
    /// with one.
    static func isAppsOwn(_ choice: SessionChoice) -> Bool {
        choice.appSession != nil || choice.run?.isAppSession == true
    }

    /// What a session is called where the pull request's details say it: one of the app's by its name; a task BriefBar
    /// sent by what for, "Fix the Build", or the work item it was sent for, "Work Item 5112".
    static func name(of choice: SessionChoice) -> String {
        guard let run = choice.run, run.isAppSession != true else { return choice.name }
        if let action = run.action { return action.title }
        if let workItem = run.workItem { return "Work Item \(workItem.id)" }
        return choice.name
    }
}

extension AppSettings {
    /// The session you chose for a pull request's work, or a new one, while it's kept.
    func chosenSession(for key: PRKey) -> PullRequestSessionChoice? {
        copilotPullRequestSessions.last { $0.isFor(key) }
    }

    /// Keeps the session you chose for a pull request's work, or a new one for nil, in place of what you chose before.
    func choose(session id: String?, for key: PRKey, at date: Date = Date()) {
        guard let choice = PullRequestSessionChoice(pullRequest: key, session: id, date: date) else { return }
        copilotPullRequestSessions = PullRequestSessionChoice.kept(
            copilotPullRequestSessions.filter { !$0.isFor(key) } + [choice], now: date
        )
    }

    /// Forgets what you chose for a pull request's work: BriefBar suggests a session again.
    func forgetChosenSession(for key: PRKey) {
        guard copilotPullRequestSessions.contains(where: { $0.isFor(key) }) else { return }
        copilotPullRequestSessions.removeAll { $0.isFor(key) }
    }
}

extension CopilotTasksStore {
    /// A pull request's session (`PullRequestSession`), as its details and agents tell it: the sessions its work could go
    /// to (`sessionChoices`), and, only when none goes with it, which of the app's mention it (`sessionsMentioning`), which
    /// takes longer and matters only then, for its guess; with the session you chose for it. Nil while Send Work to Copilot
    /// is off, and in the demo, which reads no sessions.
    func pullRequestSession(for pullRequest: TaskPullRequest, createdAt: Date?) async -> PullRequestSession? {
        // Where it goes doesn't depend on what it's for.
        let subject = TaskSubject.pullRequest(pullRequest, .fixComments)
        let key = PRKey(pullRequest.organization, pullRequest.id)
        let found = await sessionChoices(for: subject)
        // Again after that wait, as before every read of Copilot's: it may have been turned off meanwhile, or no longer be
        // wanted.
        guard canSend, isOn, !Task.isCancelled else { return nil }
        let session = PullRequestSession.make(
            found, chosen: settings.chosenSession(for: key), lastTask: lastTask(forPullRequest: key), createdAt: createdAt, canChoose: true
        )
        guard case .newSession(chosenByYou: false) = session.pick else { return session }
        let mentioned = await sessionsMentioning(subject, among: found, since: createdAt)
        guard canSend, isOn, !Task.isCancelled else { return nil }
        guard !mentioned.isEmpty else { return session }
        return PullRequestSession.make(
            marking(mentioned, in: found, createdAt: createdAt), chosen: settings.chosenSession(for: key),
            lastTask: lastTask(forPullRequest: key), createdAt: createdAt, canChoose: true
        )
    }

    /// The latest task BriefBar started on a pull request, that got as far as starting, whatever its session and however
    /// it stands: the one the Send to Copilot window goes on with, once it's done, and which takes the place of the session
    /// you chose for its work before it started. As its run was kept when it started: a send that goes on with an earlier
    /// task's session is the pull request's task only once it starts, so one that couldn't start leaves your choice be.
    func lastTask(forPullRequest key: PRKey) -> PullRequestSession.LastTask? {
        // The demo's made-up tasks have no run.
        if mode == .demo {
            return entries.first { $0.isOn(key) }.map { PullRequestSession.LastTask(id: $0.id, startedAt: $0.startedAt) }
        }
        return settings.copilotRuns
            .filter { $0.isValid && $0.onPullRequest?.matches(organization: key.organization, id: key.number) == true }
            .max { $0.startedAt < $1.startedAt }
            .map(PullRequestSession.LastTask.init)
    }

    /// How work for a pull request would reach a session now (`PullRequestSession.delivery`), as the Copilot app's database
    /// and the sessions' state say now (`cliProblem`), and, for one that goes to the Copilot app, BriefBar's extension in it
    /// (`reach(of:)`), which is read only while Send Prompts to Copilot Sessions is on.
    /// - Parameter checksRepository: whether the folder it works in has to be a clone of the pull request's repository,
    ///   which runs git there; without it, what's read is what the Send to Copilot window reads as it opens.
    func delivery(to choice: SessionChoice, for pullRequest: TaskPullRequest, checksRepository: Bool) async -> PullRequestSession.Delivery {
        if choice.isUnavailable {
            return PullRequestSession.delivery(for: choice, cliProblem: nil, reach: nil, canOpenInApp: canOpenInApp)
        }
        let problem = await cliProblem(for: choice, subject: .pullRequest(pullRequest, .fixComments), checksRepository: checksRepository)
        // How a prompt would reach it in the Copilot app, for one that goes there, as the window says it.
        let goesToApp = PullRequestSession.isAppsOwn(choice) || choice.isOpenInApp || problem != nil
        let reach = goesToApp && canOpenInApp && !Task.isCancelled ? await reach(of: choice) : nil
        // Copilot may have started working in it, or its checkout, meanwhile.
        let current = availability(of: [choice]).first ?? choice
        return PullRequestSession.delivery(for: current, cliProblem: problem, reach: reach, canOpenInApp: canOpenInApp)
    }
}

extension PullRequestSession.LastTask {
    /// A task's, as its run started.
    init(_ run: CopilotRun) {
        self.init(id: run.id, startedAt: run.startedAt)
    }
}
