import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import Foundation

/// A Copilot session that a task can go to instead of a new one: one BriefBar started for an earlier task, or one of the
/// Copilot app's, such as the session that opened the pull request.
struct SessionChoice: Identifiable, Equatable {
    enum Kind: Equatable {
        /// BriefBar started it, for an earlier task, in a worktree of its own.
        case task(CopilotRun)
        /// One of the Copilot app's.
        case app(AppSession)
    }

    /// Why BriefBar suggests it, the most telling first.
    enum Reason: Int, Comparable, CaseIterable {
        /// It's the work item's task that opened the pull request.
        case openedIt
        /// It's an earlier task's on the same pull request or work item.
        case earlierTask
        /// The Copilot app records that it started from the pull request, or opened it.
        case recordedByCopilot
        /// It told BriefBar it's working on it, with Updates from Copilot Sessions on, and BriefBar still shows that.
        case toldBriefBar
        /// It works on the pull request's branch, in its repository.
        case onItsBranch
        /// You linked them, with Show Links.
        case linkedByYou
        /// Show Links links them otherwise: in Azure DevOps, or through a pull request.
        case linked
        /// Its log has a link to it.
        case mentionsIt

        static func < (lhs: Reason, rhs: Reason) -> Bool { lhs.rawValue < rhs.rawValue }

        /// "opened it", in the middle of a sentence.
        var phrase: String {
            switch self {
            case .openedIt: return "opened it"
            case .earlierTask: return "an earlier task"
            case .recordedByCopilot: return "recorded by Copilot"
            case .toldBriefBar: return "told BriefBar it's working on it"
            case .onItsBranch: return "on its branch"
            case .linkedByYou: return "linked by you"
            case .linked: return "linked"
            case .mentionsIt: return "mentions it"
            }
        }
    }

    var kind: Kind
    /// "Fix Comments: !4071 Fix totals", or the app's name for its session.
    var name: String
    /// Where it works: a repository, or a project and its branch.
    var place: String?
    var lastActive: Date?
    var reasons: [Reason]
    /// The Copilot app has it open: Copilot can only go on with it there, where its history is.
    var isOpenInApp = false
    /// BriefBar's task in it is still working: nothing goes to it until it's done.
    var isBusy = false
    /// A task of BriefBar's works in its checkout, for another session, as when two of the Copilot app's sessions share
    /// one (`CopilotTasksStore.checkoutKey`): nothing goes to it until that's done, or their work would mix.
    var isFolderBusy = false

    /// The folder one of the app's sessions works in, as BriefBar found it when the composer opened; or, for one Show Links
    /// links to a pull request whose details name it, as read while they show it (`PullRequestSessions`); or, for a task
    /// that went on with one of the app's sessions, the one that session works in, as read with the app's.
    var appFolder: URL?

    /// Nothing goes to it now: Copilot works in it, or in its checkout.
    var isUnavailable: Bool { isBusy || isFolderBusy }

    /// The folder it works in: an earlier task's worktree, or the one the app's session works in, as found.
    var folder: URL? { run?.worktree ?? appFolder }

    /// The folder it works in now, as last read, to open it: for a task that went on with one of the app's sessions, the one
    /// that session works in, which may have moved since the task started (`CopilotTasksStore.currentFolder(of:)`), until
    /// it's read; else `folder`.
    var currentFolder: URL? {
        if let run, run.isAppSession == true { return appFolder ?? run.worktree }
        return folder
    }

    var id: String {
        switch kind {
        case .task(let run): return run.id
        case .app(let session): return session.id
        }
    }

    var run: CopilotRun? {
        if case .task(let run) = kind { return run }
        return nil
    }

    var appSession: AppSession? {
        if case .app(let session) = kind { return session }
        return nil
    }

    /// Opened in Copilot, by default, rather than run with the CLI: one of the app's sessions, or one the app has open.
    var opensInApp: Bool { appSession != nil || isOpenInApp || run?.isAppSession == true }

    /// When it began to tell BriefBar it's working on the pull request, while BriefBar shows that: the session you chose
    /// for its work before then gives way to it (`PullRequestSession.pick`).
    var toldSince: Date?
}

extension CopilotTasksStore {
    /// The sessions a task could go to instead of a new one: BriefBar's own for it, its earlier tasks' and, for a pull
    /// request, the session of its work item's task that opened it, the newest first; then the Copilot app's, those that
    /// go with it first. Read when the composer opens, and only while Send Work to Copilot is on: the app's database,
    /// read-only, which sessions the app has open, and the folder each of its sessions works in, and those that tasks that
    /// went on with them work in now.
    func sessionChoices(for subject: TaskSubject) async -> [SessionChoice] {
        guard canSend, isOn else { return [] }
        let home = appHome
        let cliHome = CopilotCLI.home(environment: await environment())
        // Again after that wait, as before every read of Copilot's: it may have been turned off meanwhile, or no longer be
        // wanted, as when the details that wanted them closed.
        guard canSend, isOn, !Task.isCancelled else { return [] }
        let tasks = taskChoices(for: subject)
        let ids = Set(tasks.map(\.id))
        // The tasks that went on with one of the app's sessions, which may have moved since they started.
        let inApp = tasks.filter { $0.run?.isAppSession == true }.map(\.id)
        // In one pass: the app's sessions, which of them and of BriefBar's the app has open, and the folder each of the
        // app's sessions works in, which may be shared, and those tasks' sessions too; no more of it once what wanted them is
        // cancelled.
        let reading = Task.detached(priority: .userInitiated) { () -> (sessions: [AppSession], open: Set<String>, folders: [String: URL]) in
            let sessions = ((try? AppSessions.load(home: home)) ?? []).filter { !ids.contains($0.id) }
            guard !Task.isCancelled else { return ([], [], [:]) }
            let open = Set((Array(ids) + sessions.map(\.id)).filter { id in
                AppSessions.isOpen(id, home: home) || (cliHome != home && AppSessions.isOpen(id, home: cliHome))
            })
            guard !Task.isCancelled else { return ([], [], [:]) }
            let folders = (sessions.map(\.id) + inApp).reduce(into: [String: URL]()) { folders, id in
                folders[id] = AppSessions.folder(of: id, home: home)
            }
            return (sessions, open, folders)
        }
        let found = await withTaskCancellationHandler { await reading.value } onCancel: { reading.cancel() }
        guard !Task.isCancelled else { return [] }
        let links = linkedSessions(Self.ref(of: subject))
        let linked = Self.reasons(of: links)
        let told = toldSince(of: links)
        let apps = found.sessions.map { session in
            SessionChoice(
                kind: .app(session), name: session.name, place: Self.place(of: session), lastActive: session.lastActive,
                reasons: Self.reasons(for: session, subject: subject, linked: linked[session.id] ?? []), toldSince: told[session.id]
            )
        }
        var all = tasks + Self.sorted(apps, createdAt: nil)
        for index in all.indices {
            all[index].isOpenInApp = found.open.contains(all[index].id)
            if all[index].appSession != nil || all[index].run?.isAppSession == true {
                all[index].appFolder = found.folders[all[index].id]
            }
        }
        return availability(of: all)
    }

    /// The sessions as they stand now, for the composer to keep up with BriefBar's tasks while it's open: which ones a task
    /// works in, or in whose folders, as when two of the app's sessions share a checkout; opening such a session in the app,
    /// or starting another run in it, would fork its history or mix their work. Everything else stays as it was found.
    func availability(of choices: [SessionChoice]) -> [SessionChoice] {
        let folders = busyFolders()
        let active = Set(entries.filter { $0.status.phase.isActive }.map(\.id))
        return choices.map { choice in
            var choice = choice
            choice.isBusy = active.contains(choice.id) || isWorking(inSession: choice.id)
            choice.isFolderBusy = !folders.isEmpty && (choice.folder.map { folders.contains(Self.checkoutKey($0)) } ?? false)
            return choice
        }
    }

    /// The folder a session works in: an earlier task's worktree, or the folder one of the app's sessions says.
    func folder(of choice: SessionChoice) -> URL? {
        switch choice.kind {
        case .task(let run): return run.worktree
        case .app(let session): return AppSessions.folder(of: session.id, home: appHome)
        }
    }

    /// The folder a session works in now, for a prompt sent to it through BriefBar's extension: the one the app's session
    /// state says, for one of the app's sessions and for a task that went on with one, which may have moved since the task
    /// started; an earlier task's own worktree otherwise.
    func currentFolder(of choice: SessionChoice) -> URL? {
        if case .task(let run) = choice.kind, run.isAppSession == true {
            return AppSessions.folder(of: run.id, home: appHome) ?? run.worktree
        }
        return folder(of: choice)
    }

    /// Why nothing may go to a session now, or nil: Copilot works in it, or in its checkout, for a task BriefBar sent. Its
    /// checkout is the one in `folder` when given, or the one it works in (`folder(of:)`).
    func busyReason(for choice: SessionChoice, in folder: URL? = nil) -> String? {
        if isWorking(inSession: choice.id) { return "Copilot is still working in it. Try again once it's done." }
        if let folder = folder ?? self.folder(of: choice), isWorking(inFolder: folder) {
            return "Copilot is working in its checkout for another task BriefBar sent. Try again once that's done."
        }
        return nil
    }

    /// BriefBar's sessions for it, whose worktrees are still there, the newest first.
    func taskChoices(for subject: TaskSubject) -> [SessionChoice] {
        tasks { run in
            switch subject {
            case .workItem(let item): return run.workItem?.matches(item.reference) == true ? .earlierTask : nil
            case .pullRequest: return Self.taskReason(of: run, forPullRequest: Self.ref(of: subject))
            }
        }.map { entry, run, reason in
            SessionChoice(
                kind: .task(run), name: name(of: entry), place: run.onPullRequest?.repository ?? run.repository.lastPathComponent,
                lastActive: entry.status.since ?? entry.startedAt, reasons: [reason], isBusy: entry.status.phase.isActive
            )
        }
    }

    /// The sessions of a pull request's task choices (`taskChoices(for:)`), by their IDs.
    func taskSessionIDs(forPullRequest pullRequest: ItemRef) -> Set<String> {
        Set(tasks { Self.taskReason(of: $0, forPullRequest: pullRequest) }.map(\.run.id))
    }

    /// BriefBar's tasks whose worktrees are still there, the newest first, each with why it goes with what `reason` says,
    /// for those it does.
    private func tasks(
        _ reason: (CopilotRun) -> SessionChoice.Reason?
    ) -> [(entry: CopilotTaskEntry, run: CopilotRun, reason: SessionChoice.Reason)] {
        entries.compactMap { entry in
            guard let run = entry.run, run.isValid, FileManager.default.fileExists(atPath: run.worktree.path),
                  let why = reason(run)
            else { return nil }
            return (entry, run, why)
        }
    }

    /// Why a task of BriefBar's goes with a pull request: it was on it, or it's the work item's task that opened it; nil
    /// for neither.
    static func taskReason(of run: CopilotRun, forPullRequest pullRequest: ItemRef) -> SessionChoice.Reason? {
        guard pullRequest.kind == .pullRequest, let number = pullRequest.number else { return nil }
        if run.onPullRequest?.matches(organization: pullRequest.scope, id: number) == true { return .earlierTask }
        if run.workItem != nil, run.pullRequest.flatMap({ ItemRef.from(link: $0.absoluteString) }) == pullRequest { return .openedIt }
        return nil
    }

    /// Why Show Links links each session to it, by the session's ID: nothing while it's off.
    func linkedReasons(for subject: TaskSubject) -> [String: [SessionChoice.Reason]] {
        Self.reasons(of: linkedSessions(Self.ref(of: subject)))
    }

    /// Why Show Links links each of these sessions, by the session's ID.
    static func reasons(of links: [LinkedSession]) -> [String: [SessionChoice.Reason]] {
        var reasons: [String: [SessionChoice.Reason]] = [:]
        for link in links {
            var why: Set<SessionChoice.Reason> = []
            for origin in link.origins {
                switch origin {
                case .you: why.insert(.linkedByYou)
                case .copilot: why.insert(.recordedByCopilot)
                case .session: why.insert(.toldBriefBar)
                case .branch: why.insert(.onItsBranch)
                case .azureDevOps: why.insert(.linked)
                }
            }
            if link.isThrough || why.isEmpty { why.insert(.linked) }
            reasons[link.id, default: []] += why
        }
        return reasons
    }

    /// When each session that Show Links shows telling BriefBar it's working on this began to say so, by its ID
    /// (`SessionChoice.toldSince`), but BriefBar's own (`toldSince(of:)`): nothing while it's off.
    func toldSince(_ ref: ItemRef) -> [String: Date] {
        toldSince(of: linkedSessions(ref))
    }

    /// When each of these sessions that tells BriefBar it's working on what they're linked to began to say so, by its ID:
    /// those that can take the place of the session you chose for a pull request's work, so the same for what picks its
    /// session and what forgets what you chose (`forgetChoicesToldSince`). Not BriefBar's own, which the Copilot app
    /// doesn't have, even one you opened there, which the app then lists.
    func toldSince(of links: [LinkedSession]) -> [String: Date] {
        let own = ownSessionIDs
        var since: [String: Date] = [:]
        for link in links where !link.isThrough && link.origins.contains(.session) && !own.contains(link.id) {
            if let began = link.began { since[link.id] = began }
        }
        return since
    }

    /// BriefBar's own sessions: those of the tasks it ran with the Copilot CLI, not the Copilot app's that it went on with.
    var ownSessionIDs: Set<String> {
        Set(settings.copilotRuns.compactMap { $0.isValid && $0.isAppSession != true ? $0.id : nil })
    }

    /// What a task is for, as Show Links names it.
    static func ref(of subject: TaskSubject) -> ItemRef {
        switch subject {
        case .workItem(let item): return .workItem(organization: item.organization, id: item.id)
        case .pullRequest(let pullRequest, _): return .pullRequest(organization: pullRequest.organization, number: pullRequest.id)
        }
    }

    /// Why one of the app's sessions goes with it: what the app records, its branch, and what Show Links says.
    static func reasons(for session: AppSession, subject: TaskSubject, linked: [SessionChoice.Reason]) -> [SessionChoice.Reason] {
        var reasons = Set(linked)
        if case .pullRequest(let pullRequest, _) = subject {
            if session.pullRequests.contains(.pullRequest(organization: pullRequest.organization, number: pullRequest.id)) {
                reasons.insert(.recordedByCopilot)
            }
            let hint = BranchHint(branch: pullRequest.sourceBranch, target: pullRequest.targetBranch, repositories: [pullRequest.repository])
            if let branch = session.branchHint, BranchLinks.matches(session: branch, pullRequest: hint) {
                reasons.insert(.onItsBranch)
            }
        }
        return reasons.sorted()
    }

    /// "Spectre · users/robin/fix-total", "a chat".
    static func place(of session: AppSession) -> String? {
        if session.isChat { return "a chat" }
        let parts = [session.projectName, session.branch].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The app's sessions, those that go with it first, by their likeliest reason: of those that only mention it, the
    /// ones that were there before it was created first, the oldest of them first, since one of them likely opened it.
    /// Then the most recently active.
    static func sorted(_ sessions: [SessionChoice], createdAt: Date?) -> [SessionChoice] {
        func rank(_ choice: SessionChoice) -> Int {
            guard let best = choice.reasons.min() else { return Int.max }
            if best == .mentionsIt, let createdAt, let born = choice.appSession?.createdAt, born < createdAt {
                return SessionChoice.Reason.mentionsIt.rawValue
            }
            return best == .mentionsIt ? best.rawValue + 1 : best.rawValue
        }
        return sessions.enumerated().sorted { lhs, rhs in
            let (left, right) = (rank(lhs.element), rank(rhs.element))
            if left != right { return left < right }
            if left == SessionChoice.Reason.mentionsIt.rawValue,
               let leftBorn = lhs.element.appSession?.createdAt, let rightBorn = rhs.element.appSession?.createdAt, leftBorn != rightBorn {
                return leftBorn < rightBorn
            }
            let (leftActive, rightActive) = (lhs.element.lastActive ?? .distantPast, rhs.element.lastActive ?? .distantPast)
            if leftActive != rightActive { return leftActive > rightActive }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Which of the app's sessions mention it in their logs, by a link (`SessionMentions`): only those active since it
    /// was created, or in the last 30 days for a work item, the most recently active 40. Read off the main thread, one
    /// log at a time, each only up to its first mention, and none once Send Work to Copilot is off, as when it's turned
    /// off meanwhile, or once the task that waits for them is cancelled.
    func sessionsMentioning(_ subject: TaskSubject, among choices: [SessionChoice], since createdAt: Date?) async -> Set<String> {
        guard canSend, isOn else { return [] }
        let target: SessionMentions.Target
        switch subject {
        case .workItem(let item): target = .workItem(organization: item.organization, id: item.id)
        case .pullRequest(let pullRequest, _): target = .pullRequest(organization: pullRequest.organization, number: pullRequest.id)
        }
        let cutoff = createdAt ?? Date().addingTimeInterval(-30 * 86_400)
        let candidates = choices.compactMap(\.appSession).filter { ($0.lastActive ?? .distantPast) >= cutoff }
            .sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }.prefix(Self.mentionLimit).map(\.id)
        let home = appHome
        var mentioning = Set<String>()
        for id in candidates {
            // Nor once whatever waits for it stopped, such as a pull request's details that closed.
            guard canSend, isOn, !Task.isCancelled else { break }
            let mentions = await Task.detached(priority: .utility) { SessionMentions.mentions(target, inSession: id, home: home) }.value
            mentionReadForTests?(id)
            if mentions { mentioning.insert(id) }
        }
        return mentioning
    }

    /// The most sessions whose logs are read for mentions.
    static let mentionLimit = 40

    /// The sessions, with those whose logs mention it (`sessionsMentioning`) marked so: BriefBar's tasks first, then the
    /// app's sessions in their order (`sorted`), each as available as it is now (`availability`), since a task may have
    /// started or ended while the logs were read.
    func marking(_ mentioned: Set<String>, in choices: [SessionChoice], createdAt: Date?) -> [SessionChoice] {
        var marked = choices
        for index in marked.indices where mentioned.contains(marked[index].id) && !marked[index].reasons.contains(.mentionsIt) {
            marked[index].reasons.append(.mentionsIt)
        }
        return availability(of: marked.filter { $0.run != nil } + Self.sorted(marked.filter { $0.appSession != nil }, createdAt: createdAt))
    }

    /// The session a task goes to unless you choose another: for a pull request, the one its details name
    /// (`PullRequestSession.pick`), picked among all the sessions as they do. The session you chose for its work, or a new
    /// one if you chose that; else on with its last task's, as before; else with the session of the work item's task that
    /// opened it; else with the Copilot app's session that the app records with it, that you linked to it, or that works on
    /// its branch, when one goes with it better than the others. When two go with it as well as each other, or only a link
    /// in one's log says it may have opened it, it suggests none, as its details ask which or offer it rather than guess;
    /// and none while the one they name is busy, rather than another. A work item's starts a new session unless you choose
    /// one.
    /// - Parameters:
    ///   - lastTask: the pull request's last task (`lastTask(forPullRequest:)`), however it stands.
    ///   - chosen: what you chose for the pull request's work, unless a task started on it since (`chosenSession(for:)`).
    static func suggestedChoice(
        _ choices: [SessionChoice], for subject: TaskSubject, lastTask: PullRequestSession.LastTask?,
        chosen: PullRequestSessionChoice? = nil
    ) -> SessionChoice? {
        guard case .pullRequest = subject else { return nil }
        guard case .session(let choice, _) = PullRequestSession.pick(choices, chosen: chosen, lastTask: lastTask),
              !choice.isUnavailable
        else { return nil }
        return choice
    }

    /// The session a pull request's task goes to unless you choose another (`suggestedChoice`), with its last task and what
    /// you chose for it as they are now: where its details say its work goes.
    func suggestedChoice(_ choices: [SessionChoice], for subject: TaskSubject) -> SessionChoice? {
        guard case .pullRequest(let pullRequest, _) = subject else { return nil }
        let key = PRKey(pullRequest.organization, pullRequest.id)
        return Self.suggestedChoice(choices, for: subject, lastTask: lastTask(forPullRequest: key), chosen: chosenSession(for: subject))
    }

    /// The session you chose for a pull request's work, for a task on it, unless a task started on it since, which has taken
    /// its place (`PullRequestSession.chosen(_:after:)`): nil for a work item's.
    func chosenSession(for subject: TaskSubject) -> PullRequestSessionChoice? {
        guard case .pullRequest(let pullRequest, _) = subject else { return nil }
        let key = PRKey(pullRequest.organization, pullRequest.id)
        return PullRequestSession.chosen(settings.chosenSession(for: key), after: lastTask(forPullRequest: key))
    }

    /// Whether Copilot can go on with a session from here, with the CLI: why not, or nil. The app mustn't have it open; for
    /// one of the app's sessions, the CLI has to know it; neither a task of BriefBar's nor another of the app's sessions
    /// that runs a turn may be working in the checkout it works in, which can be shared, whichever folder of it each works
    /// in (`CopilotTasksStore.checkoutKey`); and that folder has to be in a git repository, for a pull request a clone of
    /// its repository. The same for an earlier task of BriefBar's, which may have gone on with one of the app's sessions,
    /// in the folder it works in. As things are now: the app's database and the sessions' state are read again each time.
    /// - Parameter checksRepository: false to leave out the repository, which doesn't change while the window is open,
    ///   once it passed.
    func cliProblem(for choice: SessionChoice, subject: TaskSubject, checksRepository: Bool = true) async -> String? {
        // Nothing of Copilot's is read while Send Work to Copilot is off, nor once what asked is cancelled, such as details
        // that went off screen.
        guard canSend, isOn else { return "BriefBar can't send anything now." }
        guard !Task.isCancelled else { return Self.stoppedChecking }
        let home = appHome
        let cliHome = CopilotCLI.home(environment: await environment())
        guard !Task.isCancelled else { return Self.stoppedChecking }
        let id = choice.id
        let isAppsSession = choice.appSession != nil || choice.run?.isAppSession == true
        let worktree = choice.run?.worktree
        let found = await Task.detached(priority: .userInitiated) { () -> (open: Bool, known: Bool, folder: URL?) in
            let open = AppSessions.isOpen(id, home: home) || AppSessions.isOpen(id, home: cliHome)
            let known = !isAppsSession || (AppSessions.events(of: id, home: cliHome).map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
            // An earlier task's worktree, or the folder it went on with; the folder one of the app's sessions says now.
            return (open, known, worktree ?? AppSessions.folder(of: id, home: home))
        }.value
        if found.open { return "The Copilot app has it open: Copilot can go on with it only there, where its history is." }
        guard found.known else { return "The Copilot CLI doesn't have this session, in \(UserPath.abbreviate(cliHome.path))." }
        guard let folder = found.folder else { return "BriefBar can't tell which folder it works in." }
        if isWorking(inFolder: folder) { return "Copilot is working in the same checkout for another task BriefBar sent." }
        guard !Task.isCancelled else { return Self.stoppedChecking }
        if await anotherSessionRuns(inCheckoutOf: folder, besides: id) {
            return "Another Copilot session is working in the same checkout now, so Copilot won't work there on its own."
        }
        guard checksRepository else { return nil }
        guard !Task.isCancelled else { return Self.stoppedChecking }
        let git = await git()
        do {
            switch subject {
            case .workItem: _ = try await git.repository(at: folder)
            case .pullRequest(let pullRequest, _): _ = try await git.repository(at: folder, for: pullRequest)
            }
            return nil
        } catch {
            return String(describing: error)
        }
    }

    /// What `cliProblem` says once what asked is cancelled: it stopped before it could tell, which nothing shows.
    static let stoppedChecking = "BriefBar stopped checking."

    /// Whether another of the Copilot app's sessions runs a turn now, by the app's own flag, in the same checkout as the
    /// folder (`checkoutKey`), as the app's database and the sessions' state say now, not as the window found them; and
    /// whether the window lists it as one of the app's sessions or as an earlier task that went on with one. Not `id`,
    /// when given: the session Copilot would go on with (`AppSessions.anotherRunsATurn`). Read off the main thread, and
    /// not at all while Send Work to Copilot is off.
    func anotherSessionRuns(inCheckoutOf folder: URL, besides id: String?) async -> Bool {
        guard canSend, isOn, !Task.isCancelled else { return false }
        let home = appHome
        return await Task.detached(priority: .userInitiated) {
            AppSessions.anotherRunsATurn(inCheckoutOf: folder, besides: id, home: home)
        }.value
    }

    /// The run that goes on with one of the app's sessions, with the CLI, in the folder it works in: nil when it doesn't
    /// say where that is.
    func appRun(for session: AppSession, subject: TaskSubject, options: CopilotRunOptions) -> CopilotRun? {
        guard let folder = AppSessions.folder(of: session.id, home: appHome) else { return nil }
        var run = CopilotRun(
            id: session.id, workItem: nil, options: options, repository: folder, worktree: folder, startedAt: Date(),
            process: DetachedProgram.Handle(pid: 0, startedAt: nil), isAppSession: true
        )
        switch subject {
        case .workItem(let item): run.workItem = item.reference
        case .pullRequest(let pullRequest, let action):
            run.onPullRequest = pullRequest.reference
            run.action = action
            run.pullRequest = pullRequest.url
        }
        return run
    }

    /// Whether BriefBar works in the session now, for a task it sent: one getting its worktree ready, or one whose
    /// Copilot process still runs.
    func isWorking(inSession id: String) -> Bool {
        if pending.contains(where: { $0.id == id && $0.status.phase.isActive }) { return true }
        return settings.copilotRuns.contains { $0.id == id && $0.ended == nil && DetachedProgram.isRunning($0.process) }
    }

    /// Whether an app on this Mac opens the Copilot app's `ghapp://` links: without the app, nothing does.
    var canOpenInApp: Bool {
        if let opensLinksForTests { return opensLinksForTests }
        return URL(string: "ghapp://sessions").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) } != nil
    }

    nonisolated static let cantOpenInApp = "No app on this Mac opens the Copilot app's sessions. Install the GitHub Copilot app, or run it with the CLI."

    /// Opens a session in the Copilot app, by its `ghapp://sessions/` link: false when nothing opened it.
    @discardableResult
    static func openInApp(_ id: String) -> Bool {
        guard ItemRef.session(id) != nil, let url = URL(string: "ghapp://sessions/\(id)") else { return false }
        return ThisMac.open(url)
    }

    /// Opens a session in the Copilot app, and says so when it can't.
    static func openInAppOrSay(_ id: String) {
        guard !openInApp(id) else { return }
        let alert = NSAlert()
        alert.messageText = "The session didn't open in Copilot"
        alert.informativeText = "No app on this Mac opens the Copilot app's sessions. Install or open the GitHub Copilot app, then try again."
        NSApp.activate()
        ThisMac.ask(alert)
    }
}
