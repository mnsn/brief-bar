import AppKit
import AzureDevOpsCore
import BriefBarCore
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

    /// The folder one of the app's sessions works in, as BriefBar found it when the composer opened.
    var appFolder: URL?

    /// Nothing goes to it now: Copilot works in it, or in its checkout.
    var isUnavailable: Bool { isBusy || isFolderBusy }

    /// The folder it works in: an earlier task's worktree, or the one the app's session works in, as found.
    var folder: URL? { run?.worktree ?? appFolder }

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
}

extension CopilotTasksStore {
    /// The sessions a task could go to instead of a new one: BriefBar's own for it, its earlier tasks' and, for a pull
    /// request, the session of its work item's task that opened it, the newest first; then the Copilot app's, those that
    /// go with it first. Read when the composer opens, and only while Send Work to Copilot is on: the app's database,
    /// read-only, which sessions the app has open, and the folder each of its sessions works in.
    func sessionChoices(for subject: TaskSubject) async -> [SessionChoice] {
        guard canSend, isOn else { return [] }
        let home = appHome
        let cliHome = CopilotCLI.home(environment: await environment())
        let tasks = taskChoices(for: subject)
        let ids = Set(tasks.map(\.id))
        let sessions = await Task.detached(priority: .userInitiated) {
            (try? AppSessions.load(home: home)) ?? []
        }.value.filter { !ids.contains($0.id) }
        let linked = linkedReasons(for: subject)
        let apps = sessions.map { session in
            SessionChoice(
                kind: .app(session), name: session.name, place: Self.place(of: session), lastActive: session.lastActive,
                reasons: Self.reasons(for: session, subject: subject, linked: linked[session.id] ?? [])
            )
        }
        // Which of them the app has open, and the folder each of the app's sessions works in, which may be shared.
        let found = await Task.detached(priority: .userInitiated) { [tasks, apps] in
            let open = Set((tasks + apps).map(\.id).filter { id in
                AppSessions.isOpen(id, home: home) || (cliHome != home && AppSessions.isOpen(id, home: cliHome))
            })
            let folders = apps.reduce(into: [String: URL]()) { folders, choice in
                folders[choice.id] = AppSessions.folder(of: choice.id, home: home)
            }
            return (open: open, folders: folders)
        }.value
        var all = tasks + Self.sorted(apps, createdAt: nil)
        for index in all.indices {
            all[index].isOpenInApp = found.open.contains(all[index].id)
            if all[index].appSession != nil { all[index].appFolder = found.folders[all[index].id] }
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

    /// Why nothing may go to a session now, or nil: Copilot works in it, or in its checkout, for a task BriefBar sent.
    func busyReason(for choice: SessionChoice) -> String? {
        if isWorking(inSession: choice.id) { return "Copilot is still working in it. Try again once it's done." }
        if let folder = folder(of: choice), isWorking(inFolder: folder) {
            return "Copilot is working in its checkout for another task BriefBar sent. Try again once that's done."
        }
        return nil
    }

    /// BriefBar's sessions for it, whose worktrees are still there, the newest first.
    func taskChoices(for subject: TaskSubject) -> [SessionChoice] {
        entries.compactMap { entry in
            guard let run = entry.run, run.isValid, FileManager.default.fileExists(atPath: run.worktree.path) else { return nil }
            let reason: SessionChoice.Reason
            switch subject {
            case .workItem(let item):
                guard run.workItem?.matches(item.reference) == true else { return nil }
                reason = .earlierTask
            case .pullRequest(let pullRequest, _):
                if run.onPullRequest?.matches(organization: pullRequest.organization, id: pullRequest.id) == true {
                    reason = .earlierTask
                } else if run.workItem != nil,
                          run.pullRequest.flatMap({ ItemRef.from(link: $0.absoluteString) })
                          == .pullRequest(organization: pullRequest.organization, number: pullRequest.id) {
                    reason = .openedIt
                } else {
                    return nil
                }
            }
            return SessionChoice(
                kind: .task(run), name: name(of: entry), place: run.onPullRequest?.repository ?? run.repository.lastPathComponent,
                lastActive: entry.status.since ?? entry.startedAt, reasons: [reason], isBusy: entry.status.phase.isActive
            )
        }
    }

    /// Why Show Links links each session to it, by the session's ID: nothing while it's off.
    private func linkedReasons(for subject: TaskSubject) -> [String: [SessionChoice.Reason]] {
        let ref: ItemRef
        switch subject {
        case .workItem(let item): ref = .workItem(organization: item.organization, id: item.id)
        case .pullRequest(let pullRequest, _): ref = .pullRequest(organization: pullRequest.organization, number: pullRequest.id)
        }
        var reasons: [String: [SessionChoice.Reason]] = [:]
        for link in linkedSessions(ref) {
            var why: Set<SessionChoice.Reason> = []
            for origin in link.origins {
                switch origin {
                case .you: why.insert(.linkedByYou)
                case .copilot: why.insert(.recordedByCopilot)
                case .branch: why.insert(.onItsBranch)
                case .azureDevOps: why.insert(.linked)
                }
            }
            if link.isThrough || why.isEmpty { why.insert(.linked) }
            reasons[link.id, default: []] += why
        }
        return reasons
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
    /// was created, or in the last 30 days for a work item, the most recently active 40. Read off the main thread, each
    /// log only up to its first mention.
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
        return await Task.detached(priority: .utility) {
            Set(candidates.filter { SessionMentions.mentions(target, inSession: $0, home: home) })
        }.value
    }

    /// The most sessions whose logs are read for mentions.
    static let mentionLimit = 40

    /// The session a task goes to unless you choose another. A pull request's goes on with its last task's, as before;
    /// else with the session of the work item's task that opened it; else with the app's session that the app records
    /// with it, that you linked to it, or that works on its branch, the most recently active; else with the one that
    /// mentions it and was there before it was created, which likely opened it. A work item's starts a new session unless
    /// you choose one.
    static func suggestedChoice(
        _ choices: [SessionChoice], for subject: TaskSubject, continuable: CopilotRun?, createdAt: Date?
    ) -> SessionChoice? {
        guard case .pullRequest = subject else { return nil }
        let usable = choices.filter { !$0.isUnavailable }
        if let continuable, let last = usable.first(where: { $0.id == continuable.id }) { return last }
        if let opener = usable.first(where: { $0.run != nil && $0.reasons.contains(.openedIt) }) { return opener }
        let strong: Set<SessionChoice.Reason> = [.recordedByCopilot, .linkedByYou, .onItsBranch]
        let apps = usable.filter { $0.appSession != nil }
        if let linked = apps.filter({ !strong.isDisjoint(with: $0.reasons) })
            .max(by: { ($0.lastActive ?? .distantPast) < ($1.lastActive ?? .distantPast) }) {
            return linked
        }
        guard let createdAt else { return nil }
        return apps.filter { choice in
            guard choice.reasons.contains(.mentionsIt), let born = choice.appSession?.createdAt else { return false }
            return born < createdAt
        }.min { ($0.appSession?.createdAt ?? .distantFuture) < ($1.appSession?.createdAt ?? .distantFuture) }
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
        // Nothing of Copilot's is read while Send Work to Copilot is off.
        guard canSend, isOn else { return "BriefBar can't send anything now." }
        let home = appHome
        let cliHome = CopilotCLI.home(environment: await environment())
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
        if await anotherSessionRuns(inCheckoutOf: folder, besides: id) {
            return "Another Copilot session is working in the same checkout now, so Copilot won't work there on its own."
        }
        guard checksRepository else { return nil }
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

    /// Whether another of the Copilot app's sessions runs a turn now, by the app's own flag, in the same checkout as the
    /// folder (`checkoutKey`), as the app's database and the sessions' state say now, not as the window found them; and
    /// whether the window lists it as one of the app's sessions or as an earlier task that went on with one. Not `id`,
    /// when given: the session Copilot would go on with (`AppSessions.anotherRunsATurn`). Read off the main thread, and
    /// not at all while Send Work to Copilot is off.
    func anotherSessionRuns(inCheckoutOf folder: URL, besides id: String?) async -> Bool {
        guard canSend, isOn else { return false }
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

    /// Hands a task to a session in the Copilot app: copies the prompt, and opens the session there, for you to paste and
    /// send. Copilot works on it there, with the session's own model, mode and permissions, where you see it. It's in your
    /// hands then: what `handOff` says the prompt takes care of leaves Needs You, but only once the session opened.
    /// - Returns: why it didn't, or nil once it did.
    @discardableResult
    func openInCopilot(_ choice: SessionChoice, prompt: String, handOff: CommentHandOff?) -> String? {
        guard canSend, isOn, ItemRef.session(choice.id) != nil else { return "BriefBar can't send anything now." }
        // Opening it while Copilot works in it would fork its history; while Copilot works in its checkout, their work would mix.
        if let busy = busyReason(for: choice) { return busy }
        let opened: Bool
        if let openForTests {
            opened = openForTests(choice.id, prompt)
        } else if canOpenInApp {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(prompt, forType: .string)
            opened = Self.openInApp(choice.id)
        } else {
            opened = false
        }
        guard opened else {
            Log.app.error("Couldn't open a session in the Copilot app")
            return Self.cantOpenInApp
        }
        Log.app.info("Handed a task to a session in the Copilot app")
        if let handOff { handedOff(handOff, prompt) }
        return nil
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

    static let cantOpenInApp = "No app on this Mac opens the Copilot app's sessions. Install the GitHub Copilot app, or run it with the CLI."

    /// Opens a session in the Copilot app, by its `ghapp://sessions/` link: false when nothing opened it.
    @discardableResult
    static func openInApp(_ id: String) -> Bool {
        guard ItemRef.session(id) != nil, let url = URL(string: "ghapp://sessions/\(id)") else { return false }
        return NSWorkspace.shared.open(url)
    }

    /// Opens a session in the Copilot app, and says so when it can't.
    static func openInAppOrSay(_ id: String) {
        guard !openInApp(id) else { return }
        let alert = NSAlert()
        alert.messageText = "The session didn't open in Copilot"
        alert.informativeText = "No app on this Mac opens the Copilot app's sessions. Install or open the GitHub Copilot app, then try again."
        NSApp.activate()
        alert.runModal()
    }
}
