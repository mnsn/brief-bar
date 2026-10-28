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
    /// read-only, and which sessions the app has open.
    func sessionChoices(for subject: TaskSubject) async -> [SessionChoice] {
        guard canSend, isOn else { return [] }
        let home = appHome
        let cliHome = CopilotCLI.home(environment: await environment())
        var tasks = taskChoices(for: subject)
        let ids = Set(tasks.map(\.id))
        let sessions = await Task.detached(priority: .userInitiated) {
            (try? AppSessions.load(home: home)) ?? []
        }.value.filter { !ids.contains($0.id) }
        let linked = linkedReasons(for: subject)
        var apps = sessions.map { session in
            SessionChoice(
                kind: .app(session), name: session.name, place: Self.place(of: session), lastActive: session.lastActive,
                reasons: Self.reasons(for: session, subject: subject, linked: linked[session.id] ?? [])
            )
        }
        let open = await Task.detached(priority: .userInitiated) { [tasks, apps] in
            Set((tasks + apps).map(\.id).filter { id in
                AppSessions.isOpen(id, home: home) || (cliHome != home && AppSessions.isOpen(id, home: cliHome))
            })
        }.value
        for index in tasks.indices { tasks[index].isOpenInApp = open.contains(tasks[index].id) }
        for index in apps.indices { apps[index].isOpenInApp = open.contains(apps[index].id) }
        return tasks + Self.sorted(apps, createdAt: nil)
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
            Set(candidates.filter { id in AppSessions.events(of: id, home: home).map { SessionMentions.mentions(target, in: $0) } ?? false })
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
        let usable = choices.filter { !$0.isBusy }
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

    /// Whether Copilot can go on with one of the app's sessions from here, with the CLI: why not, or nil. The app mustn't
    /// have it open; the CLI has to know it; and the folder it works in has to be in a git repository, for a pull request
    /// a clone of its repository.
    func cliProblem(for session: AppSession, subject: TaskSubject) async -> String? {
        let home = appHome
        let cliHome = CopilotCLI.home(environment: await environment())
        let found = await Task.detached(priority: .userInitiated) { () -> (open: Bool, known: Bool, folder: URL?) in
            let open = AppSessions.isOpen(session.id, home: home) || AppSessions.isOpen(session.id, home: cliHome)
            let known = AppSessions.events(of: session.id, home: cliHome).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            return (open, known, AppSessions.folder(of: session.id, home: home))
        }.value
        if found.open { return "The Copilot app has it open: Copilot can go on with it only there." }
        guard found.known else { return "The Copilot CLI doesn't have this session, in \(UserPath.abbreviate(cliHome.path))." }
        guard let folder = found.folder else { return "BriefBar can't tell which folder it works in." }
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
    /// hands then: what `handOff` says the prompt takes care of leaves Needs You.
    func openInCopilot(_ choice: SessionChoice, prompt: String, handOff: CommentHandOff?) {
        guard canSend, isOn, ItemRef.session(choice.id) != nil else { return }
        if let openForTests {
            openForTests(choice.id, prompt)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(prompt, forType: .string)
            Self.openInApp(choice.id)
        }
        Log.app.info("Handed a task to a session in the Copilot app")
        if let handOff { handedOff(handOff, prompt) }
    }

    /// Opens a session in the Copilot app, by its `ghapp://sessions/` link.
    static func openInApp(_ id: String) {
        guard ItemRef.session(id) != nil, let url = URL(string: "ghapp://sessions/\(id)") else { return }
        NSWorkspace.shared.open(url)
    }
}
